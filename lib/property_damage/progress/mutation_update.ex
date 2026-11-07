defmodule PropertyDamage.Progress.MutationUpdate do
  @moduledoc """
  Intermediate progress for `PropertyDamage.Mutation.run/1` (DR-022): the outcome
  of testing a single mutation. Not the authoritative result — see
  `PropertyDamage.Progress.MutationResult`.

  One update is emitted per mutation as it is killed, killed by an adapter error, survived, or timed out.
  Each update is self-contained: it names the `command` whose events were mutated,
  the `operator` that produced the `mutation`, the `result`, an optional
  `failure_message` (present when the mutation was killed, by a check or by an
  adapter error), and the wall-clock
  `duration_ms` of that mutation's test.
  """

  @typedoc """
  `:killed` means a check caught the mutation. `:killed_by_error` means the run
  failed with an `:execution_failed` report, for example because the mutation
  made the adapter return an error, so no check caught it.
  """
  @type result :: :killed | :killed_by_error | :survived | :timeout

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
