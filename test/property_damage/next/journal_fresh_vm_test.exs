defmodule PropertyDamage.Next.JournalFreshVmTest do
  # A journal saved in one VM must load in the next one. Modules load on first
  # use, so a fresh VM knows neither PD's atoms nor the model's until their
  # modules load, and decoding refuses to create atoms. Each test loads a
  # binary saved here in a peer VM that shares this VM's code paths and has
  # loaded nothing from them.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.Native
  alias PropertyDamage.Next.{Generation, Journal, Placeholder}
  alias PropertyDamage.Next.Test.Scheme.Model

  # A model whose journals hold every entry kind and key kind generation
  # writes. It is defined here, so the peer gets its compiled code as a binary.
  {:module, all_kinds, all_kinds_beam, _} =
    defmodule AllKindsModel do
      @moduledoc false
      use PropertyDamage.Next.Model

      alias PropertyDamage.Next.{Gen, StepSpec}
      alias PropertyDamage.Next.Test.Fixtures.{EmptyProjection, NullSimulator, Probe}

      def steps do
        [Probe]
        |> StepSpec.normalize()
        |> Enum.map(&StepSpec.assign(&1, :tenant, Gen.integer(1..3)))
      end

      def simulator, do: NullSimulator
      def command_sequence_projection, do: EmptyProjection
    end

  @all_kinds all_kinds
  @all_kinds_beam all_kinds_beam

  @moduletag timeout: 120_000

  setup do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    %{peer: peer}
  end

  defp in_fresh_vm(peer, fun, args) do
    :peer.call(peer, Journal, fun, args, 60_000)
  end

  defp model_journal, do: Next.plan(Model, 3, max_steps: 6).journal

  test "a journal naming only PD's atoms loads without the model", %{peer: peer} do
    journal = %Journal{
      seed: 1,
      max_steps: 1,
      entries: %{
        {{0, 1}, :command, :step} => {:integer, 3, 1..9},
        {{0, 1}, :command, :path} =>
          {:member, %Placeholder{step: {0, 1}, event_index: 0, path: [:event_index]}, 0}
      },
      fingerprint: nil
    }

    assert in_fresh_vm(peer, :from_binary, [Journal.to_binary(journal)]) == journal
  end

  test "a journal naming the model's atoms loads once the model is given", %{peer: peer} do
    journal = model_journal()

    assert in_fresh_vm(peer, :from_binary, [Journal.to_binary(journal), [model: Model]]) ==
             journal
  end

  test "without the model, the refusal names the atom not yet loaded", %{peer: peer} do
    %ArgumentError{message: message} =
      assert_raise ArgumentError, fn ->
        in_fresh_vm(peer, :from_binary, [Journal.to_binary(model_journal())])
      end

    assert message =~ "not yet loaded in this VM"
    assert message =~ "model:"
    refute message =~ "not a journal"
  end

  test "a journal holding every entry kind loads without the modules that write them",
       %{peer: peer} do
    journal = Next.plan(@all_kinds, 1, max_steps: 6).journal
    tags = journal.entries |> Map.values() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    keys = Map.keys(journal.entries)

    for tag <- [:pick, :integer, :member, :stream_data], do: assert(tag in tags)
    assert Enum.any?(keys, &match?({{0, _}, :pick}, &1))
    assert Enum.any?(keys, &match?({{0, _}, :command, _}, &1))
    assert Enum.any?(keys, &match?({{0, _}, :assigns, :tenant}, &1))

    assert {:module, @all_kinds} =
             :peer.call(peer, :code, :load_binary, [@all_kinds, ~c"nofile", @all_kinds_beam])

    for module <- [Generation, Native],
        do: refute(:peer.call(peer, :code, :is_loaded, [module]))

    assert in_fresh_vm(peer, :from_binary, [Journal.to_binary(journal), [model: @all_kinds]]) ==
             journal
  end
end
