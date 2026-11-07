defmodule PropertyDamage.Test.FakeOracle do
  @moduledoc false
  # An in-memory oracle for `PropertyDamage.Shrinker.shrink/2`: a 2-arity
  # function `(plan, mint_epoch) -> outcome` that answers from a rule and
  # records every call in an `Agent` the test reads back.
  #
  # `outcome/2` is the only place that names the shrinker's outcome struct.

  @outcome Module.concat(PropertyDamage.Shrinker, Outcome)

  @doc """
  Builds an outcome from its fields. `status` is `:passed`, `:failed`,
  `:setup_failed` or `:invalid`; a failure also carries `:signature`, `:root`
  and `:reason`.
  """
  def outcome(status, fields \\ []) do
    struct(@outcome, [{:status, status} | fields])
  end

  @doc """
  Starts the call log and returns `{oracle, log}`. `rule` receives the plan and
  the epoch and answers `:passed`, `:setup_failed`, `{:failed, root}` (a failure
  with the signature `signature`) or `{:failed, root, other_signature}`.
  """
  def start(rule, signature) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    oracle = fn plan, epoch ->
      answer = rule.(plan, epoch)
      outcome = to_outcome(answer, signature)
      Agent.update(log, &[%{plan: plan, epoch: epoch, answer: answer} | &1])
      outcome
    end

    {oracle, log}
  end

  @doc "Every call so far, oldest first."
  def calls(log), do: log |> Agent.get(& &1) |> Enum.reverse()

  @doc "Stops the log."
  def stop(log), do: Agent.stop(log)

  defp to_outcome(status, _signature) when status in [:passed, :setup_failed, :invalid],
    do: outcome(status)

  defp to_outcome({:failed, root}, signature),
    do: to_outcome({:failed, root, signature}, signature)

  defp to_outcome({:failed, root, signature}, _default) do
    outcome(:failed, signature: signature, root: root, reason: "fake oracle failure")
  end
end
