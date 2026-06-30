defmodule PropertyDamage.Await do
  @moduledoc """
  A correlation declaration: which inbound (injector) event a command claims.

  A command declares awaits via `c:PropertyDamage.Command.awaits/2`, returning a
  list of `%Await{}`. Each carries a `match` predicate `(event -> boolean)` built
  from the command's own resolved fields (and captured response), forming a
  correlation key.

  ## Pure correlation, not judgment (DR-030)

  An `%Await{}` only *correlates*: when an injector event satisfies its `match`,
  the framework attributes that event to the declaring command's `command_index`
  (instead of the ambient `nil`), persistently for the rest of the run. It does
  **not** block, time out, or assert anything on its own.

  All *judgment* over a command's correlated set lives in projections, reusing
  the existing assertion machinery rather than a second bespoke await path:

    * **liveness** ("the event must eventually arrive") is a `@poll_state`
      assertion over the correlated set;
    * **safety / cardinality** ("at most one", "exactly N") is a `@trigger`/
      `@invariant` assertion over the correlated set.

  This keeps one surface for correlation (`awaits/2`) and one surface for
  judgment (projections). The internal `EventQueue` is already awaited by the
  `@poll_state` finalize drain, so liveness needs no separate await loop.

  ## Multiplicity

  An injector event satisfies **at most one** await: when several registered
  matchers match the same event, the **first-registered** wins (deterministic),
  and the framework logs an overlap diagnostic. Events matching no await fold as
  ambient (`command_index: nil`), exactly as before.

  ## Example

      defmodule CloseIssue do
        use PropertyDamage.Command
        defstruct [:issue_id]

        @impl true
        def generator(overrides \\\\ %{}) do
          %{issue_id: StreamData.string(:alphanumeric, min_length: 1)}
          |> PropertyDamage.Generator.merge_overrides(overrides)
          |> StreamData.fixed_map()
        end

        # Correlate the webhook delivered for *this* issue back to this command.
        @impl true
        def awaits(_state, %__MODULE__{issue_id: id}) do
          [%PropertyDamage.Await{match: &match?(%IssueClosedWebhook{issue_id: ^id}, &1)}]
        end
      end
  """

  @typedoc """
  A correlation declaration.

  * `:match` - predicate `(event -> boolean)` identifying the injector events
    this command claims. Should be total (return `false`, not raise, for
    unrelated events).
  """
  @type t :: %__MODULE__{
          match: (struct() -> boolean())
        }

  @enforce_keys [:match]
  defstruct [:match]
end
