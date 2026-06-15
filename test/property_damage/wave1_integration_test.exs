defmodule PropertyDamage.Wave1IntegrationTest do
  @moduledoc """
  Integration coverage for the "wave-1" executor surface: nemesis fault
  injection, stutter (idempotency retries), resource pollers (@poll_state
  eventual consistency), and mid-execution event injection ("mocks") all in a
  SINGLE Executor.run sequence sharing one event log, projection set, and run
  loop. Each mechanism is tested in isolation elsewhere; this asserts they
  compose without interfering.

  The mechanisms are deliberately attached to different commands so the test
  stays deterministic (stutter timing does not race the poller, etc.) while
  still exercising the combined run loop.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{EventQueue, Executor, Sequence}
  alias PropertyDamage.Stutter.Config

  defmodule Events do
    defmodule Initiated, do: defstruct([:id])
    defmodule Confirmed, do: defstruct([:id])
    defmodule MockArrived, do: defstruct([:id])
    defmodule Charged, do: defstruct([:id])
    defmodule FaultInjected, do: defstruct([:kind])
  end

  defmodule InitiatePayment do
    @behaviour PropertyDamage.Command
    defstruct [:id]
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{id: "p1"})
  end

  defmodule Charge do
    @behaviour PropertyDamage.Command
    defstruct [:id]
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{id: "p1"})
  end

  # A nemesis command: dispatched to inject/2, not the adapter.
  defmodule LatencyFault do
    @behaviour PropertyDamage.Nemesis
    defstruct [:ms]

    @impl true
    def precondition(_state), do: true

    @impl true
    def inject(%__MODULE__{ms: _ms}, _ctx) do
      {:ok, [%Events.FaultInjected{kind: :latency}]}
    end

    @impl true
    def restore(%__MODULE__{}, _ctx), do: {:ok, []}
  end

  defmodule Projection do
    use PropertyDamage.Model.Projection

    alias Events.{Charged, Confirmed, Initiated, MockArrived}

    @impl true
    def init, do: %{status: %{}, mocked: %{}, charged: MapSet.new()}

    @impl true
    def apply(state, %Initiated{id: id}), do: put_in(state.status[id], :initiated)
    def apply(state, %Confirmed{id: id}), do: put_in(state.status[id], :confirmed)
    def apply(state, %MockArrived{id: id}), do: put_in(state.mocked[id], true)
    def apply(state, %Charged{id: id}), do: %{state | charged: MapSet.put(state.charged, id)}
    def apply(state, _), do: state

    # Synchronous invariant fired after every step (including after the nemesis
    # command): every tracked payment is in a known status.
    @trigger every: 1
    def assert_status_valid(state, _cmd_or_event) do
      bad = Enum.reject(Map.values(state.status), &(&1 in [:initiated, :confirmed]))

      if bad != [] do
        PropertyDamage.fail!("Payment in an invalid status", bad: bad)
      end
    end

    # Eventual consistency: the confirmation arrives via a resource poller after
    # InitiatePayment returns.
    @poll_state after: Initiated,
                timeout: {300, :milliseconds},
                interval: {10, :milliseconds}
    def payment_eventually_confirmed(_state, %Initiated{id: id}) do
      fn s -> s.status[id] == :confirmed end
    end
  end

  defmodule Simulator do
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def simulate(%InitiatePayment{id: id}, _state), do: [%Events.Initiated{id: id}]
    def simulate(%Charge{id: id}, _state), do: [%Events.Charged{id: id}]
    def simulate(_, _), do: []
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [InitiatePayment, Charge]
    @impl true
    def command_sequence_projection, do: Projection
    @impl true
    def assertion_projections, do: [Projection]
    @impl true
    def simulator, do: Simulator
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    alias Events.{Charged, Confirmed, Initiated, MockArrived}

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    # MOCKS (mid-execution injection) + POLLERS (out-of-band confirmation).
    @impl true
    def execute(%InitiatePayment{id: id}, ctx) do
      ctx.inject.(%MockArrived{id: id})

      ctx.start_poller.(
        poll_fn: fn -> :tick end,
        handler: fn _ -> {:done, [%Confirmed{id: id}]} end,
        interval_ms: 10,
        timeout_ms: 1000
      )

      {:ok, [%Initiated{id: id}]}
    end

    # STUTTER target: deterministically idempotent (same events every attempt).
    # Count executions so the test can prove the retry actually fired.
    def execute(%Charge{id: id}, ctx) do
      :counters.add(ctx.charge_counter, 1, 1)
      {:ok, [%Charged{id: id}]}
    end
  end

  test "nemesis + stutter + poller + injected events compose in one sequence" do
    sequence =
      Sequence.linear([
        %InitiatePayment{id: "p1"},
        %Charge{id: "p1"},
        %LatencyFault{ms: 5}
      ])

    stutter_config = %Config{
      probability: 1.0,
      max_repeats: 1,
      delay_ms: 0,
      commands: [Charge],
      comparison: :strict,
      enabled: true
    }

    {:ok, queue} = EventQueue.start_link()
    charge_counter = :counters.new(1, [:atomics])

    result =
      try do
        {:ok, result} =
          Executor.run(sequence, Model, Adapter,
            event_queue: queue,
            stutter_config: stutter_config,
            adapter_config: %{charge_counter: charge_counter}
          )

        result
      after
        EventQueue.stop(queue)
      end

    assert result.success,
           "combined wave-1 run failed: #{inspect(result.failure_reason)}"

    proj = result.projections[Projection]

    # POLLER: the out-of-band confirmation was observed.
    assert proj.status["p1"] == :confirmed
    # MOCKS: the injected event reached projections.
    assert proj.mocked["p1"] == true
    # STUTTER: the charge was retried (2 executions = 1 original + 1 retry)...
    assert :counters.get(charge_counter, 1) == 2,
           "expected the stutter retry to re-execute Charge once"

    # ...yet applied to projections exactly once (retries are not re-applied).
    assert MapSet.member?(proj.charged, "p1")

    sources = result.event_log |> Enum.map(& &1.source) |> Enum.uniq()
    # All three event provenances are present in one log.
    assert :command in sources
    assert :injected in sources
    assert :nemesis in sources

    # NEMESIS: the fault event was recorded.
    assert Enum.any?(result.event_log, &match?(%Events.FaultInjected{}, &1.event))
  end
end
