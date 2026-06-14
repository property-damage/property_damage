defmodule PropertyDamage.Model.Projection.LivenessTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Model.Projection.Liveness

  # Test command and event modules
  defmodule CreateTransfer do
    defstruct [:transfer_id, :amount]
  end

  defmodule TransferCompleted do
    defstruct [:transfer_id]
  end

  defmodule TransferFailed do
    defstruct [:transfer_id, :reason]
  end

  defmodule CreateOrder do
    defstruct [:order_id]
  end

  defmodule OrderConfirmed do
    defstruct [:order_id]
  end

  defmodule UnrelatedEvent do
    defstruct [:data]
  end

  describe "init/1" do
    test "initializes with default values" do
      state = Liveness.init()

      assert state.pending_operations == %{}
      assert state.max_pending_duration_ms == 10_000
      assert state.required_completions == %{}
      assert state.check_interval == 10
      assert state.current_step == 0
    end

    test "accepts custom configuration" do
      state =
        Liveness.init(
          max_pending_duration_ms: 5_000,
          check_interval: 5,
          required_completions: %{
            CreateTransfer => [TransferCompleted, TransferFailed]
          }
        )

      assert state.max_pending_duration_ms == 5_000
      assert state.check_interval == 5

      assert state.required_completions == %{
               CreateTransfer => [TransferCompleted, TransferFailed]
             }
    end
  end

  describe "apply/2 with commands" do
    test "tracks commands that start operations" do
      state =
        Liveness.init(
          required_completions: %{
            CreateTransfer => [TransferCompleted, TransferFailed]
          }
        )

      cmd = %CreateTransfer{transfer_id: "t1", amount: 100}
      new_state = Liveness.apply(state, cmd)

      assert Liveness.pending_count(new_state) == 1

      [op] = Liveness.pending_operations(new_state)
      assert op.command_module == CreateTransfer
      assert op.expected_completions == [TransferCompleted, TransferFailed]
    end

    test "ignores commands not in required_completions" do
      state =
        Liveness.init(
          required_completions: %{
            CreateTransfer => [TransferCompleted]
          }
        )

      # CreateOrder is not tracked
      cmd = %CreateOrder{order_id: "o1"}
      new_state = Liveness.apply(state, cmd)

      assert Liveness.pending_count(new_state) == 0
    end

    test "tracks multiple pending operations" do
      state =
        Liveness.init(
          required_completions: %{
            CreateTransfer => [TransferCompleted],
            CreateOrder => [OrderConfirmed]
          }
        )

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 50})
      state = Liveness.apply(state, %CreateOrder{order_id: "o1"})
      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t2", amount: 75})

      assert Liveness.pending_count(state) == 3
    end
  end

  describe "apply/2 with events" do
    test "removes pending operation when completion event arrives" do
      state =
        Liveness.init(
          required_completions: %{
            CreateTransfer => [TransferCompleted, TransferFailed]
          }
        )

      # Start operation
      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})
      assert Liveness.pending_count(state) == 1

      # Complete operation
      state = Liveness.apply(state, %TransferCompleted{transfer_id: "t1"})
      assert Liveness.pending_count(state) == 0
    end

    test "removes pending operation on failure event" do
      state =
        Liveness.init(
          required_completions: %{
            CreateTransfer => [TransferCompleted, TransferFailed]
          }
        )

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})
      state = Liveness.apply(state, %TransferFailed{transfer_id: "t1", reason: :timeout})

      assert Liveness.pending_count(state) == 0
    end

    test "ignores unrelated events" do
      state =
        Liveness.init(
          required_completions: %{
            CreateTransfer => [TransferCompleted]
          }
        )

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})
      state = Liveness.apply(state, %UnrelatedEvent{data: "foo"})

      assert Liveness.pending_count(state) == 1
    end

    test "increments current_step on each apply" do
      state = Liveness.init()

      state = Liveness.apply(state, %UnrelatedEvent{data: "a"})
      assert state.current_step == 1

      state = Liveness.apply(state, %UnrelatedEvent{data: "b"})
      assert state.current_step == 2
    end
  end

  describe "check_liveness/2" do
    test "returns :ok when no pending operations" do
      state = Liveness.init()

      assert Liveness.check_liveness(state) == :ok
    end

    test "returns :ok when operations complete within timeout" do
      state =
        Liveness.init(
          max_pending_duration_ms: 10_000,
          required_completions: %{
            CreateTransfer => [TransferCompleted]
          }
        )

      # Add and immediately complete
      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})
      state = Liveness.apply(state, %TransferCompleted{transfer_id: "t1"})

      assert Liveness.check_liveness(state) == :ok
    end

    test "returns error when operation exceeds timeout" do
      state =
        Liveness.init(
          # Very short timeout for testing
          max_pending_duration_ms: 1,
          required_completions: %{
            CreateTransfer => [TransferCompleted]
          }
        )

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})

      # Wait a bit to exceed timeout
      Process.sleep(5)

      result = Liveness.check_liveness(state)
      assert {:error, message} = result
      assert message =~ "Stuck operations detected"
      assert message =~ "CreateTransfer"
    end
  end

  describe "pending_count/1" do
    test "returns count of pending operations" do
      state =
        Liveness.init(required_completions: %{CreateTransfer => [TransferCompleted]})

      assert Liveness.pending_count(state) == 0

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})
      assert Liveness.pending_count(state) == 1

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t2", amount: 200})
      assert Liveness.pending_count(state) == 2
    end
  end

  describe "pending_operations/1" do
    test "returns list of pending operation details" do
      state =
        Liveness.init(required_completions: %{CreateTransfer => [TransferCompleted]})

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})

      ops = Liveness.pending_operations(state)
      assert length(ops) == 1

      [op] = ops
      assert op.command_module == CreateTransfer
      assert is_integer(op.started_at)
      assert op.expected_completions == [TransferCompleted]
    end
  end

  describe "operations_pending_longer_than/2" do
    test "returns operations exceeding threshold" do
      state =
        Liveness.init(required_completions: %{CreateTransfer => [TransferCompleted]})

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})

      # Immediately check with 0 threshold
      Process.sleep(2)
      ops = Liveness.operations_pending_longer_than(state, 1)
      assert length(ops) == 1

      # Check with high threshold
      ops = Liveness.operations_pending_longer_than(state, 100_000)
      assert ops == []
    end
  end

  describe "__checks__/0 and check/3" do
    test "defines no_stuck_operations check" do
      checks = Liveness.__checks__()

      assert [%{name: :no_stuck_operations, trigger: :always}] = checks
    end

    test "check respects check_interval" do
      state =
        Liveness.init(
          max_pending_duration_ms: 1,
          check_interval: 5,
          required_completions: %{CreateTransfer => [TransferCompleted]}
        )

      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})
      Process.sleep(5)

      # At step 1 (not multiple of 5), check should be skipped
      ctx = %{step_count: 1}
      assert Liveness.check(:no_stuck_operations, state, ctx) == :ok

      # At step 5, check should run
      ctx = %{step_count: 5}
      result = Liveness.check(:no_stuck_operations, state, ctx)
      assert {:error, _} = result
    end
  end

  describe "workflow integration" do
    test "tracks complete operation lifecycle" do
      state =
        Liveness.init(
          max_pending_duration_ms: 10_000,
          required_completions: %{
            CreateTransfer => [TransferCompleted, TransferFailed],
            CreateOrder => [OrderConfirmed]
          }
        )

      # Start multiple operations
      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t1", amount: 100})
      state = Liveness.apply(state, %CreateOrder{order_id: "o1"})
      state = Liveness.apply(state, %CreateTransfer{transfer_id: "t2", amount: 200})

      assert Liveness.pending_count(state) == 3

      # Complete some
      state = Liveness.apply(state, %TransferCompleted{transfer_id: "t1"})
      assert Liveness.pending_count(state) == 2

      state = Liveness.apply(state, %OrderConfirmed{order_id: "o1"})
      assert Liveness.pending_count(state) == 1

      # Fail the last one
      state = Liveness.apply(state, %TransferFailed{transfer_id: "t2", reason: :error})
      assert Liveness.pending_count(state) == 0

      # All complete - liveness check passes
      assert Liveness.check_liveness(state) == :ok
    end
  end
end
