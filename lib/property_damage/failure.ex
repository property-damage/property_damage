defmodule PropertyDamage.Failure.Check do
  @moduledoc """
  A property or invariant did not hold. See `PropertyDamage.Failure` for the kind
  table.
  """

  @type kind ::
          :check_failed
          | :idempotency_violation
          | :linearization
          | :poll_timeout
          | :settle_timeout
          | :projection_violation

  @type t :: %__MODULE__{
          kind: kind(),
          name: atom() | nil,
          detail: term()
        }

  defstruct kind: nil, name: nil, detail: nil
end

defmodule PropertyDamage.Failure.Execution do
  @moduledoc """
  The machinery around the SUT failed to run a command. See
  `PropertyDamage.Failure` for the kind table.
  """

  @type kind ::
          :adapter_error
          | :nemesis_error
          | :stutter_execution_failed
          | :resource_poller_error
          | :poll_error
          | :retry_from_sync_command
          | :malformed_adapter_return

  @type t :: %__MODULE__{
          kind: kind(),
          detail: term(),
          partial_events: [term()] | nil
        }

  defstruct kind: nil, detail: nil, partial_events: nil
end

defmodule PropertyDamage.Failure.Framework do
  @moduledoc """
  PropertyDamage itself could not proceed. See `PropertyDamage.Failure` for the
  kind table.
  """

  @type kind :: :placeholder_resolution | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          detail: term()
        }

  defstruct kind: nil, detail: nil
end

defmodule PropertyDamage.Failure.Divergence do
  @moduledoc """
  A target answered a command differently from the reference target. See
  `PropertyDamage.Failure` for the kind table.

  `root` is the index of the command whose answers differ. Each observation is
  `{:ok, events}` (the events the command injected, then the events it
  returned) or `{:error, reason}` (the adapter's error answer).
  `reference_result` is the reference target's observation, `divergent_result`
  the diverging target's, and `results` every target's, keyed by target name.
  """

  @type observation :: {:ok, [struct()]} | {:error, term()}

  @type t :: %__MODULE__{
          root: non_neg_integer() | nil,
          reference_result: observation() | nil,
          divergent_result: observation() | nil,
          results: %{String.t() => observation()} | nil
        }

  defstruct [:root, :reference_result, :divergent_result, :results]
end

defmodule PropertyDamage.Failure.Setup do
  @moduledoc """
  A target could not be brought up: its adapter's `setup/1` returned
  `{:error, term}` or raised. See `PropertyDamage.Failure` for the kind table.
  """

  @type t :: %__MODULE__{detail: term()}

  defstruct [:detail]
end

