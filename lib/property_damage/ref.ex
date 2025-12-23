defmodule PropertyDamage.Ref do
  @moduledoc """
  Symbolic references for entity IDs in stateful property-based testing.

  Refs are placeholders that represent entity identities before concrete
  values are known. They enable the framework to generate command sequences
  that refer to entities created by earlier commands, without needing to
  know the actual IDs upfront.

  ## Lifecycle

  Refs have a three-phase lifecycle:

  1. **Symbolic Phase** - During command sequence generation, `symbolic/1`
     creates a ref with a unique identity via `make_ref/0`. The ref has no
     concrete value yet.

  2. **Concrete Phase** - During execution against the System Under Test (SUT),
     the Adapter executes a command and gets a real ID back (e.g., `"ord_abc123"`).
     The framework calls `resolve/2` to associate the ref with this value.

  3. **Usage Phase** - Subsequent commands that reference this entity use
     the same ref. The framework automatically resolves refs to concrete
     values when executing commands via `value!/1`.

  ## Identity

  Two refs are considered equal only if they have the same `ref` field (the
  result of `make_ref/0`). The `label` field is purely for debugging/display
  and does not affect identity - two refs with the same label are still distinct.

  ## Example

      # During command generation (symbolic phase)
      order_ref = Ref.symbolic(label: "order")
      # => %Ref{ref: #Reference<...>, label: "order", resolved: Unresolved}

      # During execution (concrete phase)
      resolved_ref = Ref.resolve(order_ref, "ord_abc123")
      # => %Ref{ref: #Reference<...>, label: "order", resolved: "ord_abc123"}

      # Getting the value
      Ref.value!(resolved_ref)
      # => "ord_abc123"

  ## Framework Internals

  The executor maintains a `ref_table` mapping ref identities to concrete values.
  Commands and projections work with pure domain state - they don't need to
  understand ref resolution. The framework handles resolution transparently.
  """

  alias PropertyDamage.Ref.Unresolved

  @typedoc """
  A symbolic reference to an entity.

  - `ref` - Unique identity from `make_ref/0`
  - `label` - Optional debug label (does not affect identity)
  - `resolved` - Either `Unresolved` (sentinel) or the concrete value
  """
  @type t :: %__MODULE__{
          ref: reference(),
          label: String.t() | nil,
          resolved: any() | Unresolved
        }

  defstruct [:ref, :label, resolved: Unresolved]

  @doc """
  Create a symbolic ref during command generation.

  The optional `label` is for debugging/display purposes only (like IO.inspect's label).
  It does not affect identity - two refs with the same label are still distinct.

  ## Options

  - `:label` - A string label for debugging (optional)

  ## Examples

      iex> ref = PropertyDamage.Ref.symbolic()
      iex> PropertyDamage.Ref.resolved?(ref)
      false

      iex> ref = PropertyDamage.Ref.symbolic(label: "order")
      iex> ref.label
      "order"
  """
  @spec symbolic(keyword()) :: t()
  def symbolic(opts \\ []) do
    %__MODULE__{
      ref: make_ref(),
      label: Keyword.get(opts, :label)
    }
  end

  @doc """
  Resolve a ref with a concrete value during execution.

  This is called by the framework after executing a command that creates
  an entity. The returned ref has the same identity but now carries the
  concrete value.

  ## Examples

      iex> ref = PropertyDamage.Ref.symbolic()
      iex> resolved = PropertyDamage.Ref.resolve(ref, "ord_123")
      iex> PropertyDamage.Ref.resolved?(resolved)
      true
      iex> PropertyDamage.Ref.value!(resolved)
      "ord_123"
  """
  @spec resolve(t(), any()) :: t()
  def resolve(%__MODULE__{} = ref, value) do
    %{ref | resolved: value}
  end

  @doc """
  Check if a ref has been resolved to a concrete value.

  ## Examples

      iex> ref = PropertyDamage.Ref.symbolic()
      iex> PropertyDamage.Ref.resolved?(ref)
      false

      iex> ref = PropertyDamage.Ref.symbolic() |> PropertyDamage.Ref.resolve("123")
      iex> PropertyDamage.Ref.resolved?(ref)
      true
  """
  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{resolved: Unresolved}), do: false
  def resolved?(%__MODULE__{}), do: true

  @doc """
  Get the resolved value from a ref.

  Raises if the ref has not been resolved yet.

  ## Examples

      iex> ref = PropertyDamage.Ref.symbolic() |> PropertyDamage.Ref.resolve("abc")
      iex> PropertyDamage.Ref.value!(ref)
      "abc"

  ## Raises

  - `RuntimeError` - If the ref is not yet resolved
  """
  @spec value!(t()) :: any()
  def value!(%__MODULE__{resolved: Unresolved}) do
    raise "Ref not yet resolved"
  end

  def value!(%__MODULE__{resolved: value}), do: value
end

defimpl Inspect, for: PropertyDamage.Ref do
  @moduledoc false

  alias PropertyDamage.Ref.Unresolved

  @doc """
  Custom inspect format for Refs.

  - Unresolved: `<Ref:label:short_ref>`
  - Resolved: `<Ref:label:short_ref → value>`

  The short_ref is the last number from the reference (e.g., 220539 from
  `#Ref<0.xxx.xxx.220539>`), providing a readable unique identifier.
  """
  def inspect(%{ref: ref, label: label, resolved: resolved}, _opts) do
    label_part = if label, do: "#{label}:", else: ""
    ref_short = extract_ref_id(ref)

    case resolved do
      Unresolved ->
        "<Ref:#{label_part}#{ref_short}>"

      value ->
        "<Ref:#{label_part}#{ref_short} -> #{Kernel.inspect(value)}>"
    end
  end

  # Extract the unique ID from a reference.
  # ref_to_list returns a charlist like '#Ref<0.xxx.xxx.12345>'
  # We extract the last number (12345) as the short identifier.
  defp extract_ref_id(ref) do
    ref
    |> :erlang.ref_to_list()
    |> List.to_string()
    |> String.split(".")
    |> List.last()
    |> String.trim_trailing(">")
  end
end
