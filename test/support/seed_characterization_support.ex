defmodule PropertyDamage.Test.SeedCharacterization do
  @moduledoc """
  Runs a fixed seed set over two seeded-defect models and renders each run as
  plain data, so a golden file can pin what a linear run does.

  The golden files must outlive changes to the engine's own structs, so the
  rendering never holds a struct: commands are `{module, args}`, events are
  `{source, module, fields}`, placeholders are labels, and nothing names a
  sequence section. Durations, timestamps, pids and references are dropped.

  Two cases:

    * `:ledger` runs `PropertyDamage.Test.Gauntlet` (an account id the SUT
      mints through `external()`, deposits and withdrawals) against an adapter
      that debits twice on a large withdrawal. A small `max_runs` lets some
      seeds pass and others fail.
    * `:store` runs `PropertyDamage.Test.ShrinkQuality` (a key/value store)
      against an adapter whose delete is a no-op. Failures are found in long
      sequences and shrink to a short reproduction.

  Each rendered run holds:

    * `plans`: the generated command sequence of every run the campaign made;
    * `outcome`: `:pass` or `:fail`;
    * `events`: for a failure, the event log of the reported run; for a pass,
      the events the adapter answered, in order;
    * `failure`: for a failure, its kind, root command index, check name and
      message, else `nil`;
    * `original`: for a failure, the generated command sequence that failed,
      else `nil`;
    * `shrunk`: for a failure, the shrunk command sequence, else `nil`.

  A golden file holds one Elixir term per case, written by
  `test/fixtures/seed_characterization/generate.exs` and read back by
  `read_golden!/1` after a scan that admits only literals.
  """

  alias PropertyDamage.{FailureReport, Generator, Placeholder, Sequence}
  alias PropertyDamage.Test.Gauntlet
  alias PropertyDamage.Test.ShrinkQuality

  @fixture_dir Path.expand("../fixtures/seed_characterization", __DIR__)

  @doc "The directory holding the golden files and the generator script."
  def fixture_dir, do: @fixture_dir

  @doc "The case names, in a fixed order."
  def case_names, do: [:ledger, :store]

  @doc "The seeds a case runs."
  def seeds(:ledger), do: Enum.to_list(1..20) ++ [24, 33, 39, 40]
  def seeds(:store), do: Enum.to_list(1..24)

  @doc "The golden file of a case."
  def golden_path(name), do: Path.join(@fixture_dir, "#{name}.exs")

  @doc "Where a case's run options are fixed: the model, the adapter config, the budget."
  def setup_for(:ledger) do
    %{
      model: Gauntlet.Model,
      adapter: __MODULE__.LedgerAdapter,
      config: %{bug: {:double_debit_from, 12}},
      max_runs: 2,
      max_commands: 10
    }
  end

  def setup_for(:store) do
    %{
      model: ShrinkQuality.Model,
      adapter: __MODULE__.StoreAdapter,
      config: %{},
      max_runs: 2,
      max_commands: 16
    }
  end

  @doc "Runs one seed of a case and renders the run."
  @spec render_run(atom(), integer()) :: map()
  def render_run(name, seed) do
    %{model: model, adapter: adapter, config: config, max_runs: max_runs, max_commands: max} =
      setup_for(name)

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

    answered = Agent.get(tape, &Enum.reverse/1)
    Agent.stop(tape)

    render_result(result, model, seed, max, answered)
  end

  defp render_result({:ok, stats}, model, seed, max, answered) do
    %{
      outcome: :pass,
      plans: plans(model, seed, stats.runs, max),
      events: Enum.map(answered, &render_event(:command, &1)),
      failure: nil,
      original: nil,
      shrunk: nil
    }
  end

  defp render_result({:error, %FailureReport{} = report}, model, seed, max, _answered) do
    %{
      outcome: :fail,
      plans: plans(model, seed, report.run_number + 1, max),
      events:
        report
        |> FailureReport.event_log()
        |> Enum.map(&render_event(&1.source, &1.event)),
      failure: %{
        kind: FailureReport.kind(report),
        root_index: report.failed_at_index,
        check: report |> FailureReport.check_name() |> norm(),
        message: FailureReport.failure_message(report)
      },
      original: commands(report.original_sequence),
      shrunk: commands(FailureReport.shrunk_sequence(report))
    }
  end

  # The sequence each run of the campaign generated: a pure function of the
  # seed, the run number (counted from 0) and the model.
  defp plans(model, seed, runs, max_commands) do
    generator = Generator.generate_sequence(model, max_commands: max_commands)

    for run <- 0..(runs - 1)//1 do
      generator
      |> Generator.generate_value(Generator.run_seed(seed, run))
      |> commands()
    end
  end

  defp commands(%Sequence{} = sequence) do
    sequence
    |> Sequence.to_list()
    |> Enum.map(fn command -> {module_name(command), fields(command)} end)
  end

  defp render_event(source, %{__struct__: module} = event),
    do: {source, inspect(module), fields(event)}

  defp fields(struct), do: struct |> Map.from_struct() |> norm()

  defp module_name(%{__struct__: module}), do: inspect(module)

  @doc false
  # Struct-free, run-independent rendering of a term.
  def norm(%Placeholder{} = ph) do
    "placeholder(#{inspect(ph.event_module)}, #{inspect(ph.path)}, event #{ph.event_index})"
  end

  def norm(%{__struct__: module} = struct),
    do: {inspect(module), struct |> Map.from_struct() |> norm()}

  def norm(map) when is_map(map), do: Map.new(map, fn {k, v} -> {norm(k), norm(v)} end)
  def norm(list) when is_list(list), do: Enum.map(list, &norm/1)
  def norm(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> norm() |> List.to_tuple()

  def norm(other)
      when is_pid(other) or is_reference(other) or is_function(other) or is_port(other),
      do: "volatile"

  def norm(other), do: other

  @doc "The text of a case's golden file, one entry per seed."
  def encode(rendered_by_seed) do
    body =
      rendered_by_seed
      |> Enum.sort_by(&elem(&1, 0))
      |> inspect(
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity,
        width: 98,
        custom_options: [sort_maps: true]
      )

    formatted = body |> Code.format_string!() |> IO.iodata_to_binary()

    "# Golden render of a seeded run set; written by generate.exs, do not edit.\n" <>
      formatted <> "\n"
  end

  @doc """
  Reads a golden file back as a term. The source is scanned first: anything
  but literals (maps, lists, tuples, atoms, strings, numbers) is refused.
  """
  def read_golden!(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()
    :ok = literal!(ast)
    {term, _binding} = Code.eval_quoted(ast)
    term
  end

  defp literal!({:%{}, _, pairs}), do: pairs |> Enum.flat_map(&Tuple.to_list/1) |> all_literal!()
  defp literal!({:{}, _, elems}), do: all_literal!(elems)
  defp literal!({a, b}), do: all_literal!([a, b])
  defp literal!(list) when is_list(list), do: all_literal!(list)
  defp literal!(atom) when is_atom(atom), do: :ok
  defp literal!(bin) when is_binary(bin), do: :ok
  defp literal!(num) when is_number(num), do: :ok
  defp literal!({:-, _, [num]}) when is_number(num), do: :ok

  defp literal!(other),
    do: raise(ArgumentError, "golden file holds a non-literal: #{inspect(other)}")

  defp all_literal!(items) do
    Enum.each(items, &literal!/1)
    :ok
  end

  defmodule LedgerAdapter do
    @moduledoc false
    # The ledger SUT of `PropertyDamage.Test.Gauntlet`, answering through a tape
    # that records every answer in order.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Gauntlet

    @impl true
    defdelegate setup(config), to: Gauntlet.Adapter

    @impl true
    defdelegate teardown(ctx), to: Gauntlet.Adapter

    @impl true
    def execute(command, ctx, runtime) do
      with {:ok, events} = answer <- Gauntlet.Adapter.execute(command, ctx, runtime) do
        Enum.each(events, fn event -> Agent.update(ctx.tape, &[event | &1]) end)
        answer
      end
    end
  end

  defmodule StoreAdapter do
    @moduledoc false
    # The store of `PropertyDamage.Test.ShrinkQuality` whose delete answers
    # success and changes nothing.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.ShrinkQuality.Commands.DelKey
    alias PropertyDamage.Test.ShrinkQuality.CorrectAdapter
    alias PropertyDamage.Test.ShrinkQuality.Events.EntryDeleted

    @impl true
    def setup(config) do
      with {:ok, ctx} <- CorrectAdapter.setup(config), do: {:ok, Map.put(ctx, :tape, config.tape)}
    end

    @impl true
    def teardown(ctx), do: CorrectAdapter.teardown(ctx)

    @impl true
    def execute(%DelKey{key: key}, ctx, _runtime),
      do: record({:ok, [%EntryDeleted{key: key}]}, ctx)

    def execute(command, ctx, runtime),
      do: record(CorrectAdapter.execute(command, ctx, runtime), ctx)

    defp record({:ok, events} = answer, ctx) do
      Enum.each(events, fn event -> Agent.update(ctx.tape, &[event | &1]) end)
      answer
    end
  end
end
