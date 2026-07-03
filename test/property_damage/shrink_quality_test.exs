defmodule PropertyDamage.ShrinkQualityTest do
  @moduledoc """
  Phase 6a: in-repo seeded-bug shrink-quality suite (zero infrastructure).

  Each seeded bug is a deliberate adapter lie against a real in-memory store
  (`PropertyDamage.Test.ShrinkQuality`, an Agent). The model's read-consistency
  invariant catches the lie, and each scenario asserts that the FULL pipeline
  (seeded generation -> discovery -> shrinking) reaches the KNOWN minimal
  reproduction, deterministically.

  This is the end-to-end counterpart to the unit-level shrinker tests: it
  measures shrink quality across the whole loop, not just `Shrinker.shrink/2`
  on a hand-built sequence. When shrink quality regresses, the exact
  minimal-length assertions fail. That is the regression-tested metric this
  suite exists to provide.

  Scope: intentionally linear. Branching/parallel shrink quality is the subject
  of the dedicated 6c bench (and `shrinker_test.exs`); `external()` shrink
  quality lives in `external_shrink_test.exs` and the 6b Oban bench. Seeds are
  pinned empirically: each adapter's bug is reliably discovered AND shrinks to
  its minimal repro at the recorded seed.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Sequence}
  alias PropertyDamage.Test.ShrinkQuality.Commands.{DelKey, GetKey, PutKey}
  alias PropertyDamage.Test.ShrinkQuality.{CorrectAdapter, Model, Store}
  alias PropertyDamage.Test.ShrinkQuality.Events.{EntryDeleted, EntryPut}

  # The bug: delete claims success but never touches the store. The minimal
  # reproduction is put k -> del k -> get k on one key (3 commands): only then
  # does the model expect the key absent while the SUT still serves the value.
  defmodule LyingDeleteAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: CorrectAdapter.setup(config)

    @impl true
    def teardown(context), do: CorrectAdapter.teardown(context)

    @impl true
    def execute(%DelKey{key: key}, _ctx, _runtime), do: {:ok, [%EntryDeleted{key: key}]}

    def execute(command, ctx, runtime), do: CorrectAdapter.execute(command, ctx, runtime)
  end

  # The bug: put never overwrites an existing key. The minimal reproduction is
  # put k v1 -> put k v2 -> get k with v1 != v2 (3 commands): the model expects
  # v2 but the store still serves v1. Note this also exercises failure-preserving
  # argument shrinking: if values shrank to v1 == v2 the failure would vanish,
  # so the shrinker must keep them distinct.
  defmodule InsertOnlyAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: CorrectAdapter.setup(config)

    @impl true
    def teardown(context), do: CorrectAdapter.teardown(context)

    @impl true
    def execute(%PutKey{key: key, value: value}, %{store: pid}, _runtime) do
      if Store.get(pid, key) == nil, do: Store.put(pid, key, value)
      {:ok, [%EntryPut{key: key, value: value}]}
    end

    def execute(command, ctx, runtime), do: CorrectAdapter.execute(command, ctx, runtime)
  end

  defp run_seeded(adapter, seed) do
    PropertyDamage.run(
      model: Model,
      adapter: adapter,
      seed: seed,
      max_commands: 20,
      max_runs: 150,
      verbose: false
    )
  end

  defp reproduces?(sequence, adapter) do
    {:ok, replay} = Executor.run(sequence, Model, adapter, adapter_config: %{})
    not replay.success
  end

  describe "sanity" do
    test "the correct adapter satisfies the read-consistency invariant" do
      assert {:ok, _stats} =
               PropertyDamage.run(
                 model: Model,
                 adapter: CorrectAdapter,
                 seed: 1,
                 max_commands: 30,
                 max_runs: 200,
                 verbose: false
               )
    end
  end

  describe "seeded bug: no-op delete" do
    @seed 1

    test "discovered, and shrinks to the minimal put -> del -> get on one key" do
      assert {:error, failure} = run_seeded(LyingDeleteAdapter, @seed)
      assert failure.check_name == :read_consistent

      commands = Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(failure))

      assert [%PutKey{key: key}, %DelKey{key: key}, %GetKey{key: key}] = commands,
             "expected the 3-command put/del/get minimal repro, got: #{inspect(commands)}"

      # Non-vacuity: the raw discovered failure was much longer than the minimal.
      assert length(Sequence.to_list(failure.original_sequence)) > length(commands)
    end

    test "the shrunk reproduction still fails the same way" do
      assert {:error, failure} = run_seeded(LyingDeleteAdapter, @seed)

      assert reproduces?(
               PropertyDamage.FailureReport.shrunk_sequence(failure),
               LyingDeleteAdapter
             )
    end

    test "shrinking is deterministic across repeated runs" do
      assert {:error, a} = run_seeded(LyingDeleteAdapter, @seed)
      assert {:error, b} = run_seeded(LyingDeleteAdapter, @seed)

      assert Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(a)) ==
               Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(b))
    end
  end

  describe "seeded bug: insert-only put" do
    @seed 1

    test "discovered, and shrinks to the minimal put -> put -> get with distinct values" do
      assert {:error, failure} = run_seeded(InsertOnlyAdapter, @seed)
      assert failure.check_name == :read_consistent

      commands = Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(failure))

      assert [
               %PutKey{key: key, value: v1},
               %PutKey{key: key, value: v2},
               %GetKey{key: key}
             ] = commands,
             "expected the 3-command put/put/get minimal repro, got: #{inspect(commands)}"

      # The two writes must stay distinct: that is what makes the failure
      # reproduce, so argument shrinking must not collapse them.
      assert v1 != v2

      assert length(Sequence.to_list(failure.original_sequence)) > length(commands)
    end

    test "the shrunk reproduction still fails the same way" do
      assert {:error, failure} = run_seeded(InsertOnlyAdapter, @seed)
      assert reproduces?(PropertyDamage.FailureReport.shrunk_sequence(failure), InsertOnlyAdapter)
    end

    test "shrinking is deterministic across repeated runs" do
      assert {:error, a} = run_seeded(InsertOnlyAdapter, @seed)
      assert {:error, b} = run_seeded(InsertOnlyAdapter, @seed)

      assert Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(a)) ==
               Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(b))
    end
  end
end
