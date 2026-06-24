defmodule PropertyDamage.InvariantCatalogTest do
  @moduledoc """
  End-to-end tests for the invariant catalog and anti-vacuity coverage (DR-026).

  The headline guarantee: an assertion whose trigger never fires (e.g.
  `@trigger every: NeverEmitted` where `NeverEmitted` is never observed) is a
  silent vacuous pass today. Coverage turns its zero firings into a visible
  signal: `PropertyDamage.assertion_coverage/2` reports the never-fired
  invariant as uncovered while a normally-firing one is covered.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.Formatter

  # An event the model emits on every command.
  defmodule Ticked, do: defstruct([])

  # An event/command module that is NEVER produced. An assertion triggered on
  # it can never fire, which is precisely the dynamic-vacuity case.
  defmodule NeverEmitted, do: defstruct([])

  defmodule Tick do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule GateProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{ticks: 0}

    @impl true
    def apply(%{ticks: t} = state, %Ticked{}), do: %{state | ticks: t + 1}
    def apply(state, _), do: state

    # Fires on every step: its invariant (default id :always_runs) is exercised.
    @trigger every: 1
    def assert_always_runs(_state, _cmd_or_event), do: :ok

    # Triggers only on a NeverEmitted observation, which never happens: its
    # invariant (default id :never_runs) is declared but never exercised.
    @trigger every: NeverEmitted
    def assert_never_runs(_state, _cmd_or_event), do: :ok
  end

  defmodule GateModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Tick]
    @impl true
    def command_sequence_projection, do: GateProjection
  end

  defmodule TickAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Tick{}, _ctx), do: {:ok, [%Ticked{}]}
  end

  test "a never-firing assertion is reported uncovered; a firing one is covered" do
    result =
      PropertyDamage.run(
        model: GateModel,
        adapter: TickAdapter,
        max_runs: 5,
        max_commands: 5,
        validate: false,
        shrink: false
      )

    assert {:ok, _stats} = result

    coverage = PropertyDamage.assertion_coverage(result, GateModel)

    always = Enum.find(coverage, &(&1.id == :always_runs))
    never = Enum.find(coverage, &(&1.id == :never_runs))

    assert always, "expected an :always_runs invariant in the coverage report"
    assert never, "expected a :never_runs invariant in the coverage report"

    assert always.covered?, "expected the every: 1 invariant to be covered"
    assert always.fire_count > 0

    refute never.covered?, "expected the never-emitted invariant to be uncovered"
    assert never.fire_count == 0
  end

  # ===========================================================================
  # Catalog enumeration (identity, default ids, inline id:, validates:, union)
  # ===========================================================================

  defmodule InlineProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    # Centralized declaration with a description, plus a second check that links
    # to the same invariant via validates: -- one invariant, two checks.
    @invariant id: :balanced, description: "Debits equal credits"

    @trigger every: 1, validates: :balanced
    def assert_balanced_each_step(_state, _), do: :ok

    @trigger at: :teardown, validates: :balanced
    def assert_balanced_at_end(_state, _phase), do: :ok

    # Inline declaration on the assertion itself.
    @trigger every: :command, id: :command_seen, description: "A command was observed"
    def assert_command_seen(_state, _), do: :ok
  end

  defmodule InlineModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Tick]
    @impl true
    def command_sequence_projection, do: GateProjection
    @impl true
    def assertion_projections, do: [InlineProjection]
  end

  test "catalog enumerates default, inline, and validates-linked invariants" do
    catalog = PropertyDamage.assertion_catalog(InlineModel)

    balanced = Enum.find(catalog, &(&1.projection == InlineProjection and &1.id == :balanced))
    assert balanced.invariant.description == "Debits equal credits"
    # One invariant, two checks (a synchronous every: and a lifecycle at:).
    assert length(balanced.checks) == 2
    kinds = balanced.checks |> Enum.map(& &1.kind) |> Enum.sort()
    assert kinds == [:lifecycle, :synchronous]

    command_seen =
      Enum.find(catalog, &(&1.projection == InlineProjection and &1.id == :command_seen))

    assert command_seen.invariant.description == "A command was observed"

    # The default-named invariants from GateProjection still appear.
    assert Enum.find(catalog, &(&1.projection == GateProjection and &1.id == :always_runs))
  end

  defmodule ReuseProjectionA do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}

    @trigger every: 1, id: :consistent
    def assert_a(_state, _), do: :ok
  end

  defmodule ReuseProjectionB do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}

    @trigger every: 1, id: :consistent
    def assert_b(_state, _), do: :ok
  end

  # ReuseProjectionA is listed BOTH as the command-sequence projection and as an
  # assertion projection (a doubly-listed projection); the catalog must dedup it.
  defmodule ReuseModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Tick]
    @impl true
    def command_sequence_projection, do: ReuseProjectionA
    @impl true
    def assertion_projections, do: [ReuseProjectionA, ReuseProjectionB]
  end

  test "two projections may reuse an id; the catalog keys by {projection, id} and dedups" do
    catalog = PropertyDamage.assertion_catalog(ReuseModel)

    consistent = Enum.filter(catalog, &(&1.id == :consistent))
    projections = consistent |> Enum.map(& &1.projection) |> Enum.sort()

    # Two distinct invariants share the id :consistent, one per projection, and
    # the doubly-listed ReuseProjectionA appears exactly once.
    assert projections == Enum.sort([ReuseProjectionA, ReuseProjectionB])
    assert length(consistent) == 2
  end

  # ===========================================================================
  # Firing from the lifecycle (at:) path (DR-024)
  # ===========================================================================

  defmodule LifecycleProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}

    @trigger at: :teardown
    def assert_settled(_state, _phase), do: :ok
  end

  defmodule LifecycleModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Tick]
    @impl true
    def command_sequence_projection, do: LifecycleProjection
  end

  test "a lifecycle at: assertion is counted as fired" do
    result =
      PropertyDamage.run(
        model: LifecycleModel,
        adapter: TickAdapter,
        max_runs: 3,
        max_commands: 3,
        validate: false,
        shrink: false
      )

    assert {:ok, _stats} = result

    settled =
      Enum.find(PropertyDamage.assertion_coverage(result, LifecycleModel), &(&1.id == :settled))

    assert settled.covered?
    assert settled.fire_count > 0
  end

  # ===========================================================================
  # The invariant's description flows into the failure report (failure-analysis)
  # ===========================================================================

  defmodule FailingProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}

    @trigger every: 1, id: :never_negative, description: "The counter is never negative"
    def assert_never_negative(_state, _) do
      PropertyDamage.fail!("boom")
    end
  end

  defmodule FailingModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Tick]
    @impl true
    def command_sequence_projection, do: FailingProjection
  end

  test "the failing invariant's name and description are stamped onto the report" do
    result =
      PropertyDamage.run(
        model: FailingModel,
        adapter: TickAdapter,
        max_runs: 5,
        max_commands: 5,
        validate: false,
        shrink: false
      )

    assert {:error, report} = result
    assert report.invariant_name == :never_negative
    assert report.invariant_description == "The counter is never negative"

    rendered = Formatter.format(report)
    assert rendered =~ "never_negative"
    assert rendered =~ "The counter is never negative"
  end

  # ===========================================================================
  # Per-assertion fire counts merge across parallel branches (execution-engine)
  # ===========================================================================

  defmodule BranchProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}

    @trigger every: :command
    def assert_cmd(_state, _), do: :ok
  end

  defmodule BranchModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Tick]
    @impl true
    def command_sequence_projection, do: BranchProjection
  end

  test "fire counts ride the additive branch merge across the branch boundary" do
    alias PropertyDamage.{Executor, Sequence}

    # Synchronous assertions are disabled INSIDE branches by design (branch
    # correctness is decided by the linearization check, not per-branch
    # sampling), so branch commands contribute a zero delta. The merge must
    # nonetheless preserve the prefix and suffix firings exactly: prefix (1
    # command) + suffix (1 command) = 2, with the two branch commands neither
    # lost nor double-counted.
    seq = Sequence.branching([%Tick{}], [[%Tick{}], [%Tick{}]], [%Tick{}])

    {:ok, queue} = PropertyDamage.EventQueue.start_link()

    result =
      try do
        {:ok, result} = Executor.run(seq, BranchModel, TickAdapter, event_queue: queue)
        result
      after
        PropertyDamage.EventQueue.stop(queue)
      end

    fired = Map.get(result.assertion_counters, {:fired, BranchProjection, :cmd}, 0)
    assert fired == 2
  end

  # ===========================================================================
  # Whole-run accumulation across sequences (guards the single-result bug)
  # ===========================================================================

  defmodule WholeRunProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}

    @trigger every: :command
    def assert_cmd(_state, _), do: :ok
  end

  defmodule WholeRunModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Tick]
    @impl true
    def command_sequence_projection, do: WholeRunProjection
  end

  test "fire counts accumulate across every generated sequence, not just the representative one" do
    result =
      PropertyDamage.run(
        model: WholeRunModel,
        adapter: TickAdapter,
        max_runs: 4,
        max_commands: 6,
        seed: 4242,
        validate: false,
        shrink: false
      )

    assert {:ok, stats} = result

    cmd = Enum.find(PropertyDamage.assertion_coverage(result, WholeRunModel), &(&1.id == :cmd))

    # every: :command fires once per command, so the whole-run fire count equals
    # the total commands across ALL sequences. A single-result coverage would
    # report only the last sequence's commands.
    assert cmd.fire_count == stats.total_commands
    assert stats.total_commands > 6, "expected more than one sequence's worth of commands"
  end

  # ===========================================================================
  # Firing from the @poll_state spawn path (eventual-consistency, DR-026)
  # ===========================================================================

  defmodule Started, do: defstruct([])

  defmodule Start do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule PollProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}

    # Spawning the poller counts as firing (the after: event arrived and
    # verification began). The predicate passes immediately, so no timeout.
    @poll_state after: Started, timeout: {200, :milliseconds}, interval: {10, :milliseconds}
    def eventually_ok(_state, %Started{}) do
      fn _s -> true end
    end
  end

  defmodule PollModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Start]
    @impl true
    def command_sequence_projection, do: PollProjection
  end

  defmodule PollAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Start{}, _ctx), do: {:ok, [%Started{}]}
  end

  test "spawning a @poll_state poller counts as firing the invariant" do
    result =
      PropertyDamage.run(
        model: PollModel,
        adapter: PollAdapter,
        max_runs: 3,
        max_commands: 3,
        validate: false,
        shrink: false
      )

    assert {:ok, _stats} = result

    inv =
      Enum.find(PropertyDamage.assertion_coverage(result, PollModel), &(&1.id == :eventually_ok))

    assert inv.kinds == [:polling]
    assert inv.covered?
    assert inv.fire_count > 0
  end

  # ===========================================================================
  # coverage: true tracker + strict anti-vacuity via meets_threshold?
  # ===========================================================================

  test "coverage: true attaches a whole-run tracker; strict assertion_coverage flags the vacuous one" do
    result =
      PropertyDamage.run(
        model: GateModel,
        adapter: TickAdapter,
        max_runs: 4,
        max_commands: 4,
        coverage: true,
        validate: false,
        shrink: false
      )

    assert {:ok, stats} = result
    assert %PropertyDamage.Coverage{} = stats.coverage

    # GateModel exercises :always_runs but never :never_runs, so strict
    # anti-vacuity (100%) must fail while a 0% floor passes.
    refute PropertyDamage.Coverage.meets_threshold?(stats.coverage, assertion_coverage: 100)
    assert PropertyDamage.Coverage.meets_threshold?(stats.coverage, assertion_coverage: 0)

    assert {GateProjection, :never_runs} in PropertyDamage.Coverage.uncovered_invariants(
             stats.coverage
           )
  end
end
