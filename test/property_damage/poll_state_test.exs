defmodule PropertyDamage.PollStateTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Model.Projection

  # ============================================================================
  # Test Events and Commands
  # ============================================================================

  defmodule PaymentInitiated do
    defstruct [:id, :amount]
  end

  defmodule PaymentConfirmed do
    defstruct [:id]
  end

  defmodule PaymentFailed do
    defstruct [:id, :reason]
  end

  # ============================================================================
  # Test Projections
  # ============================================================================

  defmodule PaymentProjection do
    use PropertyDamage.Model.Projection

    def init, do: %{payments: %{}}

    def apply(state, %PaymentInitiated{id: id}) do
      put_in(state.payments[id], :pending)
    end

    def apply(state, %PaymentConfirmed{id: id}) do
      put_in(state.payments[id], :confirmed)
    end

    def apply(state, %PaymentFailed{id: id}) do
      put_in(state.payments[id], :failed)
    end

    def apply(state, _), do: state

    # Synchronous check
    @check every: PaymentInitiated
    def assert_amount_positive(_state, %PaymentInitiated{amount: amt}) do
      if amt <= 0, do: PropertyDamage.fail!("amount must be positive")
    end

    # Eventually check - payment should be confirmed within timeout
    @eventually after: PaymentInitiated, timeout: 1, interval: {50, :milliseconds}
    def payment_eventually_confirmed(_state, %PaymentInitiated{id: id}) do
      fn s -> s.payments[id] == :confirmed end
    end
  end

  defmodule FastTimeoutProjection do
    use PropertyDamage.Model.Projection

    def init, do: %{status: :pending}

    def apply(state, _), do: state

    # Very short timeout for testing failures
    @eventually after: PaymentInitiated,
                timeout: {50, :milliseconds},
                interval: {10, :milliseconds}
    def never_succeeds(_state, %PaymentInitiated{}) do
      fn _s -> false end
    end
  end

  defmodule MultiTriggerProjection do
    use PropertyDamage.Model.Projection

    def init, do: %{items: %{}}

    def apply(state, %PaymentInitiated{id: id}) do
      put_in(state.items[id], :initiated)
    end

    def apply(state, %PaymentConfirmed{id: id}) do
      put_in(state.items[id], :confirmed)
    end

    def apply(state, _), do: state

    # Multiple trigger events
    @eventually after: [PaymentInitiated, PaymentFailed],
                timeout: 1,
                interval: {50, :milliseconds}
    def item_processed(_state, event) do
      id =
        case event do
          %PaymentInitiated{id: id} -> id
          %PaymentFailed{id: id} -> id
        end

      fn s -> Map.has_key?(s.items, id) end
    end
  end

  # ============================================================================
  # Projection Compilation Tests
  # ============================================================================

  describe "projection @eventually compilation" do
    test "captures @eventually check metadata" do
      checks = PaymentProjection.__checks__()

      poll_check =
        Enum.find(checks, fn a ->
          a.name == :payment_eventually_confirmed
        end)

      assert poll_check != nil
      assert poll_check.type == :polling
      assert poll_check.eventually.after == [PaymentInitiated]
      assert poll_check.eventually.timeout_ms == 1000
      assert poll_check.eventually.interval_ms == 50
      assert poll_check.predicate_source != nil
    end

    test "captures synchronous @check metadata" do
      checks = PaymentProjection.__checks__()

      trigger_check =
        Enum.find(checks, fn a ->
          a.name == :amount_positive
        end)

      assert trigger_check != nil
      assert trigger_check.type == :synchronous
      assert trigger_check.trigger != nil
    end

    test "captures multiple trigger events" do
      checks = MultiTriggerProjection.__checks__()

      poll_check =
        Enum.find(checks, fn a ->
          a.name == :item_processed
        end)

      assert poll_check != nil
      assert poll_check.eventually.after == [PaymentInitiated, PaymentFailed]
    end

    test "normalizes time values correctly" do
      checks = FastTimeoutProjection.__checks__()

      poll_check =
        Enum.find(checks, fn a ->
          a.name == :never_succeeds
        end)

      # 50 milliseconds
      assert poll_check.eventually.timeout_ms == 50
      # 10 milliseconds
      assert poll_check.eventually.interval_ms == 10
    end
  end

  # ============================================================================
  # Projection Helper Tests
  # ============================================================================

  describe "Projection.event_matches_poll_trigger?/2" do
    test "returns true for matching event module" do
      eventually = %{after: [PaymentInitiated]}
      assert Projection.event_matches_poll_trigger?(eventually, PaymentInitiated)
    end

    test "returns false for non-matching event module" do
      eventually = %{after: [PaymentInitiated]}
      refute Projection.event_matches_poll_trigger?(eventually, PaymentConfirmed)
    end

    test "handles multiple trigger events" do
      eventually = %{after: [PaymentInitiated, PaymentFailed]}
      assert Projection.event_matches_poll_trigger?(eventually, PaymentInitiated)
      assert Projection.event_matches_poll_trigger?(eventually, PaymentFailed)
      refute Projection.event_matches_poll_trigger?(eventually, PaymentConfirmed)
    end
  end

  # ============================================================================
  # Predicate Source Capture Tests
  # ============================================================================

  describe "predicate source capture" do
    test "captures simple fn expression" do
      checks = PaymentProjection.__checks__()

      poll_check =
        Enum.find(checks, fn a ->
          a.name == :payment_eventually_confirmed
        end)

      # Should contain the fn expression
      assert poll_check.predicate_source =~ "fn"
      assert poll_check.predicate_source =~ "payments"
      assert poll_check.predicate_source =~ "confirmed"
    end
  end

  # ============================================================================
  # Time Normalization Tests
  # ============================================================================

  describe "time normalization" do
    defmodule TimeTestProjection do
      use PropertyDamage.Model.Projection

      def init, do: %{}
      def apply(state, _), do: state

      # Test seconds (default)
      @eventually after: PaymentInitiated, timeout: 5, interval: 1
      def seconds_default(_state, %PaymentInitiated{}) do
        fn _s -> true end
      end

      # Test explicit seconds
      @eventually after: PaymentConfirmed, timeout: {3, :seconds}, interval: {500, :milliseconds}
      def explicit_seconds(_state, %PaymentConfirmed{}) do
        fn _s -> true end
      end

      # Test minutes
      @eventually after: PaymentFailed, timeout: {2, :minutes}, interval: {30, :seconds}
      def minutes_test(_state, %PaymentFailed{}) do
        fn _s -> true end
      end
    end

    test "defaults integers to seconds" do
      checks = TimeTestProjection.__checks__()
      check = Enum.find(checks, &(&1.name == :seconds_default))

      assert check.eventually.timeout_ms == 5000
      assert check.eventually.interval_ms == 1000
    end

    test "handles explicit seconds tuple" do
      checks = TimeTestProjection.__checks__()
      check = Enum.find(checks, &(&1.name == :explicit_seconds))

      assert check.eventually.timeout_ms == 3000
      assert check.eventually.interval_ms == 500
    end

    test "handles minutes" do
      checks = TimeTestProjection.__checks__()
      check = Enum.find(checks, &(&1.name == :minutes_test))

      assert check.eventually.timeout_ms == 120_000
      assert check.eventually.interval_ms == 30_000
    end

    test "accepts singular time units" do
      defmodule SingularTimeProjection do
        use PropertyDamage.Model.Projection

        def init, do: %{}
        def apply(state, _), do: state

        @eventually after: PaymentInitiated, timeout: {2, :second}, interval: {1, :second}
        def singular_units(_state, %PaymentInitiated{}) do
          fn _s -> true end
        end
      end

      check =
        Enum.find(SingularTimeProjection.__checks__(), &(&1.name == :singular_units))

      assert check.eventually.timeout_ms == 2000
      assert check.eventually.interval_ms == 1000
    end
  end

  # ============================================================================
  # Check Function Call Tests
  # ============================================================================

  describe "polling check function" do
    test "returns a predicate function when called" do
      state = %{payments: %{"pay_123" => :pending}}
      event = %PaymentInitiated{id: "pay_123", amount: 100}

      predicate = PaymentProjection.payment_eventually_confirmed(state, event)

      assert is_function(predicate, 1)

      # Predicate should return false for pending
      assert predicate.(%{payments: %{"pay_123" => :pending}}) == false

      # Predicate should return true for confirmed
      assert predicate.(%{payments: %{"pay_123" => :confirmed}}) == true
    end

    test "predicate captures event data via closure" do
      state = PaymentProjection.init()
      event = %PaymentInitiated{id: "specific_id", amount: 50}

      predicate = PaymentProjection.payment_eventually_confirmed(state, event)

      # The predicate should check for the specific ID from the event
      assert predicate.(%{payments: %{"specific_id" => :confirmed}}) == true
      assert predicate.(%{payments: %{"other_id" => :confirmed}}) == false
    end
  end
end
