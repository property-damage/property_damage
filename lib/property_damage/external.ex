defprotocol PropertyDamage.ExternalMarker do
  @moduledoc """
  Protocol for custom external marker types.

  Domain libraries can define their own external marker types that implement
  this protocol, enabling external field markers without depending on PropertyDamage.

  ## Example

      defmodule MyDomain.ExternalId do
        defstruct [:field_name]
      end

      defimpl PropertyDamage.ExternalMarker, for: MyDomain.ExternalId do
        def external?(_), do: true
      end

  Then in your test project, these markers will be recognized automatically.
  """

  @doc "Returns true if this value is an external marker"
  @fallback_to_any true
  @spec external?(term()) :: boolean()
  def external?(value)
end

defimpl PropertyDamage.ExternalMarker, for: Any do
  def external?(_), do: false
end

defmodule PropertyDamage.External do
  @moduledoc """
  Sentinel value marking a field as server-generated (external).

  Use `external()` as the default value in event struct definitions to mark
  fields that will be populated by the System Under Test (SUT) during execution.

  ## Basic Usage

      defmodule MyApp.Events.OrderCreated do
        import PropertyDamage, only: [external: 0]

        # id is server-generated, amount and customer_id come from the command
        defstruct [:amount, :customer_id, id: external()]
      end

  ## Multiple Externals

  Events can have multiple external fields:

      defmodule MyApp.Events.PaymentProcessed do
        import PropertyDamage, only: [external: 0]

        defstruct [
          payment_id: external(),
          transaction_ref: external(),
          :order_id,
          :amount
        ]
      end

  ## Nested Externals

  Externals are supported in nested maps and structs:

      defmodule MyApp.Events.TransactionCompleted do
        import PropertyDamage, only: [external: 0]

        defstruct [
          ids: %{transaction: external(), confirmation: external()},
          :amount,
          :timestamp
        ]
      end

  Paths are tracked as lists: `[:ids, :transaction]`, `[:ids, :confirmation]`

  ## Fixed-Length Lists

  Externals are supported in fixed-length lists where the count is known
  at struct definition time:

      defmodule MyApp.Events.BatchCreated do
        import PropertyDamage, only: [external: 0]

        # 3 server-generated IDs (indices tracked: [:item_ids, 0], etc.)
        defstruct [
          item_ids: [external(), external(), external()],
          :batch_name
        ]
      end

  ## Custom External Markers

  Domain libraries that don't depend on PropertyDamage can use atom sentinels
  or custom structs implementing the `PropertyDamage.ExternalMarker` protocol:

      # In domain library (no PropertyDamage dependency)
      defmodule MyDomain.Events.OrderCreated do
        defstruct [id: :__external__, :amount]
      end

      # In test project
      PropertyDamage.run(model: M, adapter: A, external_markers: [:__external__])

  ## Limitations

  Variable-length lists where the count isn't known at struct definition
  time are **not supported**. If you need a variable number of external IDs,
  mark the entire list as `external()` and have the SUT return the complete list.

  ## How It Works

  1. During simulation, the framework detects `external()` markers and replaces
     them with internal placeholders
  2. During execution, real values from the SUT are captured
  3. Before projection `apply/2` is called, placeholders are resolved to real values
  4. Commands that use these values get resolved placeholders automatically

  Users never see placeholders - they work with concrete values in projections
  and command generators.
  """

  @typedoc "External marker struct - used as sentinel in struct definitions"
  @type t :: %__MODULE__{}

  defstruct []

  @doc """
  Create an external marker for use in struct definitions.

  ## Example

      defstruct [:name, :amount, id: external()]
  """
  @spec external() :: t()
  def external, do: %__MODULE__{}

  @doc """
  Check if a value is an external marker.

  Recognizes:
  - `%PropertyDamage.External{}` struct (always)
  - Values implementing `PropertyDamage.ExternalMarker` protocol

  Atom markers (e.g. a domain library's `:__external__`) are recognized only
  via an explicit markers list: pass them as the `external_markers:` run option,
  which threads through to `external?/2`. There is no ambient app-config channel
  (DR-032).

  ## Examples

      iex> PropertyDamage.External.external?(%PropertyDamage.External{})
      true

      iex> PropertyDamage.External.external?("some_id")
      false

      iex> PropertyDamage.External.external?(:__external__)
      false
  """
  @spec external?(term()) :: boolean()
  def external?(%__MODULE__{}), do: true

  def external?(value) do
    PropertyDamage.ExternalMarker.external?(value)
  end

  @doc """
  Check if a value is an external marker with explicit markers list.

  The explicit markers list is the sole source of atom markers (DR-032).

  ## Examples

      iex> PropertyDamage.External.external?(:__external__, [:__external__])
      true

      iex> PropertyDamage.External.external?(%PropertyDamage.External{}, [])
      true
  """
  @spec external?(term(), [atom()]) :: boolean()
  def external?(%__MODULE__{}, _markers), do: true

  def external?(value, markers) when is_atom(value) and not is_nil(value) and is_list(markers) do
    value in markers
  end

  def external?(value, _markers) do
    PropertyDamage.ExternalMarker.external?(value)
  end

  @doc """
  Get paths to fields marked as external() in a struct module.

  Recognizes only intrinsic markers (`%PropertyDamage.External{}` and protocol
  implementers). For atom markers, pass them explicitly via `external_paths/2`.

  Returns a list of paths where each path is a list of keys/indices.
  Paths are returned in depth-first order.

  ## Examples

      # Simple: defstruct [:amount, id: external()]
      External.external_paths(OrderCreated)
      #=> [[:id]]

      # Nested: defstruct [ids: %{order: external(), confirm: external()}]
      External.external_paths(TransactionEvent)
      #=> [[:ids, :order], [:ids, :confirm]]

      # List: defstruct [item_ids: [external(), external()]]
      External.external_paths(BatchEvent)
      #=> [[:item_ids, 0], [:item_ids, 1]]
  """
  @spec external_paths(module()) :: [[atom() | non_neg_integer()]]
  def external_paths(module) when is_atom(module) do
    external_paths(module, [])
  end

  @doc """
  Get paths to fields marked as external() in a struct module with explicit markers.

  The explicit markers list is the sole source of atom markers (DR-032).

  ## Examples

      # Domain library uses :__external__ as marker
      External.external_paths(DomainEvent, [:__external__])
      #=> [[:id]]
  """
  @spec external_paths(module(), [atom()]) :: [[atom() | non_neg_integer()]]
  def external_paths(module, markers) when is_atom(module) and is_list(markers) do
    module.__struct__()
    |> Map.from_struct()
    |> find_external_paths([], [], markers)
    |> Enum.reverse()
  end

  defp find_external_paths(value, current_path, acc, markers) do
    cond do
      external?(value, markers) ->
        [Enum.reverse(current_path) | acc]

      is_struct(value) ->
        value
        |> Map.from_struct()
        |> Enum.reduce(acc, fn {key, v}, a ->
          find_external_paths(v, [key | current_path], a, markers)
        end)

      is_map(value) ->
        Enum.reduce(value, acc, fn {key, v}, a ->
          find_external_paths(v, [key | current_path], a, markers)
        end)

      is_list(value) ->
        value
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {v, index}, a ->
          find_external_paths(v, [index | current_path], a, markers)
        end)

      true ->
        acc
    end
  end

  @doc """
  Get the value at a path in a nested structure.

  Supports map keys and list indices.

  ## Examples

      iex> data = %{ids: %{order: "123", confirm: "456"}}
      iex> PropertyDamage.External.get_at_path(data, [:ids, :order])
      "123"

      iex> data = %{items: ["a", "b", "c"]}
      iex> PropertyDamage.External.get_at_path(data, [:items, 1])
      "b"
  """
  @spec get_at_path(term(), [atom() | non_neg_integer()]) :: term()
  def get_at_path(data, []), do: data

  def get_at_path(data, [key | rest]) when is_map(data) do
    get_at_path(Map.get(data, key), rest)
  end

  def get_at_path(data, [index | rest]) when is_list(data) and is_integer(index) do
    get_at_path(Enum.at(data, index), rest)
  end

  def get_at_path(_, _), do: nil

  @doc """
  Put a value at a path in a nested structure.

  Supports map keys and list indices. Creates intermediate structures as needed.

  ## Examples

      iex> data = %{ids: %{order: nil}}
      iex> PropertyDamage.External.put_at_path(data, [:ids, :order], "123")
      %{ids: %{order: "123"}}

      iex> data = %{items: [nil, nil]}
      iex> PropertyDamage.External.put_at_path(data, [:items, 0], "a")
      %{items: ["a", nil]}
  """
  @spec put_at_path(term(), [atom() | non_neg_integer()], term()) :: term()
  def put_at_path(_data, [], value), do: value

  def put_at_path(data, [key | rest], value) when is_map(data) do
    current = Map.get(data, key, %{})
    Map.put(data, key, put_at_path(current, rest, value))
  end

  def put_at_path(data, [index | rest], value) when is_list(data) and is_integer(index) do
    List.update_at(data, index, fn elem -> put_at_path(elem, rest, value) end)
  end

  @doc """
  Check if a data structure contains any external markers.

  Uses app config markers only. For explicit markers, use `contains_external?/2`.

  Useful for validation - commands should not contain externals.

  ## Example

      iex> PropertyDamage.External.contains_external?(%{id: %PropertyDamage.External{}})
      true

      iex> PropertyDamage.External.contains_external?(%{id: "123"})
      false
  """
  @spec contains_external?(term()) :: boolean()
  def contains_external?(value), do: contains_external?(value, [])

  @doc """
  Check if a data structure contains any external markers with explicit markers list.

  The explicit markers list is combined with app config markers.

  ## Example

      iex> PropertyDamage.External.contains_external?(%{id: :__external__}, [:__external__])
      true
  """
  @spec contains_external?(term(), [atom()]) :: boolean()
  def contains_external?(%__MODULE__{}, _markers), do: true

  def contains_external?(value, markers) when is_atom(value) and not is_nil(value) do
    external?(value, markers)
  end

  def contains_external?(%{__struct__: _} = struct, markers) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(&contains_external?(&1, markers))
  end

  def contains_external?(map, markers) when is_map(map) do
    map
    |> Map.values()
    |> Enum.any?(&contains_external?(&1, markers))
  end

  def contains_external?(list, markers) when is_list(list) do
    Enum.any?(list, &contains_external?(&1, markers))
  end

  def contains_external?(tuple, markers) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(&contains_external?(&1, markers))
  end

  def contains_external?(value, markers) do
    PropertyDamage.ExternalMarker.external?(value) or external?(value, markers)
  end
end

defimpl Inspect, for: PropertyDamage.External do
  def inspect(_external, _opts) do
    "external()"
  end
end

defimpl PropertyDamage.ExternalMarker, for: PropertyDamage.External do
  def external?(_), do: true
end
