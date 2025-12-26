defmodule PropertyDamage.ErrorTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Error

  # ============================================================================
  # Error Formatting Tests
  # ============================================================================

  describe "Error.format/2 for check_failed" do
    test "formats check failure with context" do
      result =
        Error.format({:check_failed, :balance_valid, "Balance is negative"}, %{
          command_index: 3,
          seed: 12345
        })

      assert result =~ "Check Failed: :balance_valid"
      assert result =~ "Balance is negative"
      assert result =~ "At index: 3"
      assert result =~ "Seed: 12345"
      assert result =~ "Suggestions:"
    end

    test "formats check failure without context" do
      result = Error.format({:check_failed, :test_check, "error"}, %{})

      assert result =~ "Check Failed: :test_check"
      assert result =~ "error"
    end
  end

  describe "Error.format/2 for precondition_failed" do
    test "formats precondition failure" do
      result = Error.format({:precondition_failed, MyCommand}, %{})

      assert result =~ "Precondition Failed: MyCommand"
      assert result =~ "precondition/1 returned false"
      assert result =~ "Suggestions:"
    end
  end

  describe "Error.format/2 for adapter_error" do
    test "formats adapter error with adapter info" do
      result = Error.format({:adapter_error, :timeout}, %{adapter: MyAdapter})

      assert result =~ "Adapter Error"
      assert result =~ "MyAdapter"
      assert result =~ "timeout"
      assert result =~ "Suggestions:"
    end

    test "formats adapter error with nested reason" do
      result = Error.format({:adapter_error, {:http_error, 500}}, %{})

      assert result =~ "Adapter Error"
      assert result =~ "http_error"
      assert result =~ "500"
    end
  end

  describe "Error.format/2 for settle_timeout" do
    test "formats settle timeout" do
      result = Error.format({:settle_timeout, :still_pending}, %{})

      assert result =~ "Settle Timeout"
      assert result =~ "still_pending"
      assert result =~ "eventual consistency"
    end
  end

  describe "Error.format/2 for idempotency_violation" do
    test "formats idempotency violation" do
      result =
        Error.format(
          {:idempotency_violation,
           %{
             original_events: [:event1],
             retry_events: [:event2]
           }},
          %{}
        )

      assert result =~ "Idempotency Violation"
      assert result =~ "event1"
      assert result =~ "event2"
    end
  end

  describe "Error.format/2 for linearization_failed" do
    test "formats linearization failure" do
      result = Error.format({:linearization_failed, [[cmd1: 1], [cmd2: 2]]}, %{})

      assert result =~ "Linearization Failed"
      assert result =~ "Branches: 2"
      assert result =~ "race condition"
    end
  end

  describe "Error.format/2 for unknown errors" do
    test "formats unknown error gracefully" do
      result = Error.format(:some_random_error, %{})

      assert result =~ "Error"
      assert result =~ "some_random_error"
    end
  end

  # ============================================================================
  # Configuration Error Tests
  # ============================================================================

  describe "Error.format_config_error/2" do
    test "formats missing_model" do
      result = Error.format_config_error(:missing_model, nil)

      assert result =~ "Missing Model"
      assert result =~ ":model option is required"
      assert result =~ "Example:"
    end

    test "formats missing_adapter" do
      result = Error.format_config_error(:missing_adapter, nil)

      assert result =~ "Missing Adapter"
      assert result =~ ":adapter option is required"
    end

    test "formats invalid_max_commands" do
      result = Error.format_config_error(:invalid_max_commands, -5)

      assert result =~ "Invalid max_commands"
      assert result =~ "-5"
      assert result =~ "positive integer"
    end

    test "formats invalid_max_runs" do
      result = Error.format_config_error(:invalid_max_runs, "abc")

      assert result =~ "Invalid max_runs"
      assert result =~ "abc"
    end

    test "formats invalid_seed" do
      result = Error.format_config_error(:invalid_seed, -1)

      assert result =~ "Invalid seed"
      assert result =~ "-1"
    end

    test "formats empty_commands" do
      result = Error.format_config_error(:empty_commands, MyModel)

      assert result =~ "No Commands"
      assert result =~ "MyModel"
      assert result =~ "empty command list"
    end

    test "formats invalid_command_weight" do
      result = Error.format_config_error(:invalid_command_weight, {-1, MyCommand})

      assert result =~ "Invalid Command Weight"
      assert result =~ "MyCommand"
      assert result =~ "-1"
    end

    test "formats command_missing_callback" do
      result = Error.format_config_error(:command_missing_callback, {MyCommand, :events, 2})

      assert result =~ "Missing Command Callback"
      assert result =~ "MyCommand"
      assert result =~ "events/2"
    end
  end

  # ============================================================================
  # Warning Tests
  # ============================================================================

  describe "Error.format_warning/2" do
    test "formats precondition_never_true warning" do
      result = Error.format_warning(:precondition_never_true, MyCommand)

      assert result =~ "MyCommand"
      assert result =~ "never satisfied"
    end

    test "formats check_never_failed warning" do
      result = Error.format_warning(:check_never_failed, :some_check)

      assert result =~ "some_check"
      assert result =~ "never failed"
    end

    test "formats low_command_coverage warning" do
      result = Error.format_warning(:low_command_coverage, {45.5, 80})

      assert result =~ "45.5%"
      assert result =~ "80%"
    end

    test "formats command_always_fails warning" do
      result = Error.format_warning(:command_always_fails, MyCommand)

      assert result =~ "MyCommand"
      assert result =~ "always failed"
    end
  end
end
