defmodule PropertyDamage.ExecutorSettledTest do
  @moduledoc """
  End-to-end characterization of `execute_regular_command`'s `{:settled, events}`
  arm (probe/async commands that settle via `Settle`) and of the `:record` /
  `:log` assertion modes.

  These are characterization tests: they pin down the observable behavior of the
  settled path and the record/log modes so the F1 refactor (folding the two
  identical `{:ok, events}` / `{:settled, events}` success arms into one shared
  pipeline) is provably behavior-preserving. They pass on `main` before the fold
  and must still pass after it.

  A `{:settled, events}` return reaches the executor when the *adapter* returns
  `{:settled, events}` (Settle passes it through), realistically for a probe/async
  command after one or more `{:retry, _}` attempts. The sync path returns
  `{:ok, events}`; both success arms run an identical post-events pipeline.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PropertyDamage.{EventQueue, Executor}

  # credo's AliasOrder sorts a multi-alias by its first member, so
  # PropertyDamage.Test.{FailingModel, ...} sorts as ...Test.FailingModel and
  # belongs between Test.Events and Test.Projections.
  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}
  alias PropertyDamage.Test.{FailingModel, SimpleAdapter, SimpleInjectorAdapter}
  alias PropertyDamage.Test.Projections.{FailingAssertion, ModelState}

  # A probe command that settles after two {:retry, _} attempts. It carries the
  # same fields the sync CreateItem does so the produced event drives the exact
  # same projections and @trigger every: assertion, making the settled path
  # directly comparable to the sync path.
  defmodule SettledCreate do
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 2_000, interval_ms: 5, backoff: :linear}

    defstruct [:name, :quantity]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # Adapter for SettledCreate: returns {:retry, _} for the first two attempts of a
  # command, then {:settled, [%ItemCreated{}]}. The attempt counter is a
  # cross-process atomics ref (execute/3 runs in a child Task under DR-032), reset
  # per run in setup/1. These characterization runs use single-command sequences,
  # so one counter per run tracks the one command's settle loop.
  defmodule RetryThenSettleAdapter do
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Events.ItemCreated

    @impl true
    def setup(config) do
      {:ok, config |> Map.new() |> Map.put(:attempts, :atomics.new(1, []))}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%SettledCreate{name: name, quantity: qty}, %{attempts: ref}, _runtime) do
      attempt = :atomics.add_get(ref, 1, 1)

      if attempt >= 3 do
        {:settled, [%ItemCreated{item_ref: "settled_item", name: name, quantity: qty}]}
      else
        {:retry, :not_settled_yet}
      end
    end
  end

  # Model wiring the probe command to the same FailingAssertion (@trigger every: 1,
  # fails once cumulative quantity exceeds 100) the sync FailingModel uses.
  defmodule SettledModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    alias PropertyDamage.Test.Events.ItemCreated

    @impl true
    def commands, do: [SettledCreate]

    @impl true
    def command_sequence_projection, do: ModelState

    @impl true
    def assertion_projections, do: [FailingAssertion]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%SettledCreate{name: name, quantity: quantity}, _state) do
      [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
    end
  end

  describe "{:settled, events} success arm" do
    test "a probe command that settles records its event and updates projections" do
      command = %SettledCreate{name: "Widget", quantity: 10}

      {:ok, result} = Executor.run([command], SettledModel, RetryThenSettleAdapter)

      assert result.success == true
      assert result.failure_reason == nil

      # The settled event is recorded exactly like a sync {:ok, _} command event.
      assert [entry] = result.event_log
      assert entry.source == :command
      assert entry.command_index == 0
      assert %ItemCreated{name: "Widget", quantity: 10} = entry.event

      # Command-sequence projection folded the settled event.
      model_state = result.projections[ModelState]
      assert Map.has_key?(model_state.items, "settled_item")
      assert model_state.items["settled_item"].name == "Widget"
    end
  end

  describe "{:settled, events} arm: @trigger every: assertion failure" do
    test "a settled event that trips an every: assertion fails identically to the sync path" do
      # Sync equivalent: CreateItem over the same limit fails with this shape.
      {:ok, sync_result} =
        Executor.run([%CreateItem{name: "Big", quantity: 150}], FailingModel, SimpleAdapter)

      assert sync_result.success == false
      assert {:assertion_failed, :quantity_limit, sync_exception} = sync_result.failure_reason
      assert %PropertyDamage.AssertionFailed{} = sync_exception

      # Settled path: the probe command's settled event drives the same
      # @trigger every: 1 assertion and must produce the same failure_reason shape.
      {:ok, settled_result} =
        Executor.run(
          [%SettledCreate{name: "Big", quantity: 150}],
          SettledModel,
          RetryThenSettleAdapter
        )

      assert settled_result.success == false
      assert settled_result.failed_at_index == 0

      assert {:assertion_failed, :quantity_limit, settled_exception} =
               settled_result.failure_reason

      assert %PropertyDamage.AssertionFailed{} = settled_exception
    end
  end

  describe "{:settled, events} arm: async injector events fold in" do
    test "injector events are drained and folded through the settled arm" do
      {:ok, queue} = EventQueue.start_link()

      # An injector event enqueued before execution is drained by the command's
      # post-events pipeline (process_injector_events), the same code both success
      # arms run.
      EventQueue.push(queue, SimpleInjectorAdapter, %ItemViewed{item_ref: "injected"})

      {:ok, result} =
        Executor.run(
          [%SettledCreate{name: "Widget", quantity: 5}],
          SettledModel,
          RetryThenSettleAdapter,
          event_queue: queue
        )

      assert result.success == true

      # Both the settled command event and the drained injector event are logged.
      assert length(result.event_log) == 2

      injector_entry = Enum.find(result.event_log, &(&1.source == :injector))
      assert injector_entry != nil
      assert %ItemViewed{item_ref: "injected"} = injector_entry.event

      # The injector event's projection effect (view_count) was applied.
      assert result.projections[ModelState].view_count == 1

      EventQueue.stop(queue)
    end
  end

  describe "assertion_mode: :record (end-to-end)" do
    test "a check failure is recorded, the run completes, and success is false" do
      {:ok, result} =
        Executor.run(
          [%CreateItem{name: "Huge", quantity: 150}],
          FailingModel,
          SimpleAdapter,
          assertion_mode: :record
        )

      # :record => run completes to a non-halted result with failure_reason nil,
      # success false, and the failure captured in assertion_failures.
      assert result.success == false
      assert result.failure_reason == nil
      refute Enum.empty?(result.assertion_failures)

      failure = hd(result.assertion_failures)
      assert failure.assertion_name == :quantity_limit
      assert failure.command_index == 0

      # The command still executed and its event is in the log.
      assert length(result.event_log) == 1
    end
  end

  describe "assertion_mode: :log (end-to-end)" do
    test "a check failure is only logged: run completes, succeeds, nothing recorded" do
      {result, log} =
        with_log(fn ->
          {:ok, result} =
            Executor.run(
              [%CreateItem{name: "Huge", quantity: 150}],
              FailingModel,
              SimpleAdapter,
              assertion_mode: :log
            )

          result
        end)

      # :log => the failure is neither halted nor recorded; the run succeeds.
      assert result.success == true
      assert result.failure_reason == nil
      assert result.assertion_failures == []

      # The failure was emitted as a log warning.
      assert log =~ "Assertion failed"
      assert log =~ "quantity_limit"

      # The command still executed and its event is in the log.
      assert length(result.event_log) == 1
    end
  end
end
