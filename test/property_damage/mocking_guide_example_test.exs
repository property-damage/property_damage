defmodule PropertyDamage.MockingGuideExampleTest do
  @moduledoc """
  The complete example of `guides/mocking_third_parties.md` (the payment
  gateway mock, its configuration command, projections and model) run end to
  end through `PropertyDamage.run/1`.

  The module bodies are the guide's, placed under this module so their names
  do not collide. What the guide leaves to the reader is defined here: a stub
  `MockServer`, the commands and event the guide calls ordinary (`CreateOrder`,
  `SubmitPayment`, `OrderCreated`), and the adapter that plays the SUT.
  """
  use ExUnit.Case, async: false

  # --- what the guide leaves to the reader -----------------------------------

  defmodule MockServer do
    @moduledoc false
    def start_link(opts), do: Agent.start_link(fn -> opts end)
    def stop(pid), do: Agent.stop(pid)
  end

  defmodule OrderCreated do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, id: external()]
  end

  defmodule PaymentSubmitted do
    @moduledoc false
    defstruct [:order_id, :status]
  end

  defmodule CreateOrder do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(1..100)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule SubmitPayment do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:order_id, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{order_id: StreamData.constant(nil), amount: StreamData.integer(1..100)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # --- the guide's Events ----------------------------------------------------

  defmodule PaymentAuthorized do
    import PropertyDamage, only: [external: 0]
    defstruct [:order_id, :amount, transaction_id: external()]
  end

  defmodule PaymentDeclined do
    defstruct [:order_id, :reason]
  end

  # --- the guide's Configuration Command -------------------------------------

  defmodule ConfigurePaymentProvider do
    use PropertyDamage.Command

    defstruct [:behavior, :reason]

    @impl true
    def generator(overrides \\ %{}) do
      %{
        behavior: StreamData.member_of([:success, :decline, :timeout]),
        reason:
          StreamData.member_of([nil, "insufficient_funds", "card_expired", "fraud_detected"])
      }
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # --- the guide's Mock Module -----------------------------------------------

  defmodule PaymentGatewayMock do
    use PropertyDamage.MockServiceAdapter

    @emits [PaymentAuthorized, PaymentDeclined]

    @impl true
    def setup(config) do
      {:ok, pid} = MockServer.start_link(port: config[:port] || 4445, handler: __MODULE__)
      {:ok, %{server: pid}}
    end

    @impl true
    def teardown(%{server: pid}) do
      MockServer.stop(pid)
      :ok
    end

    @impl true
    def init_state do
      %{
        behavior: :success,
        decline_reason: nil,
        authorized_count: 0
      }
    end

    @impl true
    def on_command(%ConfigurePaymentProvider{behavior: b, reason: r}, state) do
      %{state | behavior: b, decline_reason: r}
    end

    def on_command(_cmd, state), do: state

    @impl true
    def on_event(%PaymentAuthorized{}, state), do: update_in(state.authorized_count, &(&1 + 1))
    def on_event(_event, state), do: state

    @impl true
    def handle_request(%{path: "/authorize", body: body}, state) do
      case state.behavior do
        :success ->
          resp = %{
            status: 200,
            body: %{transaction_id: "txn_#{System.unique_integer([:positive])}"}
          }

          events = [%PaymentAuthorized{order_id: body["order_id"], amount: body["amount"]}]
          {:ok, resp, events}

        :decline ->
          resp = %{status: 402, body: %{error: state.decline_reason}}
          events = [%PaymentDeclined{order_id: body["order_id"], reason: state.decline_reason}]
          {:ok, resp, events}

        :timeout ->
          # {:error, term} simulates a connection failure and carries no events.
          {:error, :timeout}

        :partial_failure ->
          # Authorize succeeds but with a warning flag
          resp = %{
            status: 200,
            body: %{transaction_id: "txn_partial", warning: "retry_suggested"}
          }

          events = [%PaymentAuthorized{order_id: body["order_id"], amount: body["amount"]}]
          {:ok, resp, events}
      end
    end

    def handle_request(_request, _state) do
      {:ok, %{status: 404, body: %{error: "not_found"}}}
    end
  end

  # --- the guide's Model Integration -----------------------------------------

  defmodule PaymentState do
    use PropertyDamage.Model.Projection

    def init, do: %{orders: %{}}

    def apply(state, %OrderCreated{id: id, amount: amt}),
      do: put_in(state, [:orders, id], %{amount: amt})

    def apply(state, _event), do: state
  end

  # --- the guide's Rollback Invariant ----------------------------------------

  defmodule PaymentInvariant do
    use PropertyDamage.Model.Projection

    def init, do: %{orders: %{}, payments: %{}}

    def apply(state, %OrderCreated{id: id, amount: amt}) do
      put_in(state, [:orders, id], %{amount: amt, status: :pending})
    end

    def apply(state, %PaymentAuthorized{order_id: id}) do
      put_in(state, [:orders, id, :status], :authorized)
    end

    def apply(state, %PaymentDeclined{order_id: id}) do
      put_in(state, [:orders, id, :status], :declined)
    end

    def apply(state, _), do: state

    @check every: PaymentDeclined
    def assert_rollback_on_decline(state, %PaymentDeclined{order_id: id}) do
      order = state.orders[id]

      order.status == :declined or
        PropertyDamage.fail!("order not rolled back after decline",
          order_id: id,
          status: order.status
        )
    end
  end

  defmodule PaymentTestModel do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands do
      [
        {CreateOrder, weight: 5},
        {SubmitPayment,
         weight: 3,
         when: fn s -> map_size(s.orders) > 0 end,
         overrides: fn s -> %{order_id: StreamData.member_of(Map.keys(s.orders))} end},
        # Low weight -- mostly success
        {ConfigurePaymentProvider, weight: 1}
      ]
    end

    @impl true
    def command_sequence_projection, do: PaymentState

    @impl true
    def check_projections, do: [PaymentInvariant]

    @impl true
    def simulator, do: __MODULE__

    # CreateOrder predicts an OrderCreated, which opens the `when:` guard.
    @impl PropertyDamage.Model.Simulator
    def simulate(%CreateOrder{amount: amount}, _state),
      do: [%OrderCreated{amount: amount}]

    def simulate(_command, _state), do: []
  end

  # --- the SUT stand-in: the guide's "in-process SUT" adapter ----------------

  defmodule PaymentAdapter do
    use PropertyDamage.Adapter

    alias PropertyDamage.MockServiceRegistry

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%CreateOrder{amount: amount}, ctx, _runtime) do
      id = "order-#{System.unique_integer([:positive])}"
      Agent.update(ctx.outcomes, &[:order | &1])
      {:ok, [%OrderCreated{id: id, amount: amount}]}
    end

    def execute(%ConfigurePaymentProvider{}, _ctx, _runtime), do: {:ok, []}

    def execute(%SubmitPayment{} = cmd, ctx, %PropertyDamage.Runtime{mock_registry: registry}) do
      {:ok, state} = MockServiceRegistry.get_handler_state(registry, PaymentGatewayMock)
      request = %{path: "/authorize", body: %{"order_id" => cmd.order_id, "amount" => cmd.amount}}

      case PaymentGatewayMock.handle_request(request, state) do
        {:ok, resp, events} ->
          outcome = if resp.status == 200, do: :authorized, else: :declined
          Agent.update(ctx.outcomes, &[outcome | &1])
          :ok = MockServiceRegistry.push_events(registry, PaymentGatewayMock, events)
          {:ok, [%PaymentSubmitted{order_id: cmd.order_id, status: resp.status}]}

        {:error, :timeout} ->
          Agent.update(ctx.outcomes, &[:timeout | &1])
          {:ok, [%PaymentSubmitted{order_id: cmd.order_id, status: :timeout}]}
      end
    end
  end

  test "the guide's payment gateway mock runs end to end through PropertyDamage.run/1" do
    {:ok, outcomes} = Agent.start_link(fn -> [] end)

    assert {:ok, stats} =
             PropertyDamage.run(
               model: PaymentTestModel,
               targets: [
                 {PaymentAdapter,
                  config: %{outcomes: outcomes}, mocks: [{PaymentGatewayMock, %{port: 4445}}]}
               ],
               max_runs: 10,
               max_commands: 12,
               seed: 11,
               shrink: false,
               validate: false,
               replay_dir: false
             )

    assert stats.runs == 10
    seen = Agent.get(outcomes, & &1)
    # The mock answered requests through the registry: the generated runs
    # create orders, configure the provider and submit payments.
    assert :order in seen
    assert Enum.any?(seen, &(&1 in [:authorized, :declined]))
  end

  test "a payment declined by the mock reaches the rollback invariant" do
    {:ok, outcomes} = Agent.start_link(fn -> [] end)

    # A model that always configures a decline, so every payment is declined
    # and PaymentDeclined is folded for the invariant to check.
    defmodule DeclineModel do
      @behaviour PropertyDamage.Model.Simulator
      use PropertyDamage.Model

      alias PropertyDamage.MockingGuideExampleTest.{
        ConfigurePaymentProvider,
        CreateOrder,
        OrderCreated,
        PaymentInvariant,
        PaymentState,
        SubmitPayment
      }

      @impl true
      def commands do
        [
          {CreateOrder, weight: 3},
          {SubmitPayment,
           weight: 6,
           when: fn s -> map_size(s.orders) > 0 end,
           overrides: fn s -> %{order_id: StreamData.member_of(Map.keys(s.orders))} end},
          {ConfigurePaymentProvider,
           weight: 1,
           overrides: fn _ ->
             %{
               behavior: StreamData.constant(:decline),
               reason: StreamData.constant("card_expired")
             }
           end}
        ]
      end

      @impl true
      def command_sequence_projection, do: PaymentState

      @impl true
      def check_projections, do: [PaymentInvariant]

      @impl true
      def simulator, do: __MODULE__

      @impl PropertyDamage.Model.Simulator
      def simulate(%CreateOrder{amount: amount}, _state), do: [%OrderCreated{amount: amount}]
      def simulate(_command, _state), do: []
    end

    assert {:ok, _stats} =
             PropertyDamage.run(
               model: DeclineModel,
               targets: [
                 {PaymentAdapter, config: %{outcomes: outcomes}, mocks: [PaymentGatewayMock]}
               ],
               max_runs: 10,
               max_commands: 12,
               seed: 5,
               shrink: false,
               validate: false,
               replay_dir: false
             )

    assert :declined in Agent.get(outcomes, & &1)
  end
end
