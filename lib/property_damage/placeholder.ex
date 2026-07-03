defmodule PropertyDamage.Placeholder do
  @moduledoc false
  # Internal module - users never see this directly.
  #
  # Placeholders represent values that will be populated by the SUT during
  # execution. They track:
  # - Which event module and path they belong to
  # - The structured position of the producing command (DR-021)
  # - Their resolved value (once known)
  #
  # Placeholders flow through the system as follows:
  # 1. Created during simulation when external() markers are detected
  # 2. Embedded in simulated events and stored in the registry
  # 3. Resolved when real events arrive from the SUT
  # 4. Deep-resolved before projection apply/2 and command execution

  @typedoc """
  Structured position of the producing command in a sequence.

  Branching-aware so two parallel branches producing the same event module do
  not collide. See DR-021.
  """
  @type position ::
          {:prefix, non_neg_integer()}
          | {:branch, non_neg_integer(), non_neg_integer()}
          | {:suffix, non_neg_integer()}

  @typedoc """
  A placeholder's resolution identity (DR-021, DR-036).

  A deterministic, opaque, comparable term derived from the placeholder's
  generation-time coordinates. Callers may treat it only as something with
  equality and hashability; its shape is not part of the contract.
  """
  @type id :: {position() | nil, non_neg_integer(), [atom() | non_neg_integer()]}

  @typedoc """
  A placeholder for an external (server-generated) value.

  Fields:
  - `id` - Deterministic resolution identity derived from `(position,
    event_index, path)` (DR-021, DR-036). Opaque comparable term.
  - `event_module` - The event struct module this belongs to
  - `path` - Path to the external field within the event (e.g., [:ids, :order])
  - `position` - Structured position of the producing command (DR-021)
  - `event_index` - Index of the event within the command's event list
  - `resolved` - The resolved concrete value (nil until resolved)
  """
  @type t :: %__MODULE__{
          id: id(),
          event_module: module(),
          path: [atom() | non_neg_integer()],
          position: position() | nil,
          event_index: non_neg_integer(),
          resolved: term() | nil
        }

  defstruct [:id, :event_module, :path, :position, :event_index, :resolved]

  @doc """
  Create a new placeholder identified by a structured `position` (DR-021).

  Used by sequence generation when an `external()` marker is detected. The
  producer is identified by a branching-aware `position`.

  ## Parameters

  - `event_module` - The event struct module
  - `path` - Path to the external field within the event
  - `position` - Structured position of the producing command
  - `event_index` - Index of the event within the command's event list

  The id is a pure function of `(position, event_index, path)` (DR-036), so
  two generations of the same plan produce `==` placeholders. These
  coordinates uniquely name one external field of one simulated event of one
  command within a plan, so ids do not collide within a plan (the same
  uniqueness DR-021's capture keying already relies on).
  """
  @spec new_at(module(), [atom() | non_neg_integer()], position(), non_neg_integer()) :: t()
  def new_at(event_module, path, position, event_index) do
    %__MODULE__{
      id: {position, event_index, path},
      event_module: event_module,
      path: path,
      position: position,
      event_index: event_index,
      resolved: nil
    }
  end

  @doc """
  Resolve a placeholder with a concrete value.

  Returns a new placeholder struct with the resolved value set.
  """
  @spec resolve(t(), term()) :: t()
  def resolve(%__MODULE__{} = p, value) do
    %{p | resolved: value}
  end

  @doc """
  Check if a placeholder has been resolved.
  """
  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{resolved: nil}), do: false
  def resolved?(%__MODULE__{resolved: _}), do: true

  @doc """
  Check if a value is a placeholder.
  """
  @spec placeholder?(term()) :: boolean()
  def placeholder?(%__MODULE__{}), do: true
  def placeholder?(_), do: false

  @doc """
  Get the resolved value from a placeholder.

  Raises if the placeholder is not yet resolved.
  """
  @spec value!(t()) :: term()
  def value!(%__MODULE__{resolved: nil} = p) do
    raise ArgumentError,
          "Placeholder not yet resolved: path=#{inspect(p.path)}, " <>
            "position=#{inspect(p.position)}, event_index=#{p.event_index}"
  end

  def value!(%__MODULE__{resolved: value}), do: value
end

defimpl Inspect, for: PropertyDamage.Placeholder do
  @moduledoc false

  def inspect(%{path: path, position: position, event_index: evt_idx, resolved: resolved}, _opts) do
    path_str = Enum.map_join(path, ".", &to_string/1)
    loc_str = "#{loc(position)}/evt#{evt_idx}"

    case resolved do
      nil ->
        "<Placeholder:#{path_str}@#{loc_str}>"

      value ->
        "<Placeholder:#{path_str}@#{loc_str} -> #{Kernel.inspect(value)}>"
    end
  end

  defp loc({:prefix, i}), do: "pre#{i}"
  defp loc({:branch, b, i}), do: "br#{b}.#{i}"
  defp loc({:suffix, i}), do: "suf#{i}"
  defp loc(nil), do: "?"
end
