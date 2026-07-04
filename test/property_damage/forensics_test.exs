defmodule PropertyDamage.ForensicsTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Failure
  alias PropertyDamage.Forensics

  # Test events
  defmodule OrderCreated do
    defstruct [:order_id, :amount, :currency]
  end

  defmodule OrderShipped do
    defstruct [:order_id, :tracking_number]
  end

  defmodule PaymentReceived do
    defstruct [:order_id, :amount]
  end

  # Test projection (state)
  defmodule OrderState do
    @behaviour PropertyDamage.Model.Projection

    def init, do: %{orders: %{}, total_revenue: 0}

    def apply(state, %OrderCreated{order_id: id, amount: amount, currency: currency}) do
      order = %{amount: amount, currency: currency, status: :created}
      %{state | orders: Map.put(state.orders, id, order)}
    end

    def apply(state, %OrderShipped{order_id: id, tracking_number: tracking}) do
      case Map.get(state.orders, id) do
        nil ->
          state

        order ->
          updated_order = Map.merge(order, %{status: :shipped, tracking: tracking})
          %{state | orders: Map.put(state.orders, id, updated_order)}
      end
    end

    def apply(state, %PaymentReceived{order_id: _id, amount: amount}) do
      %{state | total_revenue: state.total_revenue + amount}
    end

    def apply(state, _), do: state
  end

  # Test assertion projection with assertions
  defmodule OrderInvariants do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{order_amounts: %{}}

    @impl true
    def apply(state, %OrderCreated{order_id: id, amount: amount}) do
      %{state | order_amounts: Map.put(state.order_amounts, id, amount)}
    end

    def apply(state, _), do: state

    @trigger every: 1
    def assert_no_negative_amounts(state, _cmd_or_event) do
      negative = Enum.filter(state.order_amounts, fn {_id, amt} -> amt < 0 end)

      unless Enum.empty?(negative) do
        PropertyDamage.fail!("Negative amounts found", negative_amounts: negative)
      end
    end
  end

  # Test model
  defmodule TestModel do
    @behaviour PropertyDamage.Model

    def commands, do: []
    def command_sequence_projection, do: OrderState
    def assertion_projections, do: [OrderInvariants]
  end

  # Assertion projection that only checks the most-recent event's amount, so each
  # violating event produces exactly one violation tied to that event (unlike
  # OrderInvariants, whose accumulated state keeps failing once any amount is negative).
  defmodule LastAmountInvariant do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{last_amount: nil}

    @impl true
    def apply(state, %OrderCreated{amount: amount}), do: %{state | last_amount: amount}
    def apply(state, _), do: state

    @trigger every: 1
    def assert_last_non_negative(%{last_amount: amount}, _cmd_or_event) do
      if is_number(amount) and amount < 0 do
        PropertyDamage.fail!("Negative amount", amount: amount)
      end
    end
  end

  defmodule PerEventModel do
    @behaviour PropertyDamage.Model

    def commands, do: []
    def command_sequence_projection, do: OrderState
    def assertion_projections, do: [LastAmountInvariant]
  end

  # Test event mapping
  defmodule TestEventMapping do
    @behaviour PropertyDamage.Forensics.EventMapping

    @impl true
    def map(%{"type" => "order.created", "data" => data}) do
      {:ok,
       %OrderCreated{
         order_id: data["order_id"],
         amount: data["amount"],
         currency: data["currency"]
       }}
    end

    def map(%{"type" => "order.shipped", "data" => data}) do
      {:ok,
       %OrderShipped{
         order_id: data["order_id"],
         tracking_number: data["tracking"]
       }}
    end

    def map(%{"type" => "internal.ignored"}) do
      :skip
    end

    def map(_) do
      {:skip, :unknown_event}
    end
  end

  describe "analyze/1" do
    test "processes events successfully with no violations" do
      events = [
        %OrderCreated{order_id: "order1", amount: 100, currency: "USD"},
        %OrderShipped{order_id: "order1", tracking_number: "TRACK123"},
        %PaymentReceived{order_id: "order1", amount: 100}
      ]

      result = Forensics.analyze(events: events, model: TestModel)

      assert {:ok, success} = result
      assert success.events_processed == 3
      assert success.final_state.orders["order1"].status == :shipped
      assert success.final_state.total_revenue == 100
      # A clean run records no violations.
      assert success.violations == []
    end

    test "detects invariant violations" do
      events = [
        %OrderCreated{order_id: "order1", amount: 100, currency: "USD"},
        # Negative amount violates invariant
        %OrderCreated{order_id: "order2", amount: -50, currency: "USD"}
      ]

      result = Forensics.analyze(events: events, model: TestModel)

      assert {:error, failure} = result
      assert failure.failure_step == 1

      assert %Failure{
               type: %Failure.Assertion{kind: :assertion_failed, name: :no_negative_amounts}
             } =
               failure.failure_reason

      assert failure.event_at_failure == %OrderCreated{
               order_id: "order2",
               amount: -50,
               currency: "USD"
             }
    end

    test "returns state before and after failure" do
      events = [
        %OrderCreated{order_id: "order1", amount: 100, currency: "USD"},
        %OrderCreated{order_id: "order2", amount: -50, currency: "USD"}
      ]

      {:error, failure} = Forensics.analyze(events: events, model: TestModel)

      # State before should not have order2
      refute Map.has_key?(failure.state_before[OrderInvariants].order_amounts, "order2")

      # State after should have order2
      assert Map.has_key?(failure.state_after[OrderInvariants].order_amounts, "order2")
    end

    test "collects every violation when stop_on_first_failure is false" do
      events = [
        %OrderCreated{order_id: "order1", amount: -10, currency: "USD"},
        %OrderCreated{order_id: "order2", amount: 100, currency: "USD"},
        %OrderCreated{order_id: "order3", amount: -20, currency: "USD"}
      ]

      result =
        Forensics.analyze(
          events: events,
          model: PerEventModel,
          stop_on_first_failure: false
        )

      # Should process all events despite failures
      assert {:ok, success} = result
      assert success.events_processed == 3

      # Both violating events are recorded (events 0 and 2; event 1 is valid).
      assert length(success.violations) == 2
      [v0, v1] = success.violations

      # Each violation carries the same detail shape as a stop-early failure.
      assert v0.failure_step == 0

      assert %Failure{type: %Failure.Assertion{kind: :assertion_failed, name: :last_non_negative}} =
               v0.failure_reason

      assert v0.event_at_failure == %OrderCreated{
               order_id: "order1",
               amount: -10,
               currency: "USD"
             }

      assert Map.has_key?(v0, :state_before)
      assert Map.has_key?(v0, :state_after)

      assert v0.events_leading_to_failure == [
               %OrderCreated{order_id: "order1", amount: -10, currency: "USD"}
             ]

      assert v1.failure_step == 2

      assert %Failure{type: %Failure.Assertion{kind: :assertion_failed, name: :last_non_negative}} =
               v1.failure_reason

      assert v1.event_at_failure == %OrderCreated{
               order_id: "order3",
               amount: -20,
               currency: "USD"
             }
    end

    test "uses event mapping to translate production events" do
      production_events = [
        %{
          "type" => "order.created",
          "data" => %{"order_id" => "p1", "amount" => 50, "currency" => "EUR"}
        },
        %{"type" => "order.shipped", "data" => %{"order_id" => "p1", "tracking" => "PROD123"}}
      ]

      result =
        Forensics.analyze(
          events: production_events,
          model: TestModel,
          event_mapping: TestEventMapping
        )

      assert {:ok, success} = result
      assert success.events_processed == 2
      assert success.final_state.orders["p1"].status == :shipped
    end

    test "skips events that mapping returns :skip for" do
      production_events = [
        %{
          "type" => "order.created",
          "data" => %{"order_id" => "p1", "amount" => 50, "currency" => "EUR"}
        },
        %{"type" => "internal.ignored"},
        %{"type" => "unknown.event"},
        %{"type" => "order.shipped", "data" => %{"order_id" => "p1", "tracking" => "X"}}
      ]

      result =
        Forensics.analyze(
          events: production_events,
          model: TestModel,
          event_mapping: TestEventMapping
        )

      assert {:ok, success} = result
      # Only 2 events processed (created and shipped), others skipped
      assert success.events_processed == 2
    end

    test "handles empty event list" do
      result = Forensics.analyze(events: [], model: TestModel)

      assert {:ok, success} = result
      assert success.events_processed == 0
      assert success.final_state == OrderState.init()
    end
  end

  describe "format_report/1" do
    test "formats failure report as readable string" do
      failure = %{
        failure_reason: Failure.assertion_failed(:no_negative_amounts, "Negative amounts found"),
        failure_step: 5,
        event_at_failure: %OrderCreated{order_id: "bad", amount: -100, currency: "USD"},
        state_before: %{},
        state_after: %{},
        events_leading_to_failure: [
          %OrderCreated{order_id: "good", amount: 100, currency: "USD"},
          %OrderCreated{order_id: "bad", amount: -100, currency: "USD"}
        ]
      }

      report = Forensics.format_report(failure)

      assert report =~ "FORENSIC ANALYSIS"
      assert report =~ "Event #5"
      assert report =~ "no_negative_amounts"
      assert report =~ "Negative amounts found"
    end
  end

  describe "generate_regression_test/2" do
    test "generates valid Elixir test code" do
      failure = %{
        failure_reason: Failure.assertion_failed(:some_check, "failed"),
        failure_step: 2,
        event_at_failure: %OrderCreated{order_id: "test", amount: 100, currency: "USD"},
        state_before: %{},
        state_after: %{},
        events_leading_to_failure: [
          %OrderCreated{order_id: "o1", amount: 50, currency: "EUR"},
          %OrderCreated{order_id: "test", amount: 100, currency: "USD"}
        ]
      }

      test_code = Forensics.generate_regression_test(failure, TestModel)

      assert test_code =~ "defmodule"
      assert test_code =~ "use ExUnit.Case"
      assert test_code =~ "test \"regression:"
      assert test_code =~ "PropertyDamage.Forensics.analyze"
      assert test_code =~ "failure.failure_step == 2"
    end

    test "generated code compiles clean" do
      failure = %{
        failure_reason: Failure.assertion_failed(:some_check, "failed"),
        failure_step: 2,
        event_at_failure: %OrderCreated{order_id: "test", amount: 100, currency: "USD"},
        state_before: %{},
        state_after: %{},
        events_leading_to_failure: [
          %OrderCreated{order_id: "o1", amount: 50, currency: "EUR"},
          %OrderCreated{order_id: "test", amount: 100, currency: "USD"}
        ]
      }

      code = Forensics.generate_regression_test(failure, TestModel)

      # Compile the generated body as a plain module rather than an ExUnit test,
      # so we get its compiler diagnostics (syntax errors, bad literals) without
      # the `use ExUnit.Case` module being registered and run by the suite.
      compilable =
        code
        |> String.replace("use ExUnit.Case", "import ExUnit.Assertions")
        |> String.replace(~r/test "[^"]+" do/, "def __regression_check__ do")

      {result, diagnostics} =
        Code.with_diagnostics(fn ->
          try do
            Code.compile_string(compilable)
          rescue
            e -> {:error, e}
          end
        end)

      refute match?({:error, _}, result),
             "generated regression test failed to compile: #{inspect(result)}"

      assert diagnostics == [],
             "generated regression test emitted compiler diagnostics:\n" <>
               Enum.map_join(diagnostics, "\n", &inspect/1)

      :code.purge(TestModel.RegressionTest)
      :code.delete(TestModel.RegressionTest)
    end
  end
end
