defmodule CachexBench.ReplayTest do
  @moduledoc """
  Reproducing one variant against a real Cachex. The second target's
  `incr_bug:` adds one too much to an `Incr` below 3, which only the two-step
  rewrite of an `Incr` root sends (every root adds at least 3). The failing
  run shrinks to the one root that matters, the second target on the
  rewrite against a reference running the root itself, and writes a replay
  artifact; `only: [replay: path]` runs that artifact again without
  generating anything.

  `test/fixtures/Model_seed3.replay.exs` is the artifact the failing run of
  `@bug_seed` writes, committed: a fresh generation must write the same
  bytes, and replaying the committed file must fail the same way.
  """
  use ExUnit.Case, async: false

  alias CachexBench.Commands.Incr
  alias PropertyDamage.{Expansion, Failure, FailureReport, Sequence}
  alias PropertyDamage.FailureReport.Formatter

  @bug_seed 3
  @fixture Path.expand("fixtures/Model_seed3.replay.exs", __DIR__)

  defp targets(adapter \\ CachexBench.Adapter, extra \\ %{}) do
    [
      {adapter, name: "cachex", config: extra},
      {adapter, name: "second", config: Map.put(extra, :incr_bug, true)}
    ]
  end

  defp run(opts) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: CachexBench.Model,
          targets: targets(),
          max_commands: 30,
          compare: [converge_within: 50],
          max_runs: 1,
          seed: @bug_seed,
          verbose: false
        ],
        opts
      )
    )
  end

  defp tmp_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cachex_replay_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp identity(report),
    do: {report.kind, Failure.name(report.failure_reason), report.variant.index}

  defp ran(report, name),
    do: report.trace.expansion |> Map.fetch!(name) |> Enum.at(report.failed_at_index)

  test "the path bug shrinks to one root: the rewrite in the second target, the root in the reference" do
    assert {:error, unshrunk} = run(shrink: false, replay_dir: false)
    assert {:error, report} = run(replay_dir: false)

    assert identity(report) == identity(unshrunk)
    assert identity(report) == {:diverged, {CachexBench.Projection, :expected_contents}, 1}
    assert report.failed_at_index == 0
    assert [%Incr{amount: n}] = report |> FailureReport.shrunk_sequence() |> Sequence.to_list()
    assert n >= 3

    assert %{entry: "Incr[1]", commands: [%Incr{amount: low}, %Incr{}]} = ran(report, "second")
    assert low < 3
    assert %{entry: entry, leaves?: false} = ran(report, "cachex")
    assert entry in ["Incr[0]", :identity]
  end

  test "the report ends with the paste-ready replay call" do
    assert {:error, report} = run(replay_dir: tmp_dir!())

    last = report |> Formatter.format(:terminal, color: false) |> String.trim_trailing()
    last = last |> String.split("\n") |> List.last()

    assert last == FailureReport.replay_command(report)
    assert last =~ ~s(only: [replay: "#{report.replay_path}"])
  end

  test "the committed artifact is what a fresh failing run writes" do
    assert {:error, report} = run(replay_dir: tmp_dir!())

    assert Path.basename(report.replay_path) == Path.basename(@fixture)
    assert File.read!(report.replay_path) == File.read!(@fixture)
  end

  test "the committed artifact replays to the same failure at the same root" do
    assert {:error, report} = run(replay_dir: false)

    assert {:error, replayed} =
             PropertyDamage.run(
               model: CachexBench.Model,
               targets: targets(),
               compare: [converge_within: 50],
               verbose: false,
               only: [replay: @fixture]
             )

    assert identity(replayed) == identity(report)
    assert replayed.failed_at_index == report.failed_at_index
    assert replayed.replay_status == :reproduced
    assert replayed.replay_path == @fixture
  end

  defmodule Recording do
    @moduledoc false
    # The bench adapter, telling the test process every command it executes.
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      {:ok, ctx} = CachexBench.Adapter.setup(config)
      send(config.pid, {:setup, config.name})
      {:ok, Map.merge(ctx, %{pid: config.pid, name: config.name})}
    end

    @impl true
    def teardown(ctx), do: CachexBench.Adapter.teardown(ctx)

    @impl true
    def execute(command, ctx, runtime) do
      send(ctx.pid, {:executed, ctx.name, command})
      CachexBench.Adapter.execute(command, ctx, runtime)
    end
  end

  # The commands `name` executed in its last execution (each `setup/1`
  # starts one).
  defp executed(name) do
    name
    |> messages([])
    |> Enum.reduce([], fn
      {:setup, _}, acc -> [[] | acc]
      {:executed, _, command}, [current | rest] -> [[command | current] | rest]
    end)
    |> hd()
    |> Enum.reverse()
  end

  defp messages(name, acc) do
    receive do
      {:setup, ^name} = message -> messages(name, [message | acc])
      {:executed, ^name, _command} = message -> messages(name, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "Expansion.for regenerates the unshrunk sequence the failing target executed" do
    recording = [
      {Recording, name: "cachex", config: %{pid: self(), name: "cachex"}},
      {Recording, name: "second", config: %{pid: self(), name: "second", incr_bug: true}}
    ]

    assert {:error, report} = run(targets: recording, shrink: false, replay_dir: false)
    executed = executed("second")

    assert {:ok, result} =
             Expansion.for(CachexBench.Model, report.seed, 1, "second", max_commands: 30)

    # The run stopped at the failing root: it executed the commands of every
    # root up to it.
    ran = result.choices |> Enum.take(report.failed_at_index + 1) |> Enum.flat_map(& &1.commands)
    assert ran == executed
    assert Enum.take(result.sequence, length(executed)) == executed
    assert Enum.any?(result.choices, &(&1.entry == "Incr[1]"))
  end

  defmodule FunKeyModel do
    @moduledoc false
    # The bench model, but the rewrite of an `Incr` increments a key that
    # holds a function: a value no replay artifact can hold.
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: CachexBench.Model.commands()
    @impl true
    def command_sequence_projection, do: CachexBench.Projection
    @impl true
    def check_projections, do: [CachexBench.Projection]
    @impl true
    def simulator, do: CachexBench.Simulator
    @impl true
    def expansions, do: [{Incr, &__MODULE__.rewrite/2}]

    @doc false
    def rewrite(%Incr{amount: n} = incr, _state),
      do: [[incr], [{Incr, overrides: %{key: [&CachexBench.keys/0], amount: n}}]]
  end

  test "an artifact whose command holds a function is refused, naming where it sits" do
    dir = tmp_dir!()

    # Unshrunk, so the artifact would hold the run as it was found: shrinking
    # halves the roots below the bug's threshold and drops the rewrite.
    assert {:error, report} = run(model: FunKeyModel, shrink: false, replay_dir: dir)

    # The first command, in target then root order, whose key holds the
    # function.
    expected =
      Enum.find_value(report.targets, fn {_adapter, entry} ->
        name = entry[:name]

        report.trace.expansion
        |> Map.fetch!(name)
        |> Enum.with_index()
        |> Enum.find_value(fn {choice, root} ->
          Enum.find_value(Enum.with_index(choice.commands), fn
            {%Incr{key: [_fun]}, leaf} ->
              %{target: name, root: root, leaf: leaf, field: [:key, 0]}

            _other ->
              nil
          end)
        end)
      end)

    assert %{} = expected
    assert report.replay == {:refused, expected}
    assert report.replay_path == nil
    assert File.ls!(dir) == []

    last = report |> Formatter.format(:terminal, color: false) |> String.trim_trailing()
    last = last |> String.split("\n") |> List.last()
    assert last =~ "refused"

    assert last =~
             ~s(target "#{expected.target}", root #{expected.root}, command #{expected.leaf})

    assert last =~ "field key[0]"
  end
end
