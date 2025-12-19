defmodule PropertyDamage.Generator do
  @moduledoc """
  Utilities for building composable command generators.

  This module provides helper functions for the two-layer generator
  architecture used by commands. The key function is `merge_overrides/2`
  which enables flexible composition of generators.

  ## Auto-Lifting

  Raw values passed as overrides are automatically wrapped in
  `StreamData.constant/1`. This allows both static values and
  generators to be used interchangeably:

      # These are equivalent:
      merge_overrides(base, %{currency: "USD"})
      merge_overrides(base, %{currency: StreamData.constant("USD")})

      # But you can also pass generators:
      merge_overrides(base, %{currency: StreamData.member_of(["USD", "EUR"])})

  ## Composability Pattern

  Commands can reuse and extend other commands' generators:

      defmodule CreateHighValueOrder do
        def generator(overrides \\\\ %{}) do
          # Reuse CreateOrder's generator with constrained amount
          CreateOrder.generator(%{amount: StreamData.integer(10_000..100_000)})
          |> Map.merge(overrides)
        end
      end
  """

  @doc """
  Merge overrides into base generators, auto-lifting raw values.

  Raw values are automatically wrapped in `StreamData.constant/1`.
  StreamData generators are passed through unchanged.

  ## Parameters

  - `base` - Map of field names to StreamData generators
  - `overrides` - Map of field names to values or generators to override

  ## Returns

  A map suitable for passing to `StreamData.fixed_map/1`.

  ## Examples

      iex> base = %{amount: StreamData.positive_integer(), currency: StreamData.constant("USD")}
      iex> result = PropertyDamage.Generator.merge_overrides(base, %{currency: "EUR"})
      iex> is_map(result)
      true

      iex> base = %{amount: StreamData.positive_integer()}
      iex> result = PropertyDamage.Generator.merge_overrides(base, %{amount: StreamData.integer(1..10)})
      iex> is_map(result)
      true
  """
  @spec merge_overrides(map(), map()) :: map()
  def merge_overrides(base, overrides) do
    Map.merge(base, lift_values(overrides))
  end

  @doc """
  Check if a value is a StreamData generator.

  ## Examples

      iex> PropertyDamage.Generator.stream_data?(StreamData.integer())
      true

      iex> PropertyDamage.Generator.stream_data?(42)
      false

      iex> PropertyDamage.Generator.stream_data?("hello")
      false
  """
  @spec stream_data?(any()) :: boolean()
  def stream_data?(%StreamData{}), do: true
  def stream_data?(_), do: false

  # Lift all values in a map, wrapping non-StreamData values in constant/1
  defp lift_values(map) do
    Map.new(map, fn {k, v} -> {k, lift(v)} end)
  end

  # Pass through StreamData generators unchanged
  defp lift(%StreamData{} = gen), do: gen

  # Wrap raw values in constant/1
  defp lift(value), do: StreamData.constant(value)
end
