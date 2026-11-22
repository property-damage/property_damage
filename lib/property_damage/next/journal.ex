defmodule PropertyDamage.Next.Journal do
  @moduledoc """
  The test case: every draw of a plan, keyed by where generation made it.

  A journal holds the seed the plan was built from, the number of slots
  the plan had, one entry per key, and a fingerprint of the model's spec
  list. PD rebuilds the plan by running
  generation again against the entries: a key with an entry that still fits
  gives back its value, and a key with no entry draws afresh from the seed.

  The fingerprint covers each spec's command module, position and weight,
  and the keys of its command options, recorded changes and assigns. It
  does not cover functions, so an edit inside a `when:` function or a new
  option value goes unnoticed. A journal whose fingerprint does not match
  the model is refused with `PropertyDamage.Next.ModelChangedError`: PD
  never guesses which spec a stored pick meant.

  `to_binary/1` and `from_binary/1` save and load a journal. The binary
  carries a format version, and loading refuses any other version.
  """

  alias PropertyDamage.Next.StepSpec

  @enforce_keys [:seed]
  defstruct seed: nil, max_steps: nil, entries: %{}, fingerprint: nil

  @type t :: %__MODULE__{
          seed: integer(),
          max_steps: non_neg_integer() | nil,
          entries: %{term() => tuple()},
          fingerprint: binary() | nil
        }

  @format :property_damage_next_journal
  @version 1

  @doc "Saves `journal` as a binary that `from_binary/1` loads."
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{} = journal) do
    content = Map.take(journal, [:seed, :max_steps, :entries, :fingerprint])
    :erlang.term_to_binary({@format, @version, content})
  end

  @doc """
  Loads a journal saved by `to_binary/1`.

  Raises `ArgumentError` for a binary that is not a saved journal or that
  was saved in another format version.
  """
  @spec from_binary(binary()) :: t()
  def from_binary(binary) when is_binary(binary) do
    binary |> decode() |> journal!()
  end

  @doc """
  The seed of one key: a function of the journal's seed and the key alone,
  so an entry under one key never changes what another key draws.
  """
  @spec key_seed(integer(), term()) :: non_neg_integer()
  def key_seed(seed, key), do: :erlang.phash2({seed, key}, 4_294_967_296)

  @doc "The fingerprint of a spec list whose ids are set."
  @spec fingerprint([StepSpec.t()]) :: binary()
  def fingerprint(specs) when is_list(specs) do
    specs
    |> Enum.map(&describe/1)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp describe(%StepSpec{} = spec) do
    {spec.command, spec.id, spec.weight,
     spec.command_opts |> Keyword.keys() |> Enum.uniq() |> Enum.sort(),
     Enum.map(spec.changes, &change_key/1), spec.assigns |> Map.keys() |> Enum.sort()}
  end

  defp change_key({:put, field, _generator}), do: {:put, field}
  defp change_key({:update, _fun}), do: :update

  # A saved journal names only atoms that exist once its model is loaded, so
  # decoding refuses to create any: a binary from elsewhere cannot fill the
  # atom table.
  defp decode(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> not_a_journal!()
  end

  defp journal!(
         {@format, @version,
          %{seed: seed, max_steps: max_steps, entries: entries, fingerprint: fingerprint}}
       )
       when is_integer(seed) and is_map(entries) and
              ((is_integer(max_steps) and max_steps >= 0) or is_nil(max_steps)) and
              (is_binary(fingerprint) or is_nil(fingerprint)) do
    %__MODULE__{seed: seed, max_steps: max_steps, entries: entries, fingerprint: fingerprint}
  end

  defp journal!({@format, version, _content}) do
    raise ArgumentError,
          "the journal was saved in format version #{inspect(version)}; " <>
            "this version of PD loads version #{@version} only"
  end

  defp journal!(_other), do: not_a_journal!()

  defp not_a_journal! do
    raise ArgumentError, "the binary is not a journal saved by PropertyDamage.Next.Journal"
  end
end
