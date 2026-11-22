defmodule PropertyDamage.Next.Engine.Native do
  @moduledoc """
  PD's own engine.

  On a key with no entry it draws afresh from the key's seed: an integer
  uniformly over the range, a member uniformly by index, and any other
  generator as one StreamData value at a fixed size. On a key whose entry
  still fits the generator it returns the stored value and entry unchanged.
  An entry that no longer fits, or that is of another kind, is replaced by a
  fresh draw from the key's seed.

  A `from/2` function that returns a StreamData generator, plain or
  delegated, is refused: this engine cannot fit such a value when the field
  it depends on changes.
  """

  @behaviour PropertyDamage.Next.Engine

  alias PropertyDamage.Next.Engine.Dependent
  alias PropertyDamage.Next.{Gen, Journal}

  # The size StreamData draws at, fixed so a draw depends on the seed alone.
  @size 30

  @impl true
  def draw(_journal, _key, %Dependent{command: module, field: field, generator: generator}, _seed) do
    raise ArgumentError,
          "#{inspect(module)}, field #{inspect(field)}: the from/2 function returned " <>
            "#{inspect(generator)}, a StreamData generator. PD's engine cannot fit its value " <>
            "when the field it depends on changes. Return one of PD's descriptions instead: " <>
            "integer/1, member_of/1 or boolean/0."
  end

  def draw(%Journal{entries: entries}, key, generator, seed) do
    with {:ok, entry} <- Map.fetch(entries, key),
         {:ok, value} <- kept(entry, generator) do
      {value, entry}
    else
      :error -> fresh(generator, Journal.key_seed(seed, key))
    end
  end

  defp kept({:integer, value, _range}, %Gen{kind: :integer, domain: range})
       when is_integer(value),
       do: if(value in range, do: {:ok, value}, else: :error)

  defp kept({:member, value, _index}, %Gen{kind: :member, domain: list}),
    do: if(Enum.member?(list, value), do: {:ok, value}, else: :error)

  defp kept({:stream_data, _value}, %Gen{kind: kind}) when kind != :delegated, do: :error
  defp kept({:stream_data, value}, _generator), do: {:ok, value}
  defp kept(_entry, _generator), do: :error

  defp fresh(%Gen{kind: :integer, domain: range}, seed) do
    value = range.first + uniform(Range.size(range), seed) - 1
    {value, {:integer, value, range}}
  end

  defp fresh(%Gen{kind: :member, domain: list}, seed) do
    index = uniform(length(list), seed) - 1
    value = Enum.at(list, index)
    {value, {:member, value, index}}
  end

  defp fresh(generator, seed) do
    value =
      generator
      |> Gen.to_stream_data()
      |> StreamData.seeded(seed)
      |> StreamData.resize(@size)
      |> Enum.at(0)

    {value, {:stream_data, value}}
  end

  defp uniform(count, seed) do
    {n, _state} = :rand.uniform_s(count, :rand.seed_s(:exsss, seed))
    n
  end
end
