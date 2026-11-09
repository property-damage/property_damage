defmodule PropertyDamage.AnalysisMocksTest do
  @moduledoc """
  `Analysis.isolate_trigger/2` reruns the sequence on the target the report
  recorded, mocks included, so each varied amount is judged against the mock
  the run used.

  The fixture's fraud mock approves every charge when it is set up buggy, and
  a check rejects an approved charge over 50. A rerun that drops the mock
  would see an honest service, decline the charge of 80 and accept every
  amount, including 79 and 81.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Analysis, MockServiceRegistry, Runtime}

  defmodule ChargeSubmitted do
    defstruct [:amount, :status]
  end

  defmodule FraudChecked do
    defstruct [:amount, :approved]
  end

  defmodule Charge do
    @behaviour PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides) do
      %{amount: StreamData.constant(80)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Charges do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: FraudChecked
    def assert_high_declined(_state, %FraudChecked{amount: amount, approved: approved}) do
      amount <= 50 or not approved or
        PropertyDamage.fail!("over-limit charge approved", amount: amount)
    end
  end

  defmodule FraudMock do
    use PropertyDamage.MockServiceAdapter

    @emits [FraudChecked]

    @impl true
    def setup(config) do
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
    def on_command(_command, state), do: state

    @impl true
    def handle_request(%{body: %{"amount" => amount}}, state) do
      approved = state.buggy or amount <= 50

      {:ok, %{status: if(approved, do: 200, else: 402), body: %{approved: approved}},
       [%FraudChecked{amount: amount, approved: approved}]}
    end
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Charge{amount: amount}, _ctx, %Runtime{mock_registry: registry}) do
      {:ok, mock_state} = MockServiceRegistry.get_handler_state(registry, FraudMock)

      {:ok, response, events} =
        FraudMock.handle_request(%{path: "/check", body: %{"amount" => amount}}, mock_state)

      :ok = MockServiceRegistry.push_events(registry, FraudMock, events)
      {:ok, [%ChargeSubmitted{amount: amount, status: response.status}]}
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands, do: [Charge]

    @impl true
    def command_sequence_projection, do: Charges

    @impl true
    def check_projections, do: [Charges]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(_command, _state), do: []
  end

  setup do
    {:error, report} =
      PropertyDamage.run(
        model: Model,
        targets: [{Adapter, mocks: [{FraudMock, %{buggy: true}}]}],
        max_runs: 5,
        max_commands: 4,
        seed: 7,
        verbose: false,
        replay_dir: false
      )

    %{report: report}
  end

  test "lists the amounts the buggy mock accepts, which only the recorded mock can tell", %{
    report: report
  } do
    assert {:ok, %{trigger_command: %Charge{amount: 80}, changes: changes}} =
             Analysis.isolate_trigger(report)

    assert changes |> Enum.map(& &1.fixed) |> Enum.sort() == [0, 1, 40]
  end
end
