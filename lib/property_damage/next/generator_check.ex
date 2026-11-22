defmodule PropertyDamage.Next.GeneratorCheck do
  @moduledoc false
  # The test every value in a generator map and every assign must pass:
  # StreamData's own test of a generator (a %StreamData{}, an atom, or a
  # tuple of generators), widened to PD's descriptions and delegated values,
  # plus a mint marker.

  alias PropertyDamage.Next.Gen

  @doc "Whether `value` is a generator or a mint marker."
  def accepted?(%PropertyDamage.Mint{}), do: true
  def accepted?(value), do: generator?(value)

  @doc "Whether `value` is a generator."
  def generator?(%StreamData{}), do: true
  def generator?(%Gen{}), do: true
  def generator?(atom) when is_atom(atom), do: true

  def generator?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.all?(&generator?/1)

  def generator?(_other), do: false

  @doc "Raises `ArgumentError` for a value that is not accepted, saying where it was found."
  def refuse!(value, where) do
    raise ArgumentError,
          "#{where}: expected a generator, got: #{inspect(value)}. " <>
            "Wrap a constant in constant/1. A value computed from the drawn command is " <>
            "StepSpec.assign_from_command/3, and a field computed from other fields is from/2."
  end
end
