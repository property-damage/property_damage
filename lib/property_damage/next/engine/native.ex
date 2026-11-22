defmodule PropertyDamage.Next.Engine.Native do
  @moduledoc """
  PD's own engine.

  On a key with no entry it draws afresh from the key's seed: an integer
  uniformly over the range, a member uniformly by index, and any other
  generator as the root of its shrink tree, the value
  `PropertyDamage.Next.Steering.walk/3` reaches on the empty path from the
  key's seed, recorded as `{:stream_data, value, []}`.

  On a key whose entry still fits the generator it returns the stored value
  and entry unchanged. A StreamData entry `{:stream_data, value, path}`
  under a generator that is not a PD description is walked: the stored
  path is followed on the current generator from the key's seed, cut at
  its longest prefix that exists there, and the value reached is returned
  with the path that reached it. The stored value is not read, so a
  changed generator gives a value it can draw. An entry that no longer
  fits, or that is of another kind, is replaced by a fresh draw from the
  key's seed.

  A `from/2` function that returns a StreamData generator, plain or
  delegated, is refused: this engine cannot fit such a value when the field
  it depends on changes.
  """

  @behaviour PropertyDamage.Next.Engine

  alias PropertyDamage.Next.Engine.Dependent
  alias PropertyDamage.Next.{Gen, Journal, Steering}

  @impl true
  def draw(_journal, _key, %Dependent{command: module, field: field, generator: generator}, _seed) do
    raise ArgumentError,
          "#{inspect(module)}, field #{inspect(field)}: the from/2 function returned " <>
            "#{inspect(generator)}, a StreamData generator. PD's engine cannot fit its value " <>
            "when the field it depends on changes. Return one of PD's descriptions instead: " <>
            "integer/1, member_of/1 or boolean/0."
  end

  def draw(%Journal{entries: entries}, key, generator, seed) do
    key_seed = Journal.key_seed(seed, key)

    with {:ok, entry} <- Map.fetch(entries, key),
         {:ok, value, entry} <- kept(entry, generator, key_seed) do
      {value, entry}
    else
      :error -> fresh(generator, key_seed)
    end
  end

  defp kept({:integer, value, _range} = entry, %Gen{kind: :integer, domain: range}, _seed)
       when is_integer(value),
       do: if(value in range, do: {:ok, value, entry}, else: :error)

  defp kept({:member, value, _index} = entry, %Gen{kind: :member, domain: list}, _seed),
    do: if(Enum.member?(list, value), do: {:ok, value, entry}, else: :error)

  defp kept({:stream_data, _value, _path}, %Gen{kind: kind}, _seed) when kind != :delegated,
    do: :error

  defp kept({:stream_data, _value, path}, generator, seed) when is_list(path) do
    {value, reached} = generator |> Gen.to_stream_data() |> Steering.walk(seed, path)
    {:ok, value, {:stream_data, value, reached}}
  end

  defp kept(_entry, _generator, _seed), do: :error

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
    {value, []} = generator |> Gen.to_stream_data() |> Steering.walk(seed, [])
    {value, {:stream_data, value, []}}
  end

  defp uniform(count, seed) do
    {n, _state} = :rand.uniform_s(count, :rand.seed_s(:exsss, seed))
    n
  end
end
