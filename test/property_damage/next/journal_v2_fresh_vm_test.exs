defmodule PropertyDamage.Next.JournalV2FreshVmTest do
  # A version 2 journal must load in a VM that has loaded nothing yet: one
  # holding a StreamData entry with a path, an empty pick and a stamped mint
  # marker read back from the predicted state. Loading creates no atom, so
  # every atom of the new entries must be known to PD before decoding.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.Native
  alias PropertyDamage.Next.{Generation, Journal, Step}
  alias PropertyDamage.Next.Test.Fixtures.Probe
  alias PropertyDamage.Next.Test.Retry
  alias PropertyDamage.Next.Test.Surface

  # Every entry kind: the probe's integer, member, boolean, StreamData and
  # dependent fields, a payment's stamped keys, and a retry that reads a
  # stamped key back. Defined here, so the peer gets its code as a binary.
  {:module, kinds, kinds_beam, _} =
    defmodule V2KindsModel do
      @moduledoc false
      use PropertyDamage.Next.Model

      alias PropertyDamage.Next.StepSpec
      alias PropertyDamage.Next.Test.Fixtures.Probe
      alias PropertyDamage.Next.Test.Retry

      def steps do
        StepSpec.normalize([
          Probe,
          Retry.Pay,
          {Retry.Again, when: &Retry.Again.possible?/1}
        ])
      end

      def simulator, do: Retry.Simulator
      def command_sequence_projection, do: Retry.Projection
    end

  @kinds kinds
  @kinds_beam kinds_beam
  @max_steps 10

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

  # A plan of the model with a retry, one slot emptied, and a probe's label
  # stored with a non-empty path, rebuilt so the journal is one generation
  # writes.
  defp journal_with_every_new_entry do
    {plan, retry_key} =
      Enum.find_value(1..100, fn seed ->
        plan = Next.plan(@kinds, seed, max_steps: @max_steps)

        case Enum.find(plan.steps, &match?(%Step{command: %Retry.Again{}}, &1)) do
          nil -> nil
          %Step{key: key} -> {plan, key}
        end
      end) || flunk("no seed in 100 draws a retry")

    {label_key, entry} = label_with_path(plan)
    empty = Enum.find(plan.steps, &(&1.key not in [retry_key, elem(label_key, 0)])).key

    entries =
      plan.journal.entries
      |> Map.put(label_key, entry)
      |> Map.put({empty, :pick}, {:empty})

    Next.plan(@kinds, %{plan.journal | entries: entries}).journal
  end

  # The probe's label generator, as PD's engine draws it.
  defp label, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 6)

  defp label_with_path(plan) do
    Enum.find_value(plan.steps, fn
      %Step{key: step, command: %Probe{}} ->
        key = {step, :command, :label}
        key_seed = Journal.key_seed(plan.journal.seed, key)

        case Surface.child_count(label(), key_seed, []) do
          0 ->
            nil

          count ->
            {value, path} = Surface.walk(label(), key_seed, [count - 1])
            {key, {:stream_data, value, path}}
        end

      _step ->
        nil
    end) || flunk("no probe label with children")
  end

  test "a journal with a path entry, an empty pick and a stamped marker loads and rebuilds the identical plan",
       %{peer: peer} do
    journal = journal_with_every_new_entry()
    values = Map.values(journal.entries)

    assert {:empty} in values
    assert Enum.any?(values, &match?({:stream_data, _value, [_ | _]}, &1))

    assert Enum.any?(values, fn
             {:member, %{key: %PropertyDamage.Mint{}}, _index} -> true
             _ -> false
           end)

    assert {:module, @kinds} =
             :peer.call(peer, :code, :load_binary, [@kinds, ~c"nofile", @kinds_beam])

    for module <- [Generation, Native, PropertyDamage.Mint],
        do: refute(:peer.call(peer, :code, :is_loaded, [module]))

    binary = Journal.to_binary(journal)

    assert :peer.call(peer, Journal, :from_binary, [binary, [model: @kinds]], 60_000) == journal

    local = Next.plan(@kinds, journal)
    remote = :peer.call(peer, Next, :plan, [@kinds, journal], 60_000)

    assert remote.steps == local.steps
    assert remote.withdrawn == local.withdrawn
    assert remote.journal == journal
  end
end
