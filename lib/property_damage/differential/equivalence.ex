defmodule PropertyDamage.Differential.Equivalence do
  @moduledoc false

  @type strategy :: :exact | :structural | (term(), term() -> boolean())

  # Fields commonly containing non-deterministic values
  @structural_ignore_fields [
    :id,
    :inserted_at,
    :updated_at,
    :created_at,
    :timestamp,
    :uuid,
    :request_id,
    :correlation_id
  ]

  @doc """
  Check if two results are equivalent according to the given strategy.
  """
  @spec equivalent?(term(), term(), strategy()) :: boolean()
  def equivalent?(result_a, result_b, strategy \\ :exact)

  def equivalent?(result_a, result_b, :exact) do
    result_a == result_b
  end

  def equivalent?(result_a, result_b, :structural) do
    normalize(result_a) == normalize(result_b)
  end

  def equivalent?(result_a, result_b, fun) when is_function(fun, 2) do
    fun.(result_a, result_b)
  end

  @doc """
  Normalize a result by removing non-deterministic fields.

  Used by the `:structural` strategy.
  """
  @spec normalize(term()) :: term()
  def normalize({:ok, events}) when is_list(events) do
    {:ok, Enum.map(events, &normalize_value/1)}
  end

  def normalize({:ok, value}) do
    {:ok, normalize_value(value)}
  end

  def normalize({:error, reason}) do
    {:error, normalize_value(reason)}
  end

  def normalize(other) do
    normalize_value(other)
  end

  defp normalize_value(%{__struct__: module} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_map()
    |> then(&struct(module, &1))
  end

  defp normalize_value(map) when is_map(map) do
    normalize_map(map)
  end

  defp normalize_value(list) when is_list(list) do
    Enum.map(list, &normalize_value/1)
  end

  defp normalize_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_value/1)
    |> List.to_tuple()
  end

  defp normalize_value(other), do: other

  defp normalize_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> k in @structural_ignore_fields end)
    |> Enum.map(fn {k, v} -> {k, normalize_value(v)} end)
    |> Map.new()
  end

  @doc """
  Create a structural equivalence strategy that ignores specific fields.
  """
  @spec ignore_fields([atom()]) :: (term(), term() -> boolean())
  def ignore_fields(fields) when is_list(fields) do
    fn result_a, result_b ->
      normalize_with_fields(result_a, fields) == normalize_with_fields(result_b, fields)
    end
  end

  defp normalize_with_fields({:ok, events}, fields) when is_list(events) do
    {:ok, Enum.map(events, &normalize_value_with_fields(&1, fields))}
  end

  defp normalize_with_fields({:ok, value}, fields) do
    {:ok, normalize_value_with_fields(value, fields)}
  end

  defp normalize_with_fields({:error, reason}, fields) do
    {:error, normalize_value_with_fields(reason, fields)}
  end

  defp normalize_with_fields(other, fields) do
    normalize_value_with_fields(other, fields)
  end

  defp normalize_value_with_fields(%{__struct__: module} = struct, fields) do
    struct
    |> Map.from_struct()
    |> normalize_map_with_fields(fields)
    |> then(&struct(module, &1))
  end

  defp normalize_value_with_fields(map, fields) when is_map(map) do
    normalize_map_with_fields(map, fields)
  end

  defp normalize_value_with_fields(list, fields) when is_list(list) do
    Enum.map(list, &normalize_value_with_fields(&1, fields))
  end

  defp normalize_value_with_fields(tuple, fields) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_value_with_fields(&1, fields))
    |> List.to_tuple()
  end

  defp normalize_value_with_fields(other, _fields), do: other

  defp normalize_map_with_fields(map, fields) do
    map
    |> Enum.reject(fn {k, _v} -> k in fields end)
    |> Enum.map(fn {k, v} -> {k, normalize_value_with_fields(v, fields)} end)
    |> Map.new()
  end

  @doc """
  Create an equivalence strategy that only compares specific fields.
  """
  @spec only_fields([atom()]) :: (term(), term() -> boolean())
  def only_fields(fields) when is_list(fields) do
    fn result_a, result_b ->
      extract_fields(result_a, fields) == extract_fields(result_b, fields)
    end
  end

  defp extract_fields({:ok, events}, fields) when is_list(events) do
    {:ok, Enum.map(events, &extract_value_fields(&1, fields))}
  end

  defp extract_fields({:ok, value}, fields) do
    {:ok, extract_value_fields(value, fields)}
  end

  defp extract_fields({:error, _} = error, _fields), do: error

  defp extract_fields(other, fields), do: extract_value_fields(other, fields)

  defp extract_value_fields(%{__struct__: module} = struct, fields) do
    struct
    |> Map.from_struct()
    |> Map.take(fields)
    |> then(&struct(module, &1))
  end

  defp extract_value_fields(map, fields) when is_map(map) do
    Map.take(map, fields)
  end

  defp extract_value_fields(list, fields) when is_list(list) do
    Enum.map(list, &extract_value_fields(&1, fields))
  end

  defp extract_value_fields(other, _fields), do: other
end
