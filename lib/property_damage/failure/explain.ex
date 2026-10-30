defmodule PropertyDamage.Failure.Explain do
  @moduledoc """
  The meaning of each failure kind, in plain words, for the failure report.

  `meaning/1` takes a kind from `PropertyDamage.Failure.kind/1` and returns a
  short text that says what the kind means and where to look first. Every kind
  has a text, and a value that is not a kind raises `FunctionClauseError`.
  """

  alias PropertyDamage.Failure

  @doc """
  The meaning of a failure kind, as one string. Raises `FunctionClauseError`
  for a value that is not a kind.
  """
  @spec meaning(Failure.kind()) :: String.t()
  def meaning(:check_failed),
    do:
      "A property did not hold. After the marked step, a check judged the projection state (built from the events observed so far) and found that it violates the property."

  def meaning(:poll_timeout),
    do:
      "An @eventually check timed out. The check polled the system until its time limit ran out, and the checked condition was still false at the last poll."

  def meaning(:idempotency_violation),
    do:
      "Repeating a command changed the outcome. The command is declared safe to repeat, so sending it twice must give the same result as sending it once. The Attempt fields show both outcomes."

  def meaning(:linearization),
    do:
      "No linear order of the commands explains the results. The commands ran at the same time, and PropertyDamage found no one-at-a-time order (a linear order) that produces the results the system returned. Either the system lets concurrent commands interfere, or the model's rules for them are wrong."

  def meaning(:settle_timeout),
    do:
      "The system did not settle in time. PropertyDamage waits for the (eventually consistent) system to settle before it checks, and that wait ran out: no check saw a settled system."

  def meaning(:projection_violation),
    do:
      "The test could not process an event. A projection raised while it applied an event onto the test's state. Either the system sent an event the test does not expect at that point, or the projection has a defect."

  def meaning(:diverged),
    do:
      "Two targets ran the same plan separately and disagreed. They may have taken different but equivalent paths, and an observation settled to different values in the reference target and in the variant target. Either the system treats equivalent histories differently, or the test's claim that the paths are equivalent is wrong."

  def meaning(:did_not_converge),
    do:
      "A target did not reach the expected state in time. An observation in the variant target was still pending when the time bound ran out. Either the system is slower than the bound allows, or it never reaches the state the observation waits for."

  def meaning(:latency_exceeded),
    do:
      "A target was too slow over the whole run. A latency statistic exceeded its limit. PropertyDamage judges it once, at the end, so no single step caused it."

  def meaning(:setup_failed),
    do:
      "Unable to test the system: a target could not be prepared before the test plan ran. The Cause field says which part failed: the adapter's setup, a setup command, a check on a setup event, or a value a setup command should have produced."

  def meaning(:adapter_error),
    do:
      "Unable to test the system: the adapter could not carry out the command. It raised or returned an error. Look first at whether the system was reachable, then at the adapter's error message."

  def meaning(:malformed_adapter_return),
    do:
      "Unable to test the system: the adapter returned a value PropertyDamage does not accept. This is a defect in the test's adapter, not in the system."

  def meaning(:retry_from_sync_command),
    do:
      "Unable to test the system: a command declared synchronous asked to be retried. Only asynchronous commands may ask for a retry, so the test's adapter has a defect."

  def meaning(:poll_error),
    do:
      "Unable to test the system: the condition of an @eventually check raised an error while polling. This usually means the check itself has a defect."

  def meaning(:stutter_execution_failed),
    do:
      "Unable to test the system: PropertyDamage repeated a command to test that it is safe to repeat, and the repeat failed to run. Look at the adapter's error for the repeated command."

  def meaning(:resource_poller_error),
    do:
      "Unable to test the system: a resource poller failed while it waited on the system. Look at the poller's error and at whether the system was reachable."

  def meaning(:nemesis_error),
    do:
      "Unable to test the system: the fault injector failed to inject or remove a fault. This is a problem in the test environment, not in the system."

  def meaning(:placeholder_resolution),
    do:
      "Unable to test the system: a value the system should have created, such as an id, never arrived, so a later command could not use it. Look at the event that should have carried the value."

  def meaning(:unknown),
    do:
      "PropertyDamage stopped for a reason it cannot classify, so it cannot tell whether it tested the system. The Message field holds the raw reason. Report it as a PropertyDamage defect."
end
