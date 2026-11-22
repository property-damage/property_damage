defmodule PropertyDamage.Next.Engine.Native do
  @moduledoc """
  PD's own engine.

  On a key with no entry it draws afresh from the key's seed: an integer
  uniformly over the range, a member uniformly by index, and any other
  generator as the root of its shrink tree, the value
  `PropertyDamage.Next.Steering.walk/3` reaches on the empty path from the
  key's seed, recorded as `{:stream_data, value, []}`.

  On a key whose entry is of the generator's kind it fits the stored value
  to the current domain, and the entry it returns records that domain:

    * an integer is kept if it lies in the current range, else clamped to
      the nearer bound; the entry records the current range;
    * a member is kept if the current list still holds it, else the member
      at the stored index is taken, else the last member if the list got
      shorter; the entry records the index in the current list.

  A StreamData entry `{:stream_data, value, path}`
  under a generator that is not a PD description is walked: the stored
  path is followed on the current generator from the key's seed, cut at
  its longest prefix that exists there, and the value reached is returned
  with the path that reached it. The stored value is not read, so a
  changed generator gives a value it can draw. An entry of another kind is
  replaced by a fresh draw from the key's seed.

  A generator that a `from/2` function or a dependent assign returned
  arrives wrapped in `PropertyDamage.Next.Engine.Dependent` when it is not
  a PD description. This engine draws the wrapped generator as any other
  StreamData generator, path included, so after its source changes the
  value follows the stored path on the new generator. It cannot fit that
  value to the new domain, so it does not export `fits_dependent?/1`, and
  generation warns about the site or raises (see
  `PropertyDamage.Next.Engine`).
  """

  @behaviour PropertyDamage.Next.Engine

  alias PropertyDamage.Next.Engine.Dependent
  alias PropertyDamage.Next.{Gen, Journal, Steering}

  @impl true
  def draw(journal, key, %Dependent{generator: generator}, seed),
    do: draw(journal, key, generator, seed)

  def draw(%Journal{entries: entries}, key, generator, seed) do
    key_seed = Journal.key_seed(seed, key)

    with {:ok, entry} <- Map.fetch(entries, key),
         {:ok, value, entry} <- kept(entry, generator, key_seed) do
      {value, entry}
    else
      :error -> fresh(generator, key_seed)
    end
  end

  defp kept({:integer, value, _range}, %Gen{kind: :integer, domain: range}, _seed)
       when is_integer(value) do
    fitted = value |> max(range.first) |> min(range.last)
    {:ok, fitted, {:integer, fitted, range}}
  end

  defp kept({:member, value, index}, %Gen{kind: :member, domain: list}, _seed)
       when is_integer(index) and index >= 0 do
    index =
      case Enum.find_index(list, &(&1 === value)) do
        nil -> min(index, length(list) - 1)
        current -> current
      end

    member = Enum.at(list, index)
    {:ok, member, {:member, member, index}}
  end

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
