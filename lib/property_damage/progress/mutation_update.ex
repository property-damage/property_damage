defmodule PropertyDamage.Progress.MutationUpdate do
  @moduledoc """
  Intermediate progress for `PropertyDamage.Mutation.run/1` (DR-022): the outcome
  of testing a single mutation. Not the authoritative result — see
  `PropertyDamage.Progress.MutationResult`.

  One update is emitted per mutation as it is killed, survived, or timed out.
  Each update is self-contained: it names the `command` whose events were mutated,
  the `operator` that produced the `mutation`, the `result`, an optional
  `failure_message` (present when the mutation was killed), and the wall-clock
  `duration_ms` of that mutation's test.
  """

  @type result :: :killed | :survived | :timeout

  @type t :: %__MODULE__{
          command: module(),
          operator: atom(),
          mutation: term(),
          result: result(),
          failure_message: String.t() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @enforce_keys [:command, :operator, :mutation, :result]
  defstruct [:command, :operator, :mutation, :result, :failure_message, :duration_ms]
end
