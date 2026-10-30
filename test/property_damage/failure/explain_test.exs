defmodule PropertyDamage.Failure.ExplainTest do
  # `Failure.Explain.meaning/1` says in plain words what each failure kind
  # means, so a reader of a report knows what to do next. The kind type of
  # `PropertyDamage.Failure` lists the kinds, so a kind added to the type
  # without a meaning fails the completeness test.
  use ExUnit.Case, async: true

  alias PropertyDamage.Failure
  alias PropertyDamage.Failure.Explain

  # The atoms of the `kind` type of `PropertyDamage.Failure`. A member that is
  # not an atom raises, so a change of the type's shape cannot shrink the list.
  defp kinds do
    {:ok, types} = Code.Typespec.fetch_types(Failure)

    {:type, {:kind, {:type, _line, :union, members}, []}} =
      Enum.find(types, &match?({:type, {:kind, _, []}}, &1))

    Enum.map(members, fn
      {:atom, _line, kind} -> kind
      other -> raise "a member of the kind type is not an atom: #{inspect(other)}"
    end)
  end

  test "every kind of the kind type has a non-empty meaning" do
    kinds = kinds()

    assert length(kinds) == 19
    assert length(Enum.uniq(kinds)) == 19

    for kind <- kinds do
      meaning = Explain.meaning(kind)

      assert is_binary(meaning) and meaning != "",
             "no meaning for #{inspect(kind)}: #{inspect(meaning)}"
    end
  end

  test "a kind outside the kind type has no meaning" do
    assert_raise FunctionClauseError, fn -> Explain.meaning(:bogus_kind) end
  end

  test "the meaning of check_failed is the agreed text" do
    assert Explain.meaning(:check_failed) ==
             "A property did not hold. After the marked step, a check judged the projection state (built from the events observed so far) and found that it violates the property."
  end

  test "the meaning of poll_timeout is the agreed text" do
    assert Explain.meaning(:poll_timeout) ==
             "An @eventually check timed out. The check polled the system until its time limit ran out, and the checked condition was still false at the last poll."
  end

  test "the meaning of idempotency_violation is the agreed text" do
    assert Explain.meaning(:idempotency_violation) ==
             "Repeating a command changed the outcome. The command is declared safe to repeat, so sending it twice must give the same result as sending it once. The Attempt fields show both outcomes."
  end

  test "the meaning of linearization is the agreed text" do
    assert Explain.meaning(:linearization) ==
             "No linear order of the commands explains the results. The commands ran at the same time, and PropertyDamage found no one-at-a-time order (a linear order) that produces the results the system returned. Either the system lets concurrent commands interfere, or the model's rules for them are wrong."
  end

  test "the meaning of settle_timeout is the agreed text" do
    assert Explain.meaning(:settle_timeout) ==
             "The system did not settle in time. PropertyDamage waits for the (eventually consistent) system to settle before it checks, and that wait ran out: no check saw a settled system."
  end

  test "the meaning of projection_violation is the agreed text" do
    assert Explain.meaning(:projection_violation) ==
             "The test could not process an event. A projection raised while it applied an event onto the test's state. Either the system sent an event the test does not expect at that point, or the projection has a defect."
  end

  test "the meaning of diverged is the agreed text" do
    assert Explain.meaning(:diverged) ==
             "Two targets ran the same plan separately and disagreed. They may have taken different but equivalent paths, and an observation settled to different values in the reference target and in the variant target. Either the system treats equivalent histories differently, or the test's claim that the paths are equivalent is wrong."
  end

  test "the meaning of did_not_converge is the agreed text" do
    assert Explain.meaning(:did_not_converge) ==
             "A target did not reach the expected state in time. An observation in the variant target was still pending when the time bound ran out. Either the system is slower than the bound allows, or it never reaches the state the observation waits for."
  end

  test "the meaning of latency_exceeded is the agreed text" do
    assert Explain.meaning(:latency_exceeded) ==
             "A target was too slow over the whole run. A latency statistic exceeded its limit. PropertyDamage judges it once, at the end, so no single step caused it."
  end

  test "the meaning of setup_failed is the agreed text" do
    assert Explain.meaning(:setup_failed) ==
             "Unable to test the system: a target could not be prepared before the test plan ran. The Cause field says which part failed: the adapter's setup, a setup command, a check on a setup event, or a value a setup command should have produced."
  end

  test "the meaning of adapter_error is the agreed text" do
    assert Explain.meaning(:adapter_error) ==
             "Unable to test the system: the adapter could not carry out the command. It raised or returned an error. Look first at whether the system was reachable, then at the adapter's error message."
  end

  test "the meaning of malformed_adapter_return is the agreed text" do
    assert Explain.meaning(:malformed_adapter_return) ==
             "Unable to test the system: the adapter returned a value PropertyDamage does not accept. This is a defect in the test's adapter, not in the system."
  end

  test "the meaning of retry_from_sync_command is the agreed text" do
    assert Explain.meaning(:retry_from_sync_command) ==
             "Unable to test the system: a command declared synchronous asked to be retried. Only asynchronous commands may ask for a retry, so the test's adapter has a defect."
  end

  test "the meaning of poll_error says the check never reported" do
    assert Explain.meaning(:poll_error) ==
             "Unable to test the system: an @eventually check never reported. The run ended and PropertyDamage waited for the check's poller to answer, but it did not, so the condition was neither confirmed nor refuted. This usually means the check's condition blocked, such as a call with no timeout."
  end

  test "the meaning of stutter_execution_failed is the agreed text" do
    assert Explain.meaning(:stutter_execution_failed) ==
             "Unable to test the system: PropertyDamage repeated a command to test that it is safe to repeat, and the repeat failed to run. Look at the adapter's error for the repeated command."
  end

  test "the meaning of resource_poller_error is the agreed text" do
    assert Explain.meaning(:resource_poller_error) ==
             "Unable to test the system: a resource poller failed while it waited on the system. Look at the poller's error and at whether the system was reachable."
  end

  test "the meaning of nemesis_error is the agreed text" do
    assert Explain.meaning(:nemesis_error) ==
             "Unable to test the system: the fault injector failed to inject or remove a fault. This is a problem in the test environment, not in the system."
  end

  test "the meaning of placeholder_resolution is the agreed text" do
    assert Explain.meaning(:placeholder_resolution) ==
             "Unable to test the system: a value the system should have created, such as an id, never arrived, so a later command could not use it. Look at the event that should have carried the value."
  end

  test "the meaning of unknown is the agreed text" do
    assert Explain.meaning(:unknown) ==
             "PropertyDamage stopped for a reason it cannot classify, so it cannot tell whether it tested the system. The Message field holds the raw reason. Report it as a PropertyDamage defect."
  end
end
