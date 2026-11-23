defmodule PropertyDamage.Next.LayeredJournalTest do
  # A journal recorded on a layered model: assigns survive saving, loading in
  # a fresh VM and replay, and a layer gained or lost is refused or replayed
  # according to what the fingerprint covers.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Journal, ModelChangedError}
  alias PropertyDamage.Next.Test.LayerJournal, as: L
  alias PropertyDamage.Next.Test.Scheme.Adapter

  @moduletag timeout: 120_000

  # The adapter acknowledges no assign, so the run names the ones it ignores.
  @ignored [:tenant, :hint]
  @failing [
    model: L.Base,
    adapter: Adapter,
    config: %{fault: :refund_error},
    ignored_assigns: @ignored,
    seed: 3,
    max_steps: 8,
    max_plans: 10
  ]

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

  defp shrunk_failure do
    assert {:error, %Failure{} = failure} = Next.run(@failing)
    failure
  end

  describe "a shrunk failure whose steps carry assigns" do
    test "has a plan whose steps hold a plain assign and an assign drawn from the command" do
      steps = shrunk_failure().plan.steps
      assigns = Enum.map(steps, & &1.assigns)

      assert Enum.any?(assigns, &match?(%{tenant: n} when is_integer(n), &1))
      assert Enum.any?(assigns, &match?(%{hint: n} when is_integer(n), &1))
    end

    test "loads in a fresh VM and rebuilds to the identical plan, assigns included",
         %{peer: peer} do
      failure = shrunk_failure()
      binary = Journal.to_binary(failure.journal)

      journal = :peer.call(peer, Journal, :from_binary, [binary, [model: L.Base]], 60_000)
      plan = :peer.call(peer, Next, :plan, [L.Base, journal], 60_000)

      assert journal == failure.journal
      assert plan.steps == failure.plan.steps
      assert Enum.map(plan.steps, & &1.assigns) == Enum.map(failure.plan.steps, & &1.assigns)
    end

    test "replays from its binary to the same failure" do
      failure = shrunk_failure()
      binary = Journal.to_binary(failure.journal)

      opts = Keyword.take(@failing, [:model, :adapter, :config, :ignored_assigns])
      assert {:error, %Failure{} = replayed} = Next.replay(binary, opts)

      assert replayed.reason == failure.reason
      assert replayed.step == failure.step
      assert replayed.plan.steps == failure.plan.steps
    end
  end

  describe "a journal recorded on the base model, replayed on a model with a layer gained or lost" do
    setup do
      %{journal: Next.plan(L.Base, 3, max_steps: 6).journal}
    end

    # The ignored list names the keys the model sets, since PD checks the
    # list against the model before it compares the journal's fingerprint.
    defp replay_on(journal, module) do
      ignored = module.steps() |> Enum.flat_map(&Map.keys(&1.assigns)) |> Enum.uniq()

      result =
        try do
          Next.replay(journal,
            model: module,
            adapter: Adapter,
            config: %{recorder: self()},
            ignored_assigns: ignored
          )
        rescue
          error -> error
        end

      {result, adapter_called?()}
    end

    defp adapter_called? do
      receive do
        {:scheme_executed, _, _, _} -> true
      after
        0 -> false
      end
    end

    test "an added assigns-only layer is refused, as the fingerprint covers assign keys",
         %{journal: journal} do
      assert {%ModelChangedError{}, false} = replay_on(journal, L.AddsAssignLayer)
    end

    test "an added layer that changes a weight is refused", %{journal: journal} do
      assert {%ModelChangedError{}, false} = replay_on(journal, L.AddsWeightLayer)
    end

    test "a removed layer is refused, whether it set one assign or all of them",
         %{journal: journal} do
      assert {%ModelChangedError{}, false} = replay_on(journal, L.DropsHintLayer)
      assert {%ModelChangedError{}, false} = replay_on(journal, L.DropsAllLayers)
    end

    test "a layer that changes only a command option's value replays as built",
         %{journal: journal} do
      assert %Next.Plan{} = built = Next.plan(L.AddsOptionLayer, journal)
      assert {{:ok, %{plans: 1}}, true} = replay_on(journal, L.AddsOptionLayer)

      # The recorded draws still decide the plan: the kinds of step and the
      # assigns of the base are kept where the wider option leaves them valid.
      base = Next.plan(L.Base, journal)
      assert Enum.map(built.steps, & &1.spec_id) == Enum.map(base.steps, & &1.spec_id)
    end
  end
end
