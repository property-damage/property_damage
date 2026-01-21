defmodule PropertyDamage.External do
  @moduledoc """
  Sentinel value marking a field as server-generated (external).

  Use `external()` as the default value in event struct definitions to mark
  fields that will be populated by the System Under Test (SUT) during execution.

  ## Basic Usage

      defmodule MyApp.Events.OrderCreated do
        import PropertyDamage, only: [external: 0]

        # id is server-generated, amount and customer_id come from the command
        defstruct [id: external(), :amount, :customer_id]
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

      defstruct [id: external(), :name, :amount]
  """
  @spec external() :: t()
  def external, do: %__MODULE__{}

  @doc """
  Check if a value is an external marker.

  ## Examples

      iex> PropertyDamage.External.external?(%PropertyDamage.External{})
      true

      iex> PropertyDamage.External.external?("some_id")
      false
  """
  @spec external?(term()) :: boolean()
  def external?(%__MODULE__{}), do: true
  def external?(_), do: false

  @doc """
  Get paths to fields marked as external() in a struct module.

  Returns a list of paths where each path is a list of keys/indices.
  Paths are returned in depth-first order.

  ## Examples

      # Simple: defstruct [id: external(), :amount]
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
    module.__struct__()
    |> Map.from_struct()
    |> find_external_paths([], [])
    |> Enum.reverse()
  end

  defp find_external_paths(%__MODULE__{}, current_path, acc) do
    [Enum.reverse(current_path) | acc]
  end

  defp find_external_paths(%{__struct__: _} = struct, current_path, acc) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(acc, fn {key, value}, acc ->
      find_external_paths(value, [key | current_path], acc)
    end)
  end

  defp find_external_paths(map, current_path, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, acc ->
      find_external_paths(value, [key | current_path], acc)
    end)
  end

  defp find_external_paths(list, current_path, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, acc ->
      find_external_paths(value, [index | current_path], acc)
    end)
  end

  defp find_external_paths(_other, _current_path, acc), do: acc

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

  Useful for validation - commands should not contain externals.

  ## Example

      iex> PropertyDamage.External.contains_external?(%{id: %PropertyDamage.External{}})
      true

      iex> PropertyDamage.External.contains_external?(%{id: "123"})
      false
  """
  @spec contains_external?(term()) :: boolean()
  def contains_external?(%__MODULE__{}), do: true

  def contains_external?(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(&contains_external?/1)
  end

  def contains_external?(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.any?(&contains_external?/1)
  end

  def contains_external?(list) when is_list(list) do
    Enum.any?(list, &contains_external?/1)
  end

  def contains_external?(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(&contains_external?/1)
  end

  def contains_external?(_), do: false
end

defimpl Inspect, for: PropertyDamage.External do
  def inspect(_external, _opts) do
    "external()"
  end
end
