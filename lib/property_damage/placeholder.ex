defmodule PropertyDamage.Placeholder do
  @moduledoc false
  # Internal module - users never see this directly.
  #
  # Placeholders represent values that will be populated by the SUT during
  # execution. They track:
  # - Which event module and path they belong to
  # - When they were created (command and event indices)
  # - Their resolved value (once known)
  #
  # Placeholders flow through the system as follows:
  # 1. Created during simulation when external() markers are detected
  # 2. Embedded in simulated events and stored in the registry
  # 3. Resolved when real events arrive from the SUT
  # 4. Deep-resolved before projection apply/2 and command execution

  @typedoc """
  A placeholder for an external (server-generated) value.

  Fields:
  - `id` - Unique identity from `make_ref/0`
  - `event_module` - The event struct module this belongs to
  - `path` - Path to the external field within the event (e.g., [:ids, :order])
  - `command_index` - Index of the command that produced this event
  - `event_index` - Index of the event within the command's event list
  - `resolved` - The resolved concrete value (nil until resolved)
  """
  @type t :: %__MODULE__{
          id: reference(),
          event_module: module(),
          path: [atom() | non_neg_integer()],
          command_index: non_neg_integer(),
          event_index: non_neg_integer(),
          resolved: term() | nil
        }

  defstruct [:id, :event_module, :path, :command_index, :event_index, :resolved]

  @doc """
  Create a new placeholder for an external field.

  ## Parameters

  - `event_module` - The event struct module
  - `path` - Path to the external field within the event
  - `command_index` - Index of the producing command in the sequence
  - `event_index` - Index of the event within the command's event list
  """
  @spec new(module(), [atom() | non_neg_integer()], non_neg_integer(), non_neg_integer()) :: t()
  def new(event_module, path, command_index, event_index) do
    %__MODULE__{
      id: make_ref(),
      event_module: event_module,
      path: path,
      command_index: command_index,
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
            "command_index=#{p.command_index}, event_index=#{p.event_index}"
  end

  def value!(%__MODULE__{resolved: value}), do: value

  @doc """
  Create a location key for a placeholder.

  Location keys uniquely identify a placeholder by its source:
  `{event_module, path, command_index, event_index}`
  """
  @spec location_key(t()) ::
          {module(), [atom() | non_neg_integer()], non_neg_integer(), non_neg_integer()}
  def location_key(%__MODULE__{} = p) do
    {p.event_module, p.path, p.command_index, p.event_index}
  end
end

defimpl Inspect, for: PropertyDamage.Placeholder do
  @moduledoc false

  def inspect(
        %{path: path, command_index: cmd_idx, event_index: evt_idx, resolved: resolved},
        _opts
      ) do
    path_str = Enum.map_join(path, ".", &to_string/1)
    loc_str = "cmd#{cmd_idx}/evt#{evt_idx}"

    case resolved do
      nil ->
        "<Placeholder:#{path_str}@#{loc_str}>"

      value ->
        "<Placeholder:#{path_str}@#{loc_str} -> #{Kernel.inspect(value)}>"
    end
  end
end
