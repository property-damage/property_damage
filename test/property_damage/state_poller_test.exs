defmodule PropertyDamage.StatePollerTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.StatePoller

  defmodule TestEvent do
    defstruct [:id, :amount]
  end

  defmodule TestProjection do
    def init, do: %{items: %{}}
    def apply(state, _), do: state
  end

  describe "start/1" do
    test "starts a poller and returns a handle" do
      # Use a predicate that doesn't complete immediately so we can check the process
      counter = :counters.new(1, [:atomics])

      poller =
        StatePoller.start(
          predicate: fn _state ->
            :counters.get(counter, 1) >= 3
          end,
          projection: TestProjection,
          interval_ms: 50,
          timeout_ms: 5000,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj ->
            :counters.add(counter, 1, 1)
            %{}
          end
        )

      assert %StatePoller{} = poller
      assert is_reference(poller.id)
      assert is_pid(poller.pid)
      assert Process.alive?(poller.pid)

      # Clean up
      StatePoller.stop(poller)
    end

    test "sets poller fields correctly" do
      predicate = fn _state -> false end

      poller =
        StatePoller.start(
          predicate: predicate,
          predicate_source: "fn _state -> false end",
          projection: TestProjection,
          interval_ms: 50,
          timeout_ms: 200,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :my_check},
          get_state_fn: fn _proj -> %{} end
        )

      assert poller.predicate == predicate
      assert poller.predicate_source == "fn _state -> false end"
      assert poller.projection == TestProjection
      assert poller.interval_ms == 50
      assert poller.timeout_ms == 200
      assert poller.triggered_by.check_name == :my_check

      StatePoller.stop(poller)
    end
  end

  describe "await/2" do
    test "returns success when predicate becomes true immediately" do
      poller =
        StatePoller.start(
          predicate: fn _state -> true end,
          projection: TestProjection,
          interval_ms: 10,
          timeout_ms: 1000,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj -> %{} end
        )

      result = StatePoller.await(poller)
      assert {:success, id} = result
      assert id == poller.id
    end

    test "returns success when predicate becomes true after some polls" do
      # Create a state that changes over time
      poll_count = :counters.new(1, [:atomics])

      predicate = fn _state ->
        count = :counters.get(poll_count, 1)
        :counters.add(poll_count, 1, 1)
        # Return true on the 3rd poll
        count >= 2
      end

      poller =
        StatePoller.start(
          predicate: predicate,
          projection: TestProjection,
          interval_ms: 10,
          timeout_ms: 1000,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj -> %{} end
        )

      result = StatePoller.await(poller)
      assert {:success, _id} = result

      # Should have polled at least twice
      final_count = :counters.get(poll_count, 1)
      assert final_count >= 2
    end

    test "returns timeout when predicate never becomes true" do
      poller =
        StatePoller.start(
          predicate: fn _state -> false end,
          projection: TestProjection,
          interval_ms: 10,
          timeout_ms: 50,
          triggered_by: %{event: %TestEvent{id: "test"}, check_name: :failing_check},
          get_state_fn: fn _proj -> %{items: %{"test" => :pending}} end
        )

      result = StatePoller.await(poller)

      assert {:timeout, id, info} = result
      assert id == poller.id
      assert info.projection == TestProjection
      assert info.triggered_by.check_name == :failing_check
      assert info.triggered_by.event == %TestEvent{id: "test"}
      assert info.elapsed_ms >= 50
      assert info.poll_count > 0
      assert info.final_state == %{items: %{"test" => :pending}}
    end

    test "timeout info includes predicate source" do
      poller =
        StatePoller.start(
          predicate: fn _state -> false end,
          predicate_source: "fn s -> s.status == :ready end",
          projection: TestProjection,
          interval_ms: 10,
          timeout_ms: 30,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj -> %{} end
        )

      result = StatePoller.await(poller)

      assert {:timeout, _id, info} = result
      assert info.predicate_source == "fn s -> s.status == :ready end"
    end
  end

  describe "await_all/2" do
    test "returns results for all pollers" do
      # One succeeds, one times out
      poller1 =
        StatePoller.start(
          predicate: fn _state -> true end,
          projection: TestProjection,
          interval_ms: 10,
          timeout_ms: 100,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :succeeds},
          get_state_fn: fn _proj -> %{} end
        )

      poller2 =
        StatePoller.start(
          predicate: fn _state -> false end,
          projection: TestProjection,
          interval_ms: 10,
          timeout_ms: 30,
          triggered_by: %{event: %TestEvent{id: "2"}, check_name: :fails},
          get_state_fn: fn _proj -> %{} end
        )

      results = StatePoller.await_all([poller1, poller2])

      assert length(results) == 2

      # Find each result by poller ID
      result1 = Enum.find(results, fn {id, _} -> id == poller1.id end)
      result2 = Enum.find(results, fn {id, _} -> id == poller2.id end)

      assert {_, {:success, _}} = result1
      assert {_, {:timeout, _, _}} = result2
    end

    test "returns empty list for no pollers" do
      results = StatePoller.await_all([])
      assert results == []
    end
  end

  describe "check/1" do
    test "returns :pending when poller is still running" do
      poller =
        StatePoller.start(
          predicate: fn _state -> false end,
          projection: TestProjection,
          interval_ms: 100,
          timeout_ms: 5000,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj -> %{} end
        )

      # Check immediately - should be pending
      result = StatePoller.check(poller)
      assert result == :pending

      StatePoller.stop(poller)
    end

    test "returns result after poller completes" do
      poller =
        StatePoller.start(
          predicate: fn _state -> true end,
          projection: TestProjection,
          interval_ms: 10,
          timeout_ms: 1000,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj -> %{} end
        )

      # Wait a bit for the poller to complete
      Process.sleep(50)

      result = StatePoller.check(poller)
      assert {:ok, {:success, _}} = result
    end
  end

  describe "stop/1" do
    test "stops a running poller" do
      poller =
        StatePoller.start(
          predicate: fn _state -> false end,
          projection: TestProjection,
          interval_ms: 100,
          timeout_ms: 5000,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj -> %{} end
        )

      assert Process.alive?(poller.pid)

      StatePoller.stop(poller)
      Process.sleep(10)

      refute Process.alive?(poller.pid)
    end

    test "is idempotent - stopping twice doesn't error" do
      poller =
        StatePoller.start(
          predicate: fn _state -> false end,
          projection: TestProjection,
          interval_ms: 100,
          timeout_ms: 5000,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj -> %{} end
        )

      assert :ok = StatePoller.stop(poller)
      assert :ok = StatePoller.stop(poller)
    end
  end

  describe "update_state_getter/2" do
    test "updates the state getter function" do
      counter = :counters.new(1, [:atomics])

      # Predicate checks the counter value
      predicate = fn state ->
        state.counter_value >= 3
      end

      # State getter returns current counter value
      get_state_fn = fn _proj ->
        %{counter_value: :counters.get(counter, 1)}
      end

      poller =
        StatePoller.start(
          predicate: predicate,
          projection: TestProjection,
          interval_ms: 10,
          timeout_ms: 1000,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: get_state_fn
        )

      # Increment counter in background
      spawn(fn ->
        Process.sleep(30)
        :counters.add(counter, 1, 3)
      end)

      result = StatePoller.await(poller)
      assert {:success, _} = result
    end
  end

  describe "polling interval" do
    test "respects the configured interval" do
      timestamps = :ets.new(:timestamps, [:public, :set])
      :ets.insert(timestamps, {:polls, []})

      predicate = fn _state ->
        [{:polls, polls}] = :ets.lookup(timestamps, :polls)
        now = System.monotonic_time(:millisecond)
        :ets.insert(timestamps, {:polls, [now | polls]})
        # Always return false to keep polling
        false
      end

      poller =
        StatePoller.start(
          predicate: predicate,
          projection: TestProjection,
          interval_ms: 50,
          timeout_ms: 200,
          triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
          get_state_fn: fn _proj -> %{} end
        )

      StatePoller.await(poller)

      [{:polls, poll_times}] = :ets.lookup(timestamps, :polls)
      :ets.delete(timestamps)

      # Should have at least 3 polls in 200ms with 50ms interval
      assert length(poll_times) >= 3

      # Check intervals are roughly 50ms (allow some slack for scheduling)
      sorted = Enum.sort(poll_times)
      intervals = Enum.zip_with(tl(sorted), Enum.slice(sorted, 0..-2//1), &-/2)

      # All intervals should be roughly 50ms (allow 20-100ms)
      for interval <- intervals do
        assert interval >= 20 and interval <= 100,
               "Expected interval ~50ms, got #{interval}ms"
      end
    end
  end

  describe "the predicate's verdict (DR-052)" do
    defp start_poller(predicate, timeout_ms \\ 5_000) do
      StatePoller.start(
        predicate: predicate,
        projection: TestProjection,
        interval_ms: 10,
        timeout_ms: timeout_ms,
        triggered_by: %{event: %TestEvent{id: "1"}, check_name: :test_check},
        get_state_fn: fn _proj -> %{} end
      )
    end

    defp counting(fun) do
      calls = :counters.new(1, [:atomics])

      predicate = fn state ->
        :counters.add(calls, 1, 1)
        fun.(:counters.get(calls, 1), state)
      end

      {predicate, calls}
    end

    test "a falsy return is not yet: the poller keeps polling until a truthy one" do
      {predicate, calls} = counting(fn n, _ -> if n < 3, do: nil, else: :confirmed end)

      assert {:success, _} = StatePoller.await(start_poller(predicate))
      assert :counters.get(calls, 1) == 3
    end

    test "{:fail, text} is never: the window ends at once with that reason" do
      {predicate, calls} = counting(fn _, _ -> {:fail, "payment reached :failed"} end)

      started = System.monotonic_time(:millisecond)
      assert {:failed, _id, info} = StatePoller.await(start_poller(predicate))

      assert System.monotonic_time(:millisecond) - started < 1_000
      assert :counters.get(calls, 1) == 1
      assert %PropertyDamage.CheckFailed{message: "payment reached :failed"} = info.reason
      assert info.poll_count == 1
      assert info.triggered_by.check_name == :test_check
    end

    test "{:fail, exception} is never with that exception" do
      {predicate, _calls} = counting(fn _, _ -> {:fail, %ArgumentError{message: "never"}} end)

      assert {:failed, _id, %{reason: %ArgumentError{message: "never"}}} =
               StatePoller.await(start_poller(predicate))
    end

    test "a non-verdict return fails at once with the grammar nudge" do
      {predicate, _calls} = counting(fn _, _ -> {:error, :lookup} end)

      assert {:failed, _id, info} = StatePoller.await(start_poller(predicate))
      assert Exception.message(info.reason) =~ "a verdict is truthy"
    end

    test "a raise fails at the first poll with the raised exception and the poll count" do
      {predicate, calls} = counting(fn _, _ -> raise "simulated error" end)

      assert {:failed, _id, info} = StatePoller.await(start_poller(predicate))
      assert :counters.get(calls, 1) == 1
      assert info.poll_count == 1
      assert info.triggered_by.check_name == :test_check
      assert %RuntimeError{message: "simulated error"} = info.reason
      assert [_ | _] = info.stacktrace
    end

    test "a raise after falsy polls names the poll it happened on" do
      {predicate, _calls} = counting(fn n, s -> if n < 3, do: false, else: s.missing end)

      assert {:failed, _id, info} = StatePoller.await(start_poller(predicate))
      assert info.poll_count == 3
      assert %KeyError{key: :missing} = info.reason
    end

    test "an exit does not kill the poller or its caller: it fails at once" do
      {predicate, _calls} = counting(fn _, _ -> exit(:predicate_boom) end)

      assert {:failed, _id, info} = StatePoller.await(start_poller(predicate))
      assert Exception.message(info.reason) =~ ":predicate_boom"
      refute match?(%PropertyDamage.CheckFailed{}, info.reason)
      assert Process.alive?(self())
    end

    test "a throw does not kill the poller or its caller: it fails at once" do
      {predicate, _calls} = counting(fn _, _ -> throw(:predicate_thrown) end)

      assert {:failed, _id, info} = StatePoller.await(start_poller(predicate))
      assert Exception.message(info.reason) =~ ":predicate_thrown"
      refute match?(%PropertyDamage.CheckFailed{}, info.reason)
    end

    test "a timeout reports the window and nothing else" do
      assert {:timeout, _id, info} = StatePoller.await(start_poller(fn _ -> false end, 50))
      refute Map.has_key?(info, :last_predicate_error)
    end
  end
end
