defmodule PropertyDamage.ProjectionPurityTest do
  @moduledoc """
  P8 / DR-040: the derived per-step state timeline and the projection-purity
  check, end-to-end through a real `Executor.run` + `FailureReport`.

  Done-gates exercised here:

    * a pure projection re-derives to the runtime snapshot (linear AND branching)
    * a deliberately-impure projection (reads a process counter in apply/2) fires
      the purity detector
    * a pure-but-async projection (an event folded outside command attribution)
      does NOT false-positive — the load-bearing case
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{EventQueue, Executor, FailureReport, RunTrace, Sequence}

  # ---- Events / commands ----------------------------------------------------

  defmodule Added, do: defstruct(amount: 0)
  defmodule Pinged, do: defstruct(amount: 0)
  defmodule Add, do: defstruct(amount: 0)
  defmodule Ping, do: defstruct(amount: 0)

  # ---- Projections ----------------------------------------------------------

  defmodule SeqProj do
    @moduledoc false
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{commands: 0}
    @impl true
    def apply(state, %Add{}), do: %{state | commands: state.commands + 1}
    def apply(state, %Ping{}), do: %{state | commands: state.commands + 1}
    def apply(state, _), do: state
  end

  # Pure: state is a function of the folded events only.
  defmodule Sum do
    @moduledoc false
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{sum: 0}
    @impl true
    def apply(state, %Added{amount: a}), do: %{state | sum: state.sum + a}
    def apply(state, %Pinged{amount: a}), do: %{state | sum: state.sum + a}
    def apply(state, _), do: state

    @trigger every: 1
    def under_limit(state, _item) do
      unless state.sum <= 100 do
        PropertyDamage.fail!("sum exceeds limit", sum: state.sum)
      end
    end
  end

  # Impure: reads a monotonically increasing process value in apply/2, so a
  # re-fold produces different state than the original run.
  defmodule Impure do
    @moduledoc false
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{ticks: []}
    @impl true
    def apply(state, %Added{}),
      do: %{state | ticks: [System.unique_integer([:monotonic]) | state.ticks]}

    def apply(state, _), do: state
  end

  # ---- Models ---------------------------------------------------------------

  defmodule PureModel do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Add, Ping]
    @impl true
    def command_sequence_projection, do: SeqProj
    @impl true
    def assertion_projections, do: [Sum]
  end

  defmodule ImpureModel do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Add, Ping]
    @impl true
    def command_sequence_projection, do: SeqProj
    @impl true
    def assertion_projections, do: [Sum, Impure]
  end

  # ---- Adapter --------------------------------------------------------------

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter
    alias PropertyDamage.EventQueue

    @impl true
    def setup(config), do: {:ok, %{queue: config[:event_queue]}}
    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Add{amount: a}, _ctx, _runtime), do: {:ok, [%Added{amount: a}]}

    # Ping pushes an async event onto the queue and returns no command events, so
    # the async event is folded by the injector drain (command-unattributed),
    # outside the command/events attribution the canonical timeline uses.
    def execute(%Ping{amount: a}, %{queue: queue}, _runtime) do
      EventQueue.push(queue, __MODULE__, %Pinged{amount: a})
      {:ok, []}
    end
  end

  defp run(model, sequence) do
    {:ok, queue} = EventQueue.start_link()

    try do
      Executor.run(sequence, model, Adapter,
        adapter_config: %{event_queue: queue},
        event_queue: queue
      )
    after
      EventQueue.stop(queue)
    end
  end

  defp report(model, sequence) do
    {:ok, result} = run(model, sequence)
    refute result.success, "expected the run to fail so a report has snapshots"

    FailureReport.new(
      seed: 1,
      run_number: 0,
      original_sequence: sequence,
      shrunk_sequence: sequence,
      plan_source: :generated,
      failed_at_index: result.failed_at_index,
      failure_reason: result.failure_reason,
      event_log: result.event_log,
      executed: Map.get(result, :executed, %{}),
      projections: result.projections,
      projections_before: result.projections_before,
      command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
      linearization: result.linearization,
      model: model,
      adapter: Adapter
    )
  end

  describe "faithful derivation equals the runtime snapshot (linear)" do
    test "a pure projection passes the purity check" do
      seq = Sequence.linear([%Add{amount: 30}, %Add{amount: 80}])
      report = report(PureModel, seq)

      assert report.failed_at_index == 1
      # Snapshots the executor actually recorded:
      assert report.state_at_failure[Sum] == %{sum: 110}
      assert report.state_before_failure[Sum] == %{sum: 30}

      # Faithful derivation reproduces both exactly.
      pos = FailureReport.failure_step(report).position
      assert RunTrace.state_at(report.trace, pos) == report.state_at_failure
      assert RunTrace.state_before(report.trace, pos) == report.state_before_failure

      assert FailureReport.verify_projections(report) == :ok
    end
  end

  describe "impure projection detection" do
    test "a projection reading a process counter in apply/2 fires the detector" do
      seq = Sequence.linear([%Add{amount: 30}, %Add{amount: 80}])
      report = report(ImpureModel, seq)

      assert {:non_pure_projections, modules} = FailureReport.verify_projections(report)
      assert Impure in modules
      # The pure projection is NOT accused.
      refute Sum in modules
    end
  end

  describe "pure-but-async does not false-positive (load-bearing)" do
    test "an async queue event folded outside attribution still verifies pure" do
      # cmd0 Add 30 -> sum 30; cmd1 Ping pushes Pinged 30, drained async -> sum 60;
      # cmd2 Add 50 -> sum 110 -> fails at cmd2. The async Pinged is folded at the
      # injector drain (command_index nil), i.e. outside command attribution.
      seq = Sequence.linear([%Add{amount: 30}, %Ping{amount: 30}, %Add{amount: 50}])
      report = report(PureModel, seq)

      assert report.failed_at_index == 2
      assert report.state_at_failure[Sum] == %{sum: 110}

      pos = FailureReport.failure_step(report).position

      # Faithful includes the async event at its real fold point -> matches.
      assert RunTrace.state_at(report.trace, pos) == report.state_at_failure
      assert FailureReport.verify_projections(report) == :ok

      # Proof the test actually exercises async reordering: the CANONICAL
      # (attribution-order) timeline excludes the command-unattributed async
      # event, so it would diverge from the snapshot. Using it for the purity
      # check would false-positive; using faithful does not.
      canonical =
        report.trace
        |> RunTrace.canonical_state_timeline()
        |> Enum.find(fn {p, _state} -> p == pos end)
        |> elem(1)

      assert canonical[Sum] == %{sum: 80}
      refute canonical == report.state_at_failure
    end
  end

  describe "mix pd.audit projection-purity (generation-side, no adapter)" do
    alias PropertyDamage.Test.Commands.CreateItem
    alias PropertyDamage.Test.Events.ItemCreated
    alias PropertyDamage.Test.Projections.ModelState

    defmodule ImpureEventProj do
      @moduledoc false
      use PropertyDamage.Model.Projection
      @impl true
      def init, do: %{seen: []}
      @impl true
      def apply(state, %ItemCreated{}),
        do: %{state | seen: [System.unique_integer([:monotonic]) | state.seen]}

      def apply(state, _), do: state
    end

    defmodule GenPureModel do
      @moduledoc false
      @behaviour PropertyDamage.Model
      @behaviour PropertyDamage.Model.Simulator
      @impl true
      def commands, do: [CreateItem]
      @impl true
      def command_sequence_projection, do: ModelState
      @impl true
      def assertion_projections, do: []
      @impl true
      def simulator, do: __MODULE__
      @impl PropertyDamage.Model.Simulator
      def simulate(%CreateItem{name: n, quantity: q}, _state),
        do: [%ItemCreated{item_ref: nil, name: n, quantity: q}]
    end

    defmodule GenImpureModel do
      @moduledoc false
      @behaviour PropertyDamage.Model
      @behaviour PropertyDamage.Model.Simulator
      @impl true
      def commands, do: [CreateItem]
      @impl true
      def command_sequence_projection, do: ModelState
      @impl true
      def assertion_projections, do: [ImpureEventProj]
      @impl true
      def simulator, do: __MODULE__
      @impl PropertyDamage.Model.Simulator
      def simulate(%CreateItem{name: n, quantity: q}, _state),
        do: [%ItemCreated{item_ref: nil, name: n, quantity: q}]
    end

    test "passes for a pure model" do
      assert PropertyDamage.audit_projections(GenPureModel, seeds: 20) == :ok
    end

    test "names the impure projection module" do
      assert {:error, %{modules: modules}} =
               PropertyDamage.audit_projections(GenImpureModel, seeds: 20)

      assert ImpureEventProj in modules
    end
  end

  describe "faithful derivation equals the runtime snapshot (branching)" do
    test "a branching run failing in the suffix re-derives through the branch merge" do
      # prefix Add 10, two branches each Add 10, suffix Add 85 -> sum 115 at the
      # suffix command. Branch assertions are disabled; the suffix re-enables them
      # and Sum fires there, on the merged-then-suffix state.
      seq =
        Sequence.branching(
          [%Add{amount: 10}],
          [[%Add{amount: 10}], [%Add{amount: 10}]],
          [%Add{amount: 85}]
        )

      report = report(PureModel, seq)

      assert %Sequence.Position{section: :suffix} =
               pos = FailureReport.failure_step(report).position

      assert report.state_at_failure[Sum] == %{sum: 115}

      assert RunTrace.state_at(report.trace, pos) == report.state_at_failure
      assert RunTrace.state_before(report.trace, pos) == report.state_before_failure
      assert FailureReport.verify_projections(report) == :ok
    end
  end
end
