defmodule PropertyDamage.FailureReportRobustnessTest do
  @moduledoc """
  Regression tests for failure-output crashes found in the Phase 3 review:
  the JSON serializer raising on idiomatic projection state, ErrorOrigin
  crashing on Erlang stack frames, and lazily-computed exception messages
  rendering as empty strings.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{ErrorOrigin, FailureReport}
  alias PropertyDamage.FailureReport.Formatter

  defmodule SomeEvent, do: defstruct([:id])

  defp report(opts) do
    base = [
      seed: 1,
      run_number: 0,
      failed_at_index: 0,
      original_sequence: PropertyDamage.Sequence.linear([%SomeEvent{id: 1}]),
      shrunk_sequence: PropertyDamage.Sequence.linear([%SomeEvent{id: 1}])
    ]

    FailureReport.new(Keyword.merge(base, opts))
  end

  describe "JSON format robustness" do
    test "serializes tuple-keyed and pid-valued projection state without raising" do
      projections = %{
        SomeEvent => %{
          # tuple key (e.g. {account, currency}) and a pid value: both
          # idiomatic in SPBT projection state, both used to crash
          {:acct, "USD"} => 100,
          :owner => self(),
          :ref => make_ref()
        }
      }

      rep = report(failure_reason: {:check_failed, :bal, "bad"}, projections: projections)

      json = Formatter.format(rep, :json)
      assert is_binary(json)
      # Must be valid JSON
      assert {:ok, _decoded} = Jason.decode(json)
    end

    test "preserves nil and booleans as native JSON values" do
      projections = %{SomeEvent => %{active: true, deleted: false, note: nil, n: 3}}
      rep = report(failure_reason: {:check_failed, :x, "m"}, projections: projections)

      assert {:ok, decoded} = Jason.decode(Formatter.format(rep, :json))
      fields = decoded["state_at_failure"]["SomeEvent"]["_fields"] || decoded
      # Round-tripped types survive (somewhere in the structure)
      assert json_contains_value?(decoded, true)
      assert json_contains_value?(decoded, nil)
      _ = fields
    end
  end

  describe "ErrorOrigin robustness" do
    test "classifies an Erlang-module stack frame without crashing" do
      # badarg from :erlang.binary_to_term, frame carries an args list as the
      # third element (not an integer arity), and :erlang is not an Elixir module
      stacktrace = [{:erlang, :binary_to_term, [<<131, 100>>], []}]

      classification = ErrorOrigin.classify({:adapter_error, %ArgumentError{}}, stacktrace)
      assert is_map(classification)
      assert Map.has_key?(classification, :origin)
    end

    test "FailureReport.new survives an adapter error with an Erlang stack frame" do
      rep =
        report(
          failure_reason: {:adapter_error, %ArgumentError{message: "argument error"}},
          stacktrace: [{:erlang, :binary_to_term, [<<>>], []}]
        )

      assert %FailureReport{} = rep
      assert is_binary(Formatter.format(rep, :terminal, color: false))
    end

    test "an intentional fail!/2 assertion is a SUT error" do
      reason = %PropertyDamage.AssertionFailed{message: "balance negative"}
      assert ErrorOrigin.classify({:assertion_failed, :balance, reason}).origin == :sut_error
    end

    test "an assertion whose code crashes is a TEST CODE error, not a SUT bug" do
      # The assertion function itself raised (e.g. KeyError on a missing field)
      # rather than calling fail!/2 -- that is a broken test, not a SUT bug.
      for reason <- [%KeyError{key: :foo}, {%KeyError{key: :foo}, []}] do
        classification = ErrorOrigin.classify({:assertion_failed, :x, reason})
        assert classification.origin == :test_code_error
      end
    end
  end

  describe "exception message extraction" do
    test "a KeyError assertion failure renders a non-empty message" do
      # KeyError computes its message lazily (message: nil in the struct), so
      # matching %{message: msg} first produced an empty failure_message
      key_error = %KeyError{key: :missing, term: %{}}

      rep = report(failure_reason: {:assertion_failed, :my_check, key_error})

      assert rep.failure_message != ""
      assert rep.failure_message =~ "missing" or rep.failure_message =~ "key"
    end
  end

  describe "failure_type_summary totality" do
    test "does not crash on a hand-built struct with nil failure_type" do
      assert is_binary(FailureReport.failure_type_summary(%FailureReport{}))
    end

    test "renders the new failure types" do
      for reason <- [
            {:poll_error, :boom},
            {:settle_timeout, :nope},
            {:nemesis_error, :down},
            {:resource_poller_error, :x},
            {:projection_violation, SomeEvent, %RuntimeError{message: "bad transition"}}
          ] do
        rep = report(failure_reason: reason)
        assert is_binary(FailureReport.failure_type_summary(rep))
        assert is_binary(Formatter.format(rep, :compact))
      end
    end
  end

  defp json_contains_value?(data, target) when is_map(data) do
    Enum.any?(data, fn {_k, v} -> v === target or json_contains_value?(v, target) end)
  end

  defp json_contains_value?(data, target) when is_list(data) do
    Enum.any?(data, &json_contains_value?(&1, target))
  end

  defp json_contains_value?(data, target), do: data === target
end
