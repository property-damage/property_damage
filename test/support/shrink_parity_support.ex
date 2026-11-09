defmodule PropertyDamage.Test.ShrinkParity do
  @moduledoc false
  # What the shrinker did for each seed of the seed-characterization cases: how
  # many candidates it tried and why it stopped. The golden files of
  # `PropertyDamage.Test.SeedCharacterization` pin the shrunk sequence; this
  # pins the work done to reach it, so a change to the order or the number of
  # candidates shows up even when the result is the same.
  #
  # The fixture is written by `test/fixtures/shrink_parity/generate.exs`.

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.SeedCharacterization, as: S

  @fixture Path.expand("../fixtures/shrink_parity/iterations.exs", __DIR__)

  @doc "The fixture file."
  def fixture_path, do: @fixture

  @doc """
  Runs one seed of a case through `PropertyDamage.run/1`, as the seed
  characterization does, and returns `{iterations, stop}` for a failing run or
  `nil` for a passing one.
  """
  @spec observe(atom(), integer()) :: {non_neg_integer(), atom()} | nil
  def observe(name, seed) do
    %{model: model, adapter: adapter, config: config, max_runs: max_runs, max_commands: max} =
      S.setup_for(name)

    {:ok, tape} = Agent.start_link(fn -> [] end)

    result =
      PropertyDamage.run(
        model: model,
        targets: [{adapter, config: Map.put(config, :tape, tape)}],
        seed: seed,
        run_nonce: 1,
        max_runs: max_runs,
        max_commands: max,
        verbose: false,
        replay_dir: false
      )

    Agent.stop(tape)

    case result do
      {:ok, _stats} -> nil
      {:error, %FailureReport{} = report} -> {report.shrink_iterations, report.shrink_stop}
    end
  end

  @doc "Observes every seed of every case, as `%{case => [{seed, observation}]}`."
  def observe_all do
    Map.new(S.case_names(), fn name ->
      {name, for(seed <- S.seeds(name), do: {seed, observe(name, seed)})}
    end)
  end

  @doc "The text of the fixture for `observed`."
  def encode(observed) do
    body =
      observed
      |> inspect(pretty: true, limit: :infinity, width: 98, custom_options: [sort_maps: true])
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    "# Shrink work per seed: {iterations, stop}; written by generate.exs, do not edit.\n" <>
      body <> "\n"
  end

  @doc "Reads the fixture back as `%{case => %{seed => observation}}`."
  def read! do
    @fixture
    |> S.read_golden!()
    |> Map.new(fn {name, seeds} -> {name, Map.new(seeds)} end)
  end
end
