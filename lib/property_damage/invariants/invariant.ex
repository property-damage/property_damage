defmodule PropertyDamage.Invariants.Invariant do
  @moduledoc """
  A first-class invariant: the named property a set of assertions verifies (DR-026).

  An assertion does not stand alone; it *checks* an invariant. The invariant is
  the stable, named thing a model promises to uphold, and one invariant may be
  checked by more than one assertion (for example a synchronous `@trigger` and a
  temporal `@poll_state`). Giving invariants identity lets the framework build a
  single authoritative catalog and report which invariants a run actually
  exercised (anti-vacuity coverage).

  ## Fields

  - `:id` - the canonical, unique identifier. This is the linking, uniqueness,
    lookup, and coverage-rollup key. It is an atom and unique *within a
    projection*.
  - `:name` - a human-readable display label. Defaults to `:id`; it earns its
    keep only when `id` is opaque (e.g. a ticket key like `:"JIRA-1234"`).
  - `:description` - an optional sentence describing the property.

  There is deliberately no `:kind` field. Safety-versus-liveness is a property of
  a *check*, not of an invariant (one invariant may have both a synchronous and a
  polling check); it is surfaced in the catalog, not stored here.

  ## Declaration

  Invariants are declared per projection, either centrally with an accumulating
  module attribute whose value is `new!/1`'s own argument list:

      @invariant id: :balance_nonneg, description: "Balance never drops below zero"

  or inline on the assertion that checks them:

      @trigger every: 1, id: :balance_nonneg, description: "..."
      def assert_balance(state, _), do: ...

  Other assertions link to a declared invariant with `validates: :id`. An
  assertion with neither `id:` nor `validates:` validates an invariant whose `id`
  is the assertion's own (`assert_`-stripped) name, so every existing assertion
  owns a same-named invariant by default.
  """

  @enforce_keys [:id]
  defstruct [:id, :name, :description]

  @type t :: %__MODULE__{
          id: atom(),
          name: atom(),
          description: String.t() | nil
        }

  @doc """
  Build an `%Invariant{}` from a keyword list, validating shape.

  - `:id` (required) must be a non-nil atom.
  - `:name` (optional) must be an atom; defaults to `id`.
  - `:description` (optional) must be a binary or `nil`.

  Raises `ArgumentError` on malformed input. This is the single validating code
  path: both the centralized (`@invariant`) and inline (`@trigger ... id:`)
  declaration sites build through it.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    id = Keyword.get(opts, :id)

    unless is_atom(id) and id != nil do
      raise ArgumentError,
            "invariant :id must be a non-nil atom, got: #{inspect(id)}"
    end

    name = Keyword.get(opts, :name, id)

    unless is_atom(name) and name != nil do
      raise ArgumentError,
            "invariant :name must be an atom, got: #{inspect(name)}"
    end

    description = Keyword.get(opts, :description)

    unless is_nil(description) or is_binary(description) do
      raise ArgumentError,
            "invariant :description must be a binary or nil, got: #{inspect(description)}"
    end

    %__MODULE__{id: id, name: name, description: description}
  end

  @doc """
  Resolve the `%Invariant{}` for an `id`.

  By default reads the owning projection's compile-time registry
  (`projection.__invariants__/0`), found under `ctx.projection`. Raises on an
  unknown `id` -- a condition compile-time validation makes unreachable
  post-compile, so failing fast is correct.

  This is the single resolution seam. A configurable resolver MAY later override
  the **description** (and only the description) at report time, best-effort with
  fallback to the local description; that config plumbing is deferred (DR-026
  §9). Resolution is lazy (report/catalog time only): never compile-time, never
  on the run hot path, and it never feeds generation, shrinking, or assertion
  logic.
  """
  @spec fetch!(atom(), map()) :: t()
  def fetch!(id, ctx) when is_atom(id) and is_map(ctx) do
    projection = Map.fetch!(ctx, :projection)

    invariants =
      if function_exported?(projection, :__invariants__, 0) do
        projection.__invariants__()
      else
        %{}
      end

    case Map.fetch(invariants, id) do
      {:ok, %__MODULE__{} = invariant} ->
        invariant

      :error ->
        raise ArgumentError,
              "unknown invariant #{inspect(id)} in projection #{inspect(projection)}"
    end
  end
end
