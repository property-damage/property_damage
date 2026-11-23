defmodule PropertyDamage.Next.StreamDataSourceFreshVmTest do
  # A journal written by the recording-source engine must load in a VM that
  # has loaded nothing yet, and rebuild the identical plan there. The peer VM
  # shares this VM's code path, on which the patched StreamData comes first,
  # so it draws through the same open seams.
  use ExUnit.Case, async: true

  @moduletag :patched_stream_data
  @moduletag timeout: 120_000

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.StreamDataSource
  alias PropertyDamage.Next.{Generation, Journal}
  alias PropertyDamage.Test.PatchedStreamData

  @format :property_damage_next_journal

  # Integer, member, boolean, StreamData and dependent fields, a plain
  # assign and a dependent assign that returns a StreamData generator.
  # Defined here, so the peer gets its code as a binary.
  {:module, source_kinds, source_kinds_beam, _} =
    defmodule SourceKindsModel do
      @moduledoc false
      use PropertyDamage.Next.Model

      alias PropertyDamage.Next.{Gen, StepSpec}
      alias PropertyDamage.Next.Test.Fixtures.{EmptyProjection, NullSimulator, Probe}

      def steps do
        [Probe]
        |> StepSpec.normalize()
        |> Enum.map(&StepSpec.assign(&1, :tenant, Gen.integer(1..3)))
        |> Enum.map(
          &StepSpec.assign_from_command(&1, :batch, fn probe ->
            StreamData.list_of(StreamData.integer(1..probe.count), max_length: 3)
          end)
        )
      end

      def simulator, do: NullSimulator
      def command_sequence_projection, do: EmptyProjection
    end

  @source_kinds source_kinds
  @source_kinds_beam source_kinds_beam

  # The peer gets this VM's code path, but not in this VM's order, so the
  # directory this VM loaded StreamData from, the patched ebin copy, is put
  # at the head of the peer's path before the peer loads StreamData.
  setup do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})
    patched = StreamData |> :code.which() |> Path.dirname() |> String.to_charlist()
    false = :peer.call(peer, :code, :is_loaded, [StreamData])
    true = :peer.call(peer, :code, :add_patha, [patched])

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    %{peer: peer}
  end

  test "a journal of this engine is saved as version 3, loads in a fresh VM and rebuilds the identical plan",
       %{peer: peer} do
    journal = Next.plan(@source_kinds, 5, max_steps: 6, engine: StreamDataSource).journal
    binary = Journal.to_binary(journal)

    assert {@format, 3, _content} = :erlang.binary_to_term(binary)

    tags = journal.entries |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    assert tags == [:pick, :source]

    assert {:module, @source_kinds} =
             :peer.call(peer, :code, :load_binary, [
               @source_kinds,
               ~c"nofile",
               @source_kinds_beam
             ])

    for module <- [Generation, StreamDataSource],
        do: refute(:peer.call(peer, :code, :is_loaded, [module]))

    assert :peer.call(peer, Journal, :from_binary, [binary, [model: @source_kinds]], 60_000) ==
             journal

    # The peer draws through the patched StreamData from the ebin copy the
    # test helper wrote.
    assert :peer.call(peer, PatchedStreamData, :active?, [], 60_000)
    assert :peer.call(peer, :code, :which, [StreamData]) |> to_string() =~ "stream_data_patch"

    local = Next.plan(@source_kinds, journal, engine: StreamDataSource)

    remote =
      :peer.call(peer, Next, :plan, [@source_kinds, journal, [engine: StreamDataSource]], 60_000)

    assert remote.steps == local.steps
    assert remote.journal == journal
    assert local.journal == journal
    assert remote.kept == []
  end
end
