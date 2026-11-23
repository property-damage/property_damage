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

  `to_binary/1` and `from_binary/2` save and load a journal. The binary
  carries a format version, and loading refuses any other version. It
  holds the four fields above, the lanes of a plan with two lanes, and
  nothing about where it was recorded: no PD version, no model version, no
  module digest. A replay on a model whose
  spec list changed is refused through the fingerprint; a changed generator
  is not detected, and the engine fits or redraws the values stored for it.

  Format version 3 records a StreamData value with its path in the
  generator's shrink tree, `{:stream_data, value, path}`, may hold an
  empty pick `{:empty}` for a slot that yields no step, and may hold an
  entry of `PropertyDamage.Next.Engine.StreamDataSource`,
  `{:source, value, positions}`. Versions 1 and 2 are refused. A member entry may
  hold a mint marker that the model read back from its predicted state,
  with the stamp generation gave it.

  `lanes` is `nil` for a plan whose steps run one after another, and
  `%{count: 2, steps: lane_steps, yields: yields}` for a plan with two
  lanes (see `PropertyDamage.Next.plan/3`). Format version 3 may carry this
  field: a binary without it is a one-lane journal, so every binary saved
  before the field existed loads as one. A two-lane journal also holds the
  schedule entries, one integer under `{{1, slot}, :schedule, point}` for
  each point of each lane-1 step.

  A journal can be loaded in a VM other than the one that saved it, such as
  a later `mix test` or `mix run`. The binary names atoms: PD's own module
  and field names, and the model's command modules, event modules and field
  names. Loading never creates an atom, so a binary from elsewhere cannot
  fill the atom table, and every atom the journal names must already exist.
  `from_binary/2` loads PD's own modules first, and with the `:model`
  option it also loads the model and the modules it names, which creates
  the model's atoms. Pass `:model` whenever the journal comes from another
  VM.
  """

  alias PropertyDamage.Mint
  alias PropertyDamage.Next.Engine.Dependent
  alias PropertyDamage.Next.{Gen, Journal.Atoms, Model, Placeholder, StepSpec}

  @enforce_keys [:seed]
  defstruct seed: nil, max_steps: nil, entries: %{}, fingerprint: nil, lanes: nil

  @typedoc "The lanes a journal recorded: `nil` for one lane."
  @type lanes ::
          %{count: 2, steps: non_neg_integer(), yields: non_neg_integer()} | nil

  @type t :: %__MODULE__{
          seed: integer(),
          max_steps: non_neg_integer() | nil,
          entries: %{term() => tuple()},
          fingerprint: binary() | nil,
          lanes: lanes()
        }

  @format :property_damage_next_journal
  @version 3
  @own_modules [Gen, Dependent, Placeholder, Mint, Range]
  @entry_atoms [
    :pick,
    :command,
    :assigns,
    :integer,
    :member,
    :stream_data,
    :empty,
    :source,
    :schedule,
    :lanes,
    :count,
    :steps,
    :yields
  ]

  @doc "Saves `journal` as a binary that `from_binary/1` loads."
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{} = journal) do
    content = Map.take(journal, [:seed, :max_steps, :entries, :fingerprint])

    # A one-lane journal leaves the field out, so it saves the four fields
    # it saved before lanes existed.
    content = if journal.lanes, do: Map.put(content, :lanes, journal.lanes), else: content
    :erlang.term_to_binary({@format, @version, content})
  end

  @doc """
  Loads a journal saved by `to_binary/1`.

  Loading creates no atom, so every atom the journal names must exist in
  this VM. PD's own modules are loaded first, so a journal that names only
  PD's atoms and atoms this VM already knows always loads. Options:

    * `:model` - the model the journal was recorded on. Before decoding,
      the model module, each spec's command module, the simulator, the
      command-sequence projection and the check projections are loaded,
      which creates the atoms they name (event modules, field names). Pass
      it whenever the journal was saved in another VM.

  Raises `ArgumentError` for a binary that names an atom this VM does not
  know (the message names the atom and says to pass `:model`), for a
  binary that is not a saved journal, and for one saved in another format
  version.
  """
  @spec from_binary(binary(), keyword()) :: t()
  def from_binary(binary, opts \\ []) when is_binary(binary) and is_list(opts) do
    model = opts |> Keyword.validate!([:model]) |> Keyword.get(:model)
    load_own_modules()
    if model, do: load_model!(model)
    binary |> decode(model) |> journal!()
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

  # Modules load on first use, so in a fresh VM even PD's own atoms may not
  # exist yet. Loading the modules whose terms entries hold creates the atoms
  # of those terms. The atoms of entry keys and tags are named here instead,
  # since the modules that write them call this one: this module's literals
  # are created when it loads, and returning them keeps them in its code.
  defp load_own_modules do
    Enum.each(@own_modules, &Code.ensure_loaded/1)
    @entry_atoms
  end

  # Loading a module creates the atoms it names as literals, so loading the
  # model and every module it names creates the atoms of its journals.
  defp load_model!(model) when is_atom(model) and model not in [true, false] do
    Code.ensure_loaded!(model)

    commands = model |> Model.specs!() |> Enum.map(& &1.command)

    named =
      Enum.flat_map(
        [:simulator, :command_sequence_projection, :check_projections],
        &named(model, &1)
      )

    for module <- commands ++ named, is_atom(module), do: Code.ensure_loaded(module)
  end

  defp load_model!(other) do
    raise ArgumentError, "the :model option is a module, got: #{inspect(other)}"
  end

  defp named(model, callback) do
    if function_exported?(model, callback, 0),
      do: List.wrap(apply(model, callback, [])),
      else: []
  end

  # A saved journal names only atoms that exist once its model is loaded, so
  # decoding refuses to create any: a binary from elsewhere cannot fill the
  # atom table.
  defp decode(binary, model) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> undecodable!(binary, model)
  end

  # `:safe` refuses an unknown atom and a binary that is not a term alike.
  # A binary that scans as a whole journal term naming unknown atoms is the
  # first case; anything else is not a journal.
  defp undecodable!(binary, model) do
    case Atoms.unknown(binary, @format) do
      {:ok, [_ | _] = names} -> unknown_atoms!(names, model)
      _ -> not_a_journal!()
    end
  end

  defp unknown_atoms!(names, model) do
    shown = names |> Enum.take(5) |> Enum.map_join(", ", &show_atom/1)
    more = if length(names) > 5, do: " and #{length(names) - 5} more", else: ""

    hint =
      if model,
        do:
          "even after loading #{inspect(model)} and the modules it names; " <>
            "the journal may have been recorded on another model",
        else: "pass the journal's model as `model:`, or load the model's modules, first"

    raise ArgumentError,
          "the journal refers to atoms not yet loaded in this VM: #{shown}#{more}; #{hint}"
  end

  defp show_atom("Elixir." <> module), do: module
  defp show_atom(name), do: ":" <> name

  defp journal!(
         {@format, @version,
          %{seed: seed, max_steps: max_steps, entries: entries, fingerprint: fingerprint} =
            content}
       )
       when is_integer(seed) and is_map(entries) and
              ((is_integer(max_steps) and max_steps >= 0) or is_nil(max_steps)) and
              (is_binary(fingerprint) or is_nil(fingerprint)) do
    %__MODULE__{
      seed: seed,
      max_steps: max_steps,
      entries: entries,
      fingerprint: fingerprint,
      lanes: content |> Map.get(:lanes) |> lanes!()
    }
  end

  defp journal!({@format, version, _content}) do
    raise ArgumentError,
          "the journal was saved in format version #{inspect(version)}; " <>
            "this version of PD loads version #{@version} only"
  end

  defp journal!(_other), do: not_a_journal!()

  defp lanes!(nil), do: nil

  defp lanes!(%{count: 2, steps: steps, yields: yields} = lanes)
       when map_size(lanes) == 3 and is_integer(steps) and steps >= 0 and is_integer(yields) and
              yields >= 0,
       do: lanes

  defp lanes!(_other), do: not_a_journal!()

  defp not_a_journal! do
    raise ArgumentError, "the binary is not a journal saved by PropertyDamage.Next.Journal"
  end
end
