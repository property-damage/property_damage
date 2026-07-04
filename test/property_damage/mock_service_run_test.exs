defmodule PropertyDamage.MockServiceRunTest do
  @moduledoc """
  WP-C5: MockServiceAdapter is reachable from the public `PropertyDamage.run/1`.

  Proves the framework owns the mock lifecycle end-to-end: it starts a
  `MockServiceRegistry`, registers + `setup/1`s each declared mock, drives
  `on_command/2` before each command, hands the adapter the registry through the
  `Runtime` handle so the SUT stand-in can call `handle_request/2`, folds the
  mock-injected events (`source: :mock`) into projections, and tears the mock
  down. The recorder Agent below is written to ONLY from inside
  `handle_request/2`, so a non-zero count is direct proof that callback ran
  through a public `run/1` call.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{MockServiceRegistry, Runtime}

  # --- shared events ---------------------------------------------------------

  defmodule ChargeSubmitted do
    defstruct [:amount, :status]
  end

  defmodule FraudChecked do
    defstruct [:amount, :approved]
  end

  # --- a plain (non-HTTP) recorder proving handle_request/2 ran --------------

  defmodule Recorder do
    use Agent

    def start, do: Agent.start_link(fn -> 0 end, name: __MODULE__)
    # Linked to the test process, so by the time on_exit runs the agent may
    # already be terminating: whereis can still return a pid whose stop then
    # exits :noproc. Tolerate that race.
    def stop do
      if pid = Process.whereis(__MODULE__) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end

    def bump, do: Agent.update(__MODULE__, &(&1 + 1))
    def count, do: Agent.get(__MODULE__, & &1)
  end

  # --- the command -----------------------------------------------------------

  defmodule Charge do
    @behaviour PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides) do
      %{amount: StreamData.constant(10)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # --- projection: mock-injected events steer the asserted state -------------

  defmodule ChargeState do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{checks: 0, last: nil}

    @impl true
    def apply(state, %ChargeSubmitted{}), do: state

    def apply(state, %FraudChecked{amount: a, approved: ap}),
      do: %{state | checks: state.checks + 1, last: {a, ap}}

    def apply(state, _), do: state

    # An over-limit charge (> 50) must be declined by the fraud service. A buggy
    # mock that approves it trips this. Fires on the mock-injected event, so the
    # assertion is only reachable BECAUSE handle_request/2 injected it.
    @trigger every: FraudChecked
    def assert_high_declined(_state, %FraudChecked{amount: a, approved: ap}) do
      if a > 50 and ap do
        PropertyDamage.fail!("over-limit charge approved by fraud service", amount: a)
      end
    end
  end

  # --- the mock service (in-process, pure handle_request/2) ------------------

  defmodule FraudMock do
    use PropertyDamage.MockServiceAdapter

    alias PropertyDamage.MockServiceRegistry

    @emits [FraudChecked]

    @impl true
    def setup(config) do
      # The framework passes :registry and :event_queue here (the documented
      # contract); a real mock would start an HTTP listener closing over them.
      # Seed the mock's initial state from the entry config (the kratos-bench
      # pattern), since init_state/0 is arg-less.
      registry = config[:registry]

      if config[:buggy] do
        {:ok, state} = MockServiceRegistry.get_state(registry, __MODULE__)
        :ok = MockServiceRegistry.update_state(registry, __MODULE__, %{state | buggy: true})
      end

      {:ok, %{registry: registry}}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def init_state, do: %{buggy: false}

    @impl true
    def on_command(%Charge{}, state), do: state
    def on_command(_other, state), do: state

    @impl true
    def handle_request(%{body: %{"amount" => amount}}, state) do
      Recorder.bump()
      # Honest fraud check: decline over-limit. Buggy variant approves everything.
      approved = state.buggy or amount <= 50
      status = if approved, do: 200, else: 402

      {:ok, %{status: status, body: %{approved: approved}},
       [%FraudChecked{amount: amount, approved: approved}]}
    end
  end

  # --- the SUT stand-in adapter: reaches the mock via runtime.mock_registry --

  defmodule ChargeAdapter do
    use PropertyDamage.Adapter

    alias PropertyDamage.MockServiceRegistry

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Charge{amount: amt}, _ctx, %Runtime{mock_registry: reg}) do
      # The SUT calls out to the third party; here the mock stands in and the
      # registry travels on the runtime handle (no HTTP needed for the test).
      {:ok, mstate} = MockServiceRegistry.get_handler_state(reg, FraudMock)

      {:ok, resp, events} =
        FraudMock.handle_request(%{path: "/check", body: %{"amount" => amt}}, mstate)

      :ok = MockServiceRegistry.push_events(reg, FraudMock, events)
      {:ok, [%ChargeSubmitted{amount: amt, status: resp.status}]}
    end
  end

  # --- models ----------------------------------------------------------------

  defmodule HappyModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [Charge]
    @impl true
    def command_sequence_projection, do: ChargeState
    @impl true
    def assertion_projections, do: [ChargeState]
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_c, _s), do: []
  end

  defmodule BuggyModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [{Charge, with: fn _ -> %{amount: StreamData.constant(80)} end}]
    @impl true
    def command_sequence_projection, do: ChargeState
    @impl true
    def assertion_projections, do: [ChargeState]
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_c, _s), do: []
  end

  setup do
    Recorder.stop()
    {:ok, _} = Recorder.start()
    on_exit(&Recorder.stop/0)
    :ok
  end

  test "handle_request/2 is driven through a public run/1 call" do
    assert {:ok, stats} =
             PropertyDamage.run(
               model: HappyModel,
               adapter: ChargeAdapter,
               mock_services: [FraudMock],
               max_runs: 3,
               max_commands: 4,
               seed: 1,
               shrink: false
             )

    assert stats.runs == 3
    # The recorder only advances inside handle_request/2; a non-zero count proves
    # the callback ran through run/1 (not merely that the run completed).
    assert Recorder.count() > 0
  end

  test "mock-steered failure is caught and shrinks (mock active during shrink)" do
    assert {:error, report} =
             PropertyDamage.run(
               model: BuggyModel,
               adapter: ChargeAdapter,
               mock_services: [{FraudMock, %{buggy: true}}],
               max_runs: 5,
               max_commands: 6,
               seed: 7
             )

    # A single over-limit Charge is enough; shrinking (which re-runs many times)
    # must keep the mock live, or the minimal repro would stop reproducing.
    shrunk = PropertyDamage.FailureReport.shrunk_sequence(report)
    assert PropertyDamage.Sequence.command_count(shrunk) == 1
  end

  test "mock config tuple seeds the mock's setup" do
    # {module, config} entries are accepted and the config reaches the mock.
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: HappyModel,
               adapter: ChargeAdapter,
               mock_services: [{FraudMock, %{}}],
               max_runs: 1,
               max_commands: 2,
               seed: 3,
               shrink: false
             )
  end
end
