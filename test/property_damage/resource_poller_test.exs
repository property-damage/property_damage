defmodule PropertyDamage.ResourcePollerTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{EventQueue, ResourcePoller}

  # Test event struct
  defmodule StatusChanged do
    defstruct [:id, :status]
  end

  defmodule Completed do
    defstruct [:id, :result]
  end

  # Test exception structs for error handling tests
  defmodule TestPaymentError do
    defexception [:code, :details]

    def message(%{code: code, details: details}) do
      "Payment failed with code #{code}: #{details}"
    end
  end

  defmodule TestTimeoutError do
    defexception [:elapsed_ms, :poll_count]

    def message(%{elapsed_ms: ms, poll_count: count}) do
      "Resource timed out after #{ms}ms (#{count} polls)"
    end
  end

  describe "start/1" do
    test "starts a polling process and returns a handle" do
      {:ok, queue} = EventQueue.start_link()

      poll_count = :counters.new(1, [:atomics])

      poller =
        ResourcePoller.start(
          poll_fn: fn ->
            :counters.add(poll_count, 1, 1)
            :counters.get(poll_count, 1)
          end,
          handler: fn count ->
            # Only complete after a few polls to ensure process stays alive long enough
            if count >= 3, do: {:done, []}, else: :continue
          end,
          interval_ms: 20,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      assert %ResourcePoller{} = poller
      assert is_reference(poller.id)
      assert is_pid(poller.pid)

      # Wait for it to complete
      result = ResourcePoller.await(poller)
      assert {:success, _} = result

      EventQueue.stop(queue)
    end

    test "validates required options" do
      assert_raise KeyError, fn ->
        ResourcePoller.start(handler: fn _ -> :continue end)
      end
    end
  end

  describe "handler return values" do
    test ":continue keeps polling without injecting events" do
      {:ok, queue} = EventQueue.start_link()

      poll_count = :counters.new(1, [:atomics])

      poller =
        ResourcePoller.start(
          poll_fn: fn ->
            :counters.add(poll_count, 1, 1)
            :counters.get(poll_count, 1)
          end,
          handler: fn count ->
            if count >= 3 do
              {:done, []}
            else
              :continue
            end
          end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller)
      assert {:success, _} = result

      # No events should have been injected
      assert EventQueue.empty?(queue)

      EventQueue.stop(queue)
    end

    test "{:inject, event} pushes single event and continues" do
      {:ok, queue} = EventQueue.start_link()

      poll_count = :counters.new(1, [:atomics])

      poller =
        ResourcePoller.start(
          poll_fn: fn ->
            :counters.add(poll_count, 1, 1)
            :counters.get(poll_count, 1)
          end,
          handler: fn count ->
            case count do
              1 -> {:inject, %StatusChanged{id: "1", status: :pending}}
              2 -> {:inject, %StatusChanged{id: "1", status: :processing}}
              _ -> {:done, %Completed{id: "1", result: :ok}}
            end
          end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 5
        )

      result = ResourcePoller.await(poller)
      assert {:success, _} = result

      # Check injected events
      entries = EventQueue.drain(queue)
      assert length(entries) == 3

      [e1, e2, e3] = entries
      assert e1.source == :resource_poller
      assert e1.event == %StatusChanged{id: "1", status: :pending}
      assert e1.command_index == 5

      assert e2.event == %StatusChanged{id: "1", status: :processing}
      assert e3.event == %Completed{id: "1", result: :ok}

      EventQueue.stop(queue)
    end

    test "{:inject, [events]} pushes multiple events and continues" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :ready end,
          handler: fn _ ->
            {:done,
             [
               %StatusChanged{id: "1", status: :a},
               %StatusChanged{id: "1", status: :b}
             ]}
          end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      ResourcePoller.await(poller)

      entries = EventQueue.drain(queue)
      assert length(entries) == 2

      EventQueue.stop(queue)
    end

    test "{:done, []} stops without injecting" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :ok end,
          handler: fn _ -> {:done, []} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller)
      assert {:success, _} = result
      assert EventQueue.empty?(queue)

      EventQueue.stop(queue)
    end

    test "{:error, reason} stops with error" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :fail end,
          handler: fn _ -> {:error, :custom_error} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller)
      assert {:error, _id, :custom_error} = result

      EventQueue.stop(queue)
    end
  end

  describe "timeout behavior" do
    test "on_timeout: :fail (default) returns generic timeout error" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 10,
          timeout_ms: 50,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)
      assert {:error, _id, {:timeout, info}} = result
      assert info.elapsed_ms >= 50
      assert info.poll_count >= 1

      EventQueue.stop(queue)
    end

    test "on_timeout: :ignore returns timeout_ignored" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 10,
          timeout_ms: 50,
          on_timeout: :ignore,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)
      assert {:timeout_ignored, _id} = result

      EventQueue.stop(queue)
    end

    test "on_timeout: {:error, reason} returns custom error" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 10,
          timeout_ms: 50,
          on_timeout: {:error, :resource_never_settled},
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)
      assert {:error, _id, :resource_never_settled} = result

      EventQueue.stop(queue)
    end

    test "on_timeout: function receives timeout_info and can return :ignore" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 10,
          timeout_ms: 50,
          on_timeout: fn info ->
            if info.poll_count > 2, do: :ignore, else: {:error, :too_few_polls}
          end,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)
      assert {:timeout_ignored, _id} = result

      EventQueue.stop(queue)
    end

    test "on_timeout: function can return {:error, reason}" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 50,
          timeout_ms: 60,
          on_timeout: fn info ->
            {:error, "Timed out after #{info.poll_count} polls"}
          end,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)
      assert {:error, _id, "Timed out after " <> _} = result

      EventQueue.stop(queue)
    end
  end

  describe "error handling" do
    test "poll_fn exception returns poll_fn_error" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> raise "boom" end,
          handler: fn _ -> {:done, []} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller)
      assert {:error, _id, {:poll_fn_error, %RuntimeError{message: "boom"}, _stacktrace}} = result

      EventQueue.stop(queue)
    end

    test "poll_fn exit returns poll_fn_error instead of crashing the poller" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> exit(:poll_boom) end,
          handler: fn _ -> {:done, []} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller)
      assert {:error, _id, {:poll_fn_error, {:exit, :poll_boom}, _stacktrace}} = result

      EventQueue.stop(queue)
    end

    test "handler exit returns handler_error instead of crashing the poller" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :ok end,
          handler: fn _ -> throw(:handler_boom) end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller)
      assert {:error, _id, {:handler_error, {:throw, :handler_boom}, _stacktrace}} = result

      EventQueue.stop(queue)
    end

    test "handler exception returns handler_error" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :ok end,
          handler: fn _ -> raise "handler boom" end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller)

      assert {:error, _id, {:handler_error, %RuntimeError{message: "handler boom"}, _stacktrace}} =
               result

      EventQueue.stop(queue)
    end

    test "on_timeout function raising returns on_timeout_error" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 10,
          timeout_ms: 50,
          on_timeout: fn _info -> raise "timeout handler exploded" end,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)

      assert {:error, _id,
              {:on_timeout_error, %RuntimeError{message: "timeout handler exploded"}, stacktrace}} =
               result

      assert is_list(stacktrace)
      EventQueue.stop(queue)
    end

    test "handler can return {:error, exception} for structured errors" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> %{status: 500, body: "gateway error"} end,
          handler: fn response ->
            {:error, %TestPaymentError{code: :gateway_error, details: response.body}}
          end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller)

      assert {:error, _id, %TestPaymentError{code: :gateway_error}} = result
      EventQueue.stop(queue)
    end

    test "on_timeout function exiting returns on_timeout_error instead of crashing the poller" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 10,
          timeout_ms: 50,
          on_timeout: fn _info -> exit(:timeout_boom) end,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)

      assert {:error, _id, {:on_timeout_error, {:exit, :timeout_boom}, stacktrace}} = result
      assert is_list(stacktrace)
      EventQueue.stop(queue)
    end

    test "on_timeout function throwing returns on_timeout_error instead of crashing the poller" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 10,
          timeout_ms: 50,
          on_timeout: fn _info -> throw(:timeout_boom) end,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)

      assert {:error, _id, {:on_timeout_error, {:throw, :timeout_boom}, stacktrace}} = result
      assert is_list(stacktrace)
      EventQueue.stop(queue)
    end

    test "on_timeout can return {:error, exception} for structured errors" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 10,
          timeout_ms: 50,
          on_timeout: fn info ->
            {:error, %TestTimeoutError{elapsed_ms: info.elapsed_ms, poll_count: info.poll_count}}
          end,
          event_queue: queue,
          command_index: 0
        )

      result = ResourcePoller.await(poller, timeout: 1000)

      assert {:error, _id, %TestTimeoutError{}} = result
      EventQueue.stop(queue)
    end
  end

  describe "await_all/2" do
    test "waits for multiple pollers" do
      {:ok, queue} = EventQueue.start_link()

      pollers =
        for i <- 1..3 do
          ResourcePoller.start(
            poll_fn: fn -> i end,
            handler: fn _ -> {:done, %Completed{id: "#{i}", result: :ok}} end,
            interval_ms: 10 * i,
            timeout_ms: 5000,
            event_queue: queue,
            command_index: i
          )
        end

      results = ResourcePoller.await_all(pollers)

      assert length(results) == 3
      assert Enum.all?(results, fn {_id, result} -> match?({:success, _}, result) end)

      EventQueue.stop(queue)
    end

    test "returns results for mixed success/failure" do
      {:ok, queue} = EventQueue.start_link()

      poller1 =
        ResourcePoller.start(
          poll_fn: fn -> :ok end,
          handler: fn _ -> {:done, []} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      poller2 =
        ResourcePoller.start(
          poll_fn: fn -> :fail end,
          handler: fn _ -> {:error, :failed} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 1
        )

      results = ResourcePoller.await_all([poller1, poller2])

      assert length(results) == 2

      success_results = Enum.filter(results, fn {_id, r} -> match?({:success, _}, r) end)
      error_results = Enum.filter(results, fn {_id, r} -> match?({:error, _, _}, r) end)

      assert length(success_results) == 1
      assert length(error_results) == 1

      EventQueue.stop(queue)
    end

    test "returns empty list for empty input" do
      assert ResourcePoller.await_all([]) == []
    end
  end

  describe "check/1" do
    test "returns :pending when poller is still running" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 1000,
          timeout_ms: 10_000,
          event_queue: queue,
          command_index: 0
        )

      assert ResourcePoller.check(poller) == :pending

      ResourcePoller.stop(poller)
      EventQueue.stop(queue)
    end

    test "returns {:ok, result} when poller has completed" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :done end,
          handler: fn _ -> {:done, []} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      # Wait a bit for it to complete
      Process.sleep(50)

      result = ResourcePoller.check(poller)
      assert {:ok, {:success, _}} = result

      EventQueue.stop(queue)
    end
  end

  describe "stop/1" do
    test "stops a running poller" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 1000,
          timeout_ms: 60_000,
          event_queue: queue,
          command_index: 0
        )

      assert Process.alive?(poller.pid)

      assert :ok = ResourcePoller.stop(poller)

      # Give it time to stop
      Process.sleep(10)
      refute Process.alive?(poller.pid)

      EventQueue.stop(queue)
    end

    test "is idempotent (safe to call multiple times)" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :done end,
          handler: fn _ -> {:done, []} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 0
        )

      ResourcePoller.await(poller)

      # Should not raise even though poller is already stopped
      assert :ok = ResourcePoller.stop(poller)
      assert :ok = ResourcePoller.stop(poller)

      EventQueue.stop(queue)
    end
  end

  describe "branch_id support" do
    test "events include branch_id when provided" do
      {:ok, queue} = EventQueue.start_link()

      poller =
        ResourcePoller.start(
          poll_fn: fn -> :ok end,
          handler: fn _ -> {:done, %StatusChanged{id: "1", status: :done}} end,
          interval_ms: 10,
          timeout_ms: 5000,
          event_queue: queue,
          command_index: 3,
          branch_id: 7
        )

      ResourcePoller.await(poller)

      [entry] = EventQueue.drain(queue)
      assert entry.branch_id == 7

      EventQueue.stop(queue)
    end
  end
end
