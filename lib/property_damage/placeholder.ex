defmodule PropertyDamage.Placeholder do
  @moduledoc """
  The value an `external()` field becomes inside a generated command.

  A command field can hold a value the system under test mints later, such as
  the id of a created order. PropertyDamage cannot know that value while it
  draws the sequence, so it puts a placeholder there instead.

  ## Lifecycle

  1. The symbolic phase creates a placeholder for each `external()` field of a
     simulated event.
  2. Later commands receive that placeholder in their fields, through
     projection state, `when:` predicates and `overrides:`.
  3. The concrete phase resolves the placeholder from the event the system
     returns for the producing command. A system that answers `nil` for the
     field resolves the placeholder to `nil`.
  4. Before a command runs, every placeholder in it becomes its resolved value.

  ## Reading a placeholder

  A placeholder is opaque: read it only through these functions.

    * `id/1`, `position/1`, `path/1`, `event_module/1`, `event_index/1` name
      the event field it stands for.
    * `resolved?/1` tells whether the system has answered.
    * `value/1` returns `{:ok, value}` or `:error`; `value!/1` raises when
      the placeholder is unresolved.
    * `placeholder?/1` tests any term.

  ## Example

  A `when:` predicate can ask whether a placeholder in projection state is
  resolved, and an override can pass it on unchanged:

      # In a Model's commands/0:
      {ShipOrder,
       when: fn state ->
         Enum.any?(state.orders, &PropertyDamage.Placeholder.placeholder?/1)
       end,
       overrides: fn state ->
         [order_id: state.orders |> Map.keys() |> List.first()]
       end}

      # Reading one placeholder:
      case Placeholder.value(placeholder) do
        {:ok, order_id} -> order_id
        :error -> :not_created_yet
      end
  """

  alias PropertyDamage.Sequence.Position

  @typedoc """
  Structured position of the producing command in a sequence.

  A `%PropertyDamage.Sequence.Position{}` (DR-039), so two commands producing
  the same event module do not collide (DR-021).
  """
  @type position :: Position.t()

  @typedoc """
  A placeholder's resolution identity (DR-021, DR-036).

  A deterministic, opaque, comparable term derived from the placeholder's
  generation-time coordinates. Callers may treat it only as something with
  equality and hashability; its shape is not part of the contract.
  """
  @type id :: {position() | nil, non_neg_integer(), [atom() | non_neg_integer()]}

  @typedoc """
  A placeholder for an external (server-generated) value.

  Opaque: read it through the accessors of this module. It names one event
  field (event module, path, producing position, event index) under a
  deterministic id (DR-021, DR-036), and holds either no value yet or the value
  the system answered, which can be `nil`.
  """
  @opaque t :: %__MODULE__{
            id: id(),
            event_module: module(),
            path: [atom() | non_neg_integer()],
            position: position() | nil,
            event_index: non_neg_integer(),
            resolved: :unresolved | {:resolved, term()}
          }

  defstruct [:id, :event_module, :path, :position, :event_index, resolved: :unresolved]

  @doc """
  Create a new placeholder identified by a structured `position` (DR-021).

  Used by sequence generation when an `external()` marker is detected. The
  producer is identified by its `position`.

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
      resolved: :unresolved
    }
  end

  @doc """
  The position of the command that produces the placeholder `id` names.

  An export uses it to find the step a placeholder is bound after when it
  holds only the id, as the aliases of a root that ran as leaves do.
  """
  @spec id_position(id()) :: position() | nil
  def id_position({position, _event_index, _path}), do: position

  @doc """
  The deterministic resolution id of a placeholder.
  """
  @spec id(t()) :: id()
  def id(%__MODULE__{id: id}), do: id

  @doc """
  The position of the command that produces the placeholder.
  """
  @spec position(t()) :: position() | nil
  def position(%__MODULE__{position: position}), do: position

  @doc """
  The path of the external field within its event.
  """
  @spec path(t()) :: [atom() | non_neg_integer()]
  def path(%__MODULE__{path: path}), do: path

  @doc """
  The event module the external field belongs to.
  """
  @spec event_module(t()) :: module() | nil
  def event_module(%__MODULE__{event_module: module}), do: module

  @doc """
  The index of the producing event within the command's event list.
  """
  @spec event_index(t()) :: non_neg_integer()
  def event_index(%__MODULE__{event_index: index}), do: index

  @doc """
  Make `placeholder` capture from the coordinates of `target`.

  The result keeps the id and the resolved state of `placeholder`; its
  position, event index and path become those of `target`. Used when a root
  runs as an expansion and one of its leaves produces the field.
  """
  @spec retarget(t(), t()) :: t()
  def retarget(%__MODULE__{} = placeholder, %__MODULE__{} = target) do
    %{
      placeholder
      | position: target.position,
        event_index: target.event_index,
        path: target.path
    }
  end

  @doc """
  Resolve a placeholder with a concrete value.

  Returns a new placeholder with the value set. `nil` is a value: a system
  that answers `nil` for the field resolves the placeholder to `nil`.
  """
  @spec resolve(t(), term()) :: t()
  def resolve(%__MODULE__{} = p, value) do
    %{p | resolved: {:resolved, value}}
  end

  @doc """
  Check if a placeholder has been resolved.
  """
  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{resolved: :unresolved}), do: false
  def resolved?(%__MODULE__{resolved: {:resolved, _}}), do: true

  @doc """
  Check if a value is a placeholder.
  """
  @spec placeholder?(term()) :: boolean()
  def placeholder?(%__MODULE__{}), do: true
  def placeholder?(_), do: false

  @doc """
  The resolved value of a placeholder: `{:ok, value}`, or `:error` when the
  placeholder is unresolved.
  """
  @spec value(t()) :: {:ok, term()} | :error
  def value(%__MODULE__{resolved: {:resolved, value}}), do: {:ok, value}
  def value(%__MODULE__{resolved: :unresolved}), do: :error

  @doc """
  Get the resolved value from a placeholder.

  Raises `ArgumentError` if the placeholder is not yet resolved.
  """
  @spec value!(t()) :: term()
  def value!(%__MODULE__{resolved: {:resolved, value}}), do: value

  def value!(%__MODULE__{resolved: :unresolved} = p) do
    raise ArgumentError,
          "Placeholder not yet resolved: path=#{inspect(p.path)}, " <>
            "position=#{inspect(p.position)}, event_index=#{p.event_index}"
  end
end

defimpl Inspect, for: PropertyDamage.Placeholder do
  @moduledoc false

  def inspect(%{path: path, position: position, event_index: evt_idx, resolved: resolved}, _opts) do
    path_str = Enum.map_join(path, ".", &to_string/1)
    loc_str = "#{loc(position)}/evt#{evt_idx}"

    case resolved do
      :unresolved ->
        "<Placeholder:#{path_str}@#{loc_str}>"

      {:resolved, value} ->
        "<Placeholder:#{path_str}@#{loc_str} -> #{Kernel.inspect(value)}>"
    end
  end

  alias PropertyDamage.Sequence.Position

  defp loc(%Position{section: :prefix, offset: i}), do: "pre#{i}"
  defp loc(%Position{section: :setup, offset: i}), do: "setup#{i}"
  defp loc(%Position{section: :teardown, offset: i}), do: "teardown#{i}"
  defp loc(%Position{section: {:leaf, r}, offset: i}), do: "leaf#{r}.#{i}"
  defp loc(nil), do: "?"
end