defmodule PropertyDamage.Failure do
  @moduledoc """
  The structured reason a run failed (DR-041).

  A `%Failure{}` is the single public vocabulary for *why* a run stopped. It
  replaces the loose family of `{:tag, ...}` tuples that earlier versions used as
  `failure_reason`. Every consumer that once matched a raw tuple
  (`Shrinker.failure_signature/1`, `FailureReport`, the formatter, the exporters,
  `FailureIntelligence`) now reads a `%Failure{}`.

  ## Shape

  The type is nested so that illegal class/kind combinations cannot be
  represented:

      %PropertyDamage.Failure{
        type:
          %Failure.Check{}
          | %Failure.Execution{}
          | %Failure.Framework{}
          | %Failure.Divergence{}
          | %Failure.Setup{},
        branch_id: non_neg_integer() | nil
      }

  The envelope holds the cross-class commons. `branch_id` absorbs the old
  recursive `{:branch_failure, id, inner}` wrapper: a branch failure is just an
  ordinary failure whose envelope records which branch produced it.

  Each class struct owns its `kind` (a closed, documented set), a `name` where
  one is meaningful, and a class-specific payload (`detail`, plus
  `partial_events` on `Execution`).

  ## Classes and kinds

  Kinds are **globally unique atoms** across the classes, so `{kind, name}`
  identifies a failure without also naming the class (this is what keeps the
  shrinker's equivalence relation exact; see `PropertyDamage.Shrinker`).

  ### `Failure.Check` — a property or invariant did not hold

  | kind | name | detail |
  |------|------|--------|
  | `:check_failed` | the check name | the exception, message, or reason |
  | `:idempotency_violation` | `nil` | the `%Stutter.Violation{}` |
  | `:linearization` | `nil` | a human message |
  | `:poll_timeout` | the eventually check name | the poll-timeout info map |
  | `:settle_timeout` | `nil` | the last settle error |
  | `:projection_violation` | the projection module | the raised exception |

  ### `Failure.Execution` — the machinery around the SUT failed to run

  | kind | detail | partial_events |
  |------|--------|----------------|
  | `:adapter_error` | the adapter error / exception | events captured before the error (or `nil`) |
  | `:nemesis_error` | the fault-injection error | `nil` |
  | `:stutter_execution_failed` | the retry failure details | `nil` |
  | `:resource_poller_error` | the poller error | `nil` |
  | `:poll_error` | the raised poll-predicate error | `nil` |
  | `:retry_from_sync_command` | a `:sync` command that returned `{:retry, _}` | `nil` |
  | `:malformed_adapter_return` | the unexpected adapter return value | `nil` |

  ### `Failure.Framework` — PropertyDamage itself could not proceed

  | kind | detail |
  |------|--------|
  | `:placeholder_resolution` | why a server-minted placeholder could not be resolved |
  | `:unknown` | the raw, unclassified term |

  ### `Failure.Divergence` - a target answered differently from the reference

  | kind | name | detail |
  |------|------|--------|
  | `:diverged` | `nil` | `%{root:, reference_result:, divergent_result:, results:}` |

  ### `Failure.Setup` - a target could not be brought up

  | kind | name | detail |
  |------|------|--------|
  | `:setup_failed` | `nil` | the term `setup/1` returned in `{:error, term}`, or the exception it raised |

  ## Triage

  `class/1` groups a failure for serialization and reporting. For tuning noise in
  eventually-consistent systems, check the kind directly:
  `kind in [:poll_timeout, :settle_timeout]` means the system may simply need
  more time (a tuning question), not necessarily a bug.
  """

  alias PropertyDamage.Failure.{Check, Divergence, Execution, Framework, Setup}

  @type class :: :check | :execution | :framework | :divergence | :setup

  @type kind ::
          :check_failed
          | :idempotency_violation
          | :linearization
          | :poll_timeout
          | :settle_timeout
          | :projection_violation
          | :adapter_error
          | :nemesis_error
          | :stutter_execution_failed
          | :resource_poller_error
          | :poll_error
          | :retry_from_sync_command
          | :malformed_adapter_return
          | :placeholder_resolution
          | :unknown
          | :diverged
          | :setup_failed

  @type t :: %__MODULE__{
          type: Check.t() | Execution.t() | Framework.t() | Divergence.t() | Setup.t(),
          branch_id: non_neg_integer() | nil
        }

  defstruct type: nil, branch_id: nil

  # ==========================================================================
  # Accessors
  # ==========================================================================

  @doc """
  The failure's class: `:check`, `:execution`, `:framework`, `:divergence`, or
  `:setup`.
  """
  @spec class(t()) :: class()
  def class(%__MODULE__{type: %Check{}}), do: :check
  def class(%__MODULE__{type: %Execution{}}), do: :execution
  def class(%__MODULE__{type: %Framework{}}), do: :framework
  def class(%__MODULE__{type: %Divergence{}}), do: :divergence
  def class(%__MODULE__{type: %Setup{}}), do: :setup

  @doc "The failure's globally-unique kind atom."
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{type: %Divergence{}}), do: :diverged
  def kind(%__MODULE__{type: %Setup{}}), do: :setup_failed
  def kind(%__MODULE__{type: type}), do: type.kind

  @doc "The check/projection name, or `nil` when a name is not meaningful."
  @spec name(t()) :: atom() | nil
  def name(%__MODULE__{type: %Check{name: name}}), do: name
  def name(%__MODULE__{type: _}), do: nil

  @doc """
  The class-specific payload for the failure. For a divergence it is the map
  `%{root:, reference_result:, divergent_result:, results:}`.
  """
  @spec detail(t()) :: term()
  def detail(%__MODULE__{type: %Divergence{} = divergence}) do
    Map.take(Map.from_struct(divergence), [
      :root,
      :reference_result,
      :divergent_result,
      :results
    ])
  end

  def detail(%__MODULE__{type: type}), do: type.detail

  @doc """
  Events the adapter captured before an `:adapter_error`, or `nil`.

  Only `Failure.Execution` carries partial events; every other failure returns
  `nil`.
  """
  @spec partial_events(t()) :: [term()] | nil
  def partial_events(%__MODULE__{type: %Execution{partial_events: events}}), do: events
  def partial_events(%__MODULE__{type: _}), do: nil

  @doc "The branch id that produced this failure, or `nil` for a linear run."
  @spec branch_id(t()) :: non_neg_integer() | nil
  def branch_id(%__MODULE__{branch_id: id}), do: id

  @doc "Record that `failure` occurred inside branch `branch_id`."
  @spec in_branch(t(), non_neg_integer()) :: t()
  def in_branch(%__MODULE__{} = failure, branch_id), do: %{failure | branch_id: branch_id}

  # ==========================================================================
  # Check constructors
  # ==========================================================================

  @doc "A check or invariant failed (`name` identifies which)."
  @spec check_failed(atom() | nil, term()) :: t()
  def check_failed(name, detail) do
    %__MODULE__{type: %Check{kind: :check_failed, name: name, detail: detail}}
  end

  @doc "A command was not idempotent under stutter (`detail` is the violation)."
  @spec idempotency_violation(term()) :: t()
  def idempotency_violation(violation) do
    %__MODULE__{type: %Check{kind: :idempotency_violation, detail: violation}}
  end

  @doc "No sequential ordering explained the observed parallel results."
  @spec linearization(term()) :: t()
  def linearization(message) do
    %__MODULE__{type: %Check{kind: :linearization, detail: message}}
  end

  @doc "A `@eventually` check timed out; `info` carries the details."
  @spec poll_timeout(map()) :: t()
  def poll_timeout(info) do
    name = get_in(info, [:triggered_by, :check_name])
    %__MODULE__{type: %Check{kind: :poll_timeout, name: name, detail: info}}
  end

  @doc "A probe/bridge command never settled; `detail` is the last error."
  @spec settle_timeout(term()) :: t()
  def settle_timeout(last_reason) do
    %__MODULE__{type: %Check{kind: :settle_timeout, detail: last_reason}}
  end

  @doc "A projection's `apply/2` rejected a transition (`name` is the projection)."
  @spec projection_violation(module() | atom(), term()) :: t()
  def projection_violation(projection, exception) do
    %__MODULE__{
      type: %Check{kind: :projection_violation, name: projection, detail: exception}
    }
  end

  # ==========================================================================
  # Execution constructors
  # ==========================================================================

  @doc """
  The adapter failed to execute a command.

  `partial_events` are the events captured before the error, when the caller has
  them; pass `nil` otherwise.
  """
  @spec adapter_error(term(), [term()] | nil) :: t()
  def adapter_error(reason, partial_events \\ nil) do
    %__MODULE__{
      type: %Execution{kind: :adapter_error, detail: reason, partial_events: partial_events}
    }
  end

  @doc "A nemesis (fault-injection) command failed to inject or restore."
  @spec nemesis_error(term()) :: t()
  def nemesis_error(reason) do
    %__MODULE__{type: %Execution{kind: :nemesis_error, detail: reason}}
  end

  @doc "A retry attempt during stutter testing raised."
  @spec stutter_execution_failed(term()) :: t()
  def stutter_execution_failed(details) do
    %__MODULE__{type: %Execution{kind: :stutter_execution_failed, detail: details}}
  end

  @doc "A resource poller errored."
  @spec resource_poller_error(term()) :: t()
  def resource_poller_error(reason) do
    %__MODULE__{type: %Execution{kind: :resource_poller_error, detail: reason}}
  end

  @doc "A `@eventually` predicate raised while polling."
  @spec poll_error(term()) :: t()
  def poll_error(reason) do
    %__MODULE__{type: %Execution{kind: :poll_error, detail: reason}}
  end

  @doc "A `:sync` command returned the `{:retry, _}` probe/async protocol reply."
  @spec retry_from_sync_command(term()) :: t()
  def retry_from_sync_command(detail) do
    %__MODULE__{type: %Execution{kind: :retry_from_sync_command, detail: detail}}
  end

  @doc "The adapter returned a value that is neither success, error, timeout, nor retry."
  @spec malformed_adapter_return(term()) :: t()
  def malformed_adapter_return(value) do
    %__MODULE__{type: %Execution{kind: :malformed_adapter_return, detail: value}}
  end

  # ==========================================================================
  # Divergence and setup constructors
  # ==========================================================================

  @doc """
  A target answered command `root` differently from the reference target.

  `reference_result` and `divergent_result` are the two observations; `results`
  holds every target's observation of that command, keyed by target name.
  """
  @spec diverged(non_neg_integer(), term(), term(), %{String.t() => term()}) :: t()
  def diverged(root, reference_result, divergent_result, results) do
    %__MODULE__{
      type: %Divergence{
        root: root,
        reference_result: reference_result,
        divergent_result: divergent_result,
        results: results
      }
    }
  end

  @doc """
  A target's `setup/1` failed; `detail` is the term it returned in
  `{:error, term}` or the exception it raised.
  """
  @spec setup_failed(term()) :: t()
  def setup_failed(detail) do
    %__MODULE__{type: %Setup{detail: detail}}
  end

  # ==========================================================================
  # Framework constructors
  # ==========================================================================

  @doc "A server-minted placeholder could not be resolved into a real value."
  @spec placeholder_resolution(term()) :: t()
  def placeholder_resolution(reason) do
    %__MODULE__{type: %Framework{kind: :placeholder_resolution, detail: reason}}
  end

  @doc "An unclassified failure; `detail` is the raw term."
  @spec unknown(term()) :: t()
  def unknown(term) do
    %__MODULE__{type: %Framework{kind: :unknown, detail: term}}
  end

  @check_kinds [
    :check_failed,
    :idempotency_violation,
    :linearization,
    :poll_timeout,
    :settle_timeout,
    :projection_violation
  ]

  @execution_kinds [
    :adapter_error,
    :nemesis_error,
    :stutter_execution_failed,
    :resource_poller_error,
    :poll_error,
    :retry_from_sync_command,
    :malformed_adapter_return
  ]

  @doc """
  Build a minimal `%Failure{}` carrying only a `{kind, name}` signature.

  Used by the shrinker to reconstruct a comparable failure from a signature; the
  `detail` is left `nil`. Names are only retained for `Check` kinds.
  """
  @spec from_signature(kind(), atom() | nil) :: t()
  def from_signature(kind, name) when kind in @check_kinds do
    %__MODULE__{type: %Check{kind: kind, name: name}}
  end

  def from_signature(kind, _name) when kind in @execution_kinds do
    %__MODULE__{type: %Execution{kind: kind}}
  end

  def from_signature(:diverged, _name), do: %__MODULE__{type: %Divergence{}}

  def from_signature(:setup_failed, _name), do: %__MODULE__{type: %Setup{}}

  def from_signature(kind, _name) do
    %__MODULE__{type: %Framework{kind: kind}}
  end
end
