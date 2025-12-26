defmodule PropertyDamage.DiffTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Diff, EventLog.Entry}

  # Test structs
  defmodule CreateAccount do
    defstruct [:name, :initial_balance]
  end

  defmodule Deposit do
    defstruct [:account_id, :amount]
  end

  defmodule Withdraw do
    defstruct [:account_id, :amount]
  end

  defmodule AccountCreated do
    defstruct [:id, :name, :balance]
  end

  defmodule DepositSucceeded do
    defstruct [:account_id, :new_balance]
  end

  defmodule WithdrawSucceeded do
    defstruct [:account_id, :new_balance]
  end

  defmodule WithdrawFailed do
    defstruct [:account_id, :reason]
  end

  describe "compare_traces/2" do
    test "detects identical traces" do
      commands = [
        %CreateAccount{name: "Alice", initial_balance: 100},
        %Deposit{account_id: "acc_1", amount: 50}
      ]

      events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Alice", balance: 100},
          source: :command,
          timestamp: 1000
        },
        %Entry{
          command_index: 1,
          event: %DepositSucceeded{account_id: "acc_1", new_balance: 150},
          source: :command,
          timestamp: 2000
        }
      ]

      trace = Diff.create_trace(commands, events, [], :pass)
      diff = Diff.compare_traces(trace, trace)

      assert diff.divergence_index == nil
      assert String.contains?(diff.summary, "No differences")
    end

    test "detects event differences" do
      commands = [
        %CreateAccount{name: "Alice", initial_balance: 100},
        %Withdraw{account_id: "acc_1", amount: 150}
      ]

      passing_events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Alice", balance: 100},
          source: :command,
          timestamp: 1000
        },
        %Entry{
          command_index: 1,
          event: %WithdrawSucceeded{account_id: "acc_1", new_balance: -50},
          source: :command,
          timestamp: 2000
        }
      ]

      failing_events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Alice", balance: 100},
          source: :command,
          timestamp: 1000
        },
        %Entry{
          command_index: 1,
          event: %WithdrawFailed{account_id: "acc_1", reason: :insufficient_funds},
          source: :command,
          timestamp: 2000
        }
      ]

      passing_trace = Diff.create_trace(commands, passing_events, [], :pass)
      failing_trace = Diff.create_trace(commands, failing_events, [], {:fail, :test})

      diff = Diff.compare_traces(passing_trace, failing_trace)

      assert diff.divergence_index == 1
      assert length(diff.event_diffs) == 2

      event_diff = Enum.find(diff.event_diffs, &(&1.command_index == 1))
      assert event_diff.status == :different
    end

    test "detects command differences" do
      left_commands = [
        %CreateAccount{name: "Alice", initial_balance: 100},
        %Deposit{account_id: "acc_1", amount: 50}
      ]

      right_commands = [
        %CreateAccount{name: "Alice", initial_balance: 100},
        %Withdraw{account_id: "acc_1", amount: 50}
      ]

      left_trace = Diff.create_trace(left_commands, [], [], :pass)
      right_trace = Diff.create_trace(right_commands, [], [], :pass)

      diff = Diff.compare_traces(left_trace, right_trace)

      assert diff.divergence_index == 1

      cmd_diff = Enum.find(diff.command_diffs, &(&1.index == 1))
      assert cmd_diff.status == :different
    end

    test "detects missing commands" do
      short_commands = [%CreateAccount{name: "Alice", initial_balance: 100}]

      long_commands = [
        %CreateAccount{name: "Alice", initial_balance: 100},
        %Deposit{account_id: "acc_1", amount: 50}
      ]

      short_trace = Diff.create_trace(short_commands, [], [], :pass)
      long_trace = Diff.create_trace(long_commands, [], [], :pass)

      diff = Diff.compare_traces(short_trace, long_trace)

      cmd_diff = Enum.find(diff.command_diffs, &(&1.index == 1))
      assert cmd_diff.status == :missing_left
    end
  end

  describe "compare_events/2" do
    test "compares event logs" do
      left_events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Alice", balance: 100},
          source: :command,
          timestamp: 1000
        }
      ]

      right_events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Bob", balance: 100},
          source: :command,
          timestamp: 1000
        }
      ]

      diffs = Diff.compare_events(left_events, right_events)

      assert length(diffs) == 1
      assert hd(diffs).status == :different
    end

    test "detects extra events" do
      left_events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Alice", balance: 100},
          source: :command,
          timestamp: 1000
        }
      ]

      right_events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Alice", balance: 100},
          source: :command,
          timestamp: 1000
        },
        %Entry{
          command_index: 1,
          event: %DepositSucceeded{account_id: "acc_1", new_balance: 150},
          source: :command,
          timestamp: 2000
        }
      ]

      diffs = Diff.compare_events(left_events, right_events)

      extra_diff = Enum.find(diffs, &(&1.command_index == 1))
      assert extra_diff.status == :extra_right
    end
  end

  describe "compare_states/2" do
    test "detects changed values" do
      left = %{balance: 100, name: "Alice"}
      right = %{balance: 50, name: "Alice"}

      diffs = Diff.compare_states(left, right)

      assert length(diffs) == 1
      diff = hd(diffs)
      assert diff.field == :balance
      assert diff.status == :changed
      assert diff.left_value == 100
      assert diff.right_value == 50
    end

    test "detects added fields" do
      left = %{name: "Alice"}
      right = %{name: "Alice", balance: 100}

      diffs = Diff.compare_states(left, right)

      assert length(diffs) == 1
      diff = hd(diffs)
      assert diff.field == :balance
      assert diff.status == :added
    end

    test "detects removed fields" do
      left = %{name: "Alice", balance: 100}
      right = %{name: "Alice"}

      diffs = Diff.compare_states(left, right)

      assert length(diffs) == 1
      diff = hd(diffs)
      assert diff.field == :balance
      assert diff.status == :removed
    end

    test "ignores same values" do
      left = %{name: "Alice", balance: 100}
      right = %{name: "Alice", balance: 100}

      diffs = Diff.compare_states(left, right)

      assert diffs == []
    end
  end

  describe "format/2" do
    setup do
      commands = [
        %CreateAccount{name: "Alice", initial_balance: 100},
        %Withdraw{account_id: "acc_1", amount: 150}
      ]

      passing_events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Alice", balance: 100},
          source: :command,
          timestamp: 1000
        },
        %Entry{
          command_index: 1,
          event: %WithdrawSucceeded{account_id: "acc_1", new_balance: -50},
          source: :command,
          timestamp: 2000
        }
      ]

      failing_events = [
        %Entry{
          command_index: 0,
          event: %AccountCreated{id: "acc_1", name: "Alice", balance: 100},
          source: :command,
          timestamp: 1000
        },
        %Entry{
          command_index: 1,
          event: %WithdrawFailed{account_id: "acc_1", reason: :insufficient_funds},
          source: :command,
          timestamp: 2000
        }
      ]

      passing_states = [%{balance: 100}, %{balance: -50}]
      failing_states = [%{balance: 100}, %{balance: 100}]

      passing_trace = Diff.create_trace(commands, passing_events, passing_states, :pass)
      failing_trace = Diff.create_trace(commands, failing_events, failing_states, {:fail, :test})

      diff = Diff.compare_traces(passing_trace, failing_trace)

      {:ok, diff: diff}
    end

    test "formats terminal output", %{diff: diff} do
      output = Diff.format(diff, format: :terminal)

      assert String.contains?(output, "EXECUTION DIFF")
      assert String.contains?(output, "Divergence")
      assert String.contains?(output, "Event Differences")
    end

    test "formats markdown output", %{diff: diff} do
      output = Diff.format(diff, format: :markdown)

      assert String.contains?(output, "# Execution Diff")
      assert String.contains?(output, "**Summary:**")
      assert String.contains?(output, "| Command |")
    end

    test "formats json output", %{diff: diff} do
      output = Diff.format(diff, format: :json)

      decoded = Jason.decode!(output)
      assert Map.has_key?(decoded, "divergence_index")
      assert Map.has_key?(decoded, "summary")
      assert is_list(decoded["event_diffs"])
    end
  end

  describe "create_trace/4" do
    test "creates a trace struct" do
      commands = [%CreateAccount{name: "Alice", initial_balance: 100}]
      events = []
      states = [%{balance: 100}]

      trace = Diff.create_trace(commands, events, states, :pass)

      assert trace.commands == commands
      assert trace.events == events
      assert trace.states == states
      assert trace.result == :pass
    end
  end
end
