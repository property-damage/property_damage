defmodule PropertyDamage.Corpus.Engine.NextSource do
  @moduledoc """
  The engine that runs entries through `PropertyDamage.Next.run/1` with
  `PropertyDamage.Next.Engine.StreamDataSource` drawing every value.

  It runs an entry exactly as `PropertyDamage.Corpus.Engine.Next` does, with
  `engine: PropertyDamage.Next.Engine.StreamDataSource` added to the entry's
  `run_opts`, and answers the same result. `mix pd.corpus --both-engines`
  runs every entry of `PropertyDamage.Corpus.Engine.Next` on this engine too.

  The source engine needs a patched StreamData, which only the test
  environment can load (see `check_stream_data/1`). Run its rows with:

      MIX_ENV=test mix pd.corpus --dir corpus/next --both-engines
  """

  @behaviour PropertyDamage.Corpus.Engine

  alias PropertyDamage.Corpus.{Engine, Entry}
  alias PropertyDamage.Next.Engine.StreamDataSource

  # The test-support module that patches StreamData. It is compiled only in
  # the test environment, so it is named as data and called at run time.
  @loader Module.concat([PropertyDamage, Test, PatchedStreamData])

  @default_args ["--dir", "corpus/next", "--both-engines"]

  @impl true
  def name, do: "property_damage_next_source"

  @impl true
  def run(%Entry{} = entry, seed, plan_cap) do
    run_opts = Keyword.put(entry.run_opts, :engine, StreamDataSource)
    Engine.Next.run(%{entry | run_opts: run_opts}, seed, plan_cap)
  end

  @doc "The module that loads the patched StreamData, the default of `check_stream_data/2`."
  @spec loader() :: module()
  def loader, do: @loader

  @doc """
  Makes sure the patched StreamData is active, loading it through `loader`
  when it is present and not active yet.

  Returns `:ok`, or `{:error, message}` naming how to run the source rows:
  the command of the refused run, built from `args`, the arguments it was
  given (`--dir corpus/next --both-engines` when none are passed).
  The source engine never falls back to the released StreamData: on it the
  engine would record no draw.
  """
  @spec check_stream_data(module(), [String.t()]) :: :ok | {:error, String.t()}
  def check_stream_data(loader \\ @loader, args \\ @default_args) do
    cond do
      not Code.ensure_loaded?(loader) ->
        refuse("it loads only in the test environment", args)

      loader.active?() ->
        :ok

      true ->
        load(loader, args)
    end
  end

  defp load(loader, args) do
    case loader.load() do
      {:error, reason} -> refuse("loading it failed: #{reason}", args)
      _loaded_or_skipped -> if loader.active?(), do: :ok, else: refuse("it is not active", args)
    end
  end

  defp refuse(why, args) do
    command = Enum.map_join(["MIX_ENV=test", "mix", "pd.corpus" | args], " ", &shell_word/1)

    {:error,
     "The #{name()} rows need the patched StreamData, and #{why}. Run them with " <>
       "`#{command}`, without PD_SKIP_STREAM_DATA_PATCH=1."}
  end

  defp shell_word(word) do
    if word =~ ~r/[\s'"\\$`]/, do: "'" <> String.replace(word, "'", "'\\''") <> "'", else: word
  end
end
