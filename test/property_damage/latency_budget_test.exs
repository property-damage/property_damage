defmodule PropertyDamage.LatencyBudgetTest do
  # `latency:` measurement and budget: the per-target metrics a run reports,
  # the judgment of the budget once after the last run, and what the failure
  # report, its persistence and the verbose printer carry. Timing assertions
  # sleep at least 5 ms against adapters that are otherwise instant and use
  # ratios with a huge margin on either side.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PropertyDamage.{Failure, FailureReport, Generator, Persistence, Sequence}
  alias PropertyDamage.Test.Lockstep.{GuardedStepModel, ProbeAdapter, ProbeModel, ProbeStep}
  alias PropertyDamage.Test.Lockstep.{Step, StepAdapter, StepModel}
  alias PropertyDamage.Test.SetupCommands
  alias PropertyDamage.Test.SetupCommands.{Cleanup, CreateUser, Other, Tick}
  alias PropertyDamage.Test.VariantSupport

  @seed 4_321
  @metric_keys [:by_command, :commands, :max, :mean, :min, :p50, :p95, :p99]
  @tiny 1.0e-9
  @huge 1.0e9

  defmodule MixedModel do
    @moduledoc false
    # Two root command modules, so `by_command` has two entries.
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [PropertyDamage.Test.Lockstep.Step, PropertyDamage.Test.Lockstep.ProbeStep]

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.Lockstep.Ledger

    @impl true
    def check_projections, do: [PropertyDamage.Test.Lockstep.Answers]
  end

  defmodule TimedAdapter do
    @moduledoc false
    # Answers every command at once after sleeping. Config keys (all
    # optional): `:name`, `:test_pid` (gets `{:executed, name}` per call and
    # `{:setup, name}` per setup), `:sleep_ms` (every command),
    # `:first_run_sleep_ms` (every command of the first run of this target
    # only; needs `:counter`, an Agent that counts the target's setups).
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep.{Probed, ProbeStep, Step, Stepped}

    @impl true
    def setup(config) do
      name = Map.get(config, :name, "timed")
      notify(config, {:setup, name})

      run =
        case config[:counter] do
          nil ->
            0

          agent ->
            Agent.get_and_update(agent, fn n ->
              {Map.get(n, name, 0), Map.update(n, name, 1, &(&1 + 1))}
            end)
        end

      {:ok, Map.merge(config, %{name: name, run: run})}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Step{value: value}, ctx, _runtime) do
      pause(ctx)
      {:ok, [%Stepped{value: value}]}
    end

    def execute(%ProbeStep{value: value}, ctx, _runtime) do
      pause(ctx)
      {:ok, [%Probed{value: value}]}
    end

    defp pause(ctx) do
      notify(ctx, {:executed, ctx.name})

      cond do
        ctx.run == 0 and ctx[:first_run_sleep_ms] -> Process.sleep(ctx.first_run_sleep_ms)
        ctx[:sleep_ms] -> Process.sleep(ctx.sleep_ms)
        true -> :ok
      end
    end

    defp notify(%{test_pid: pid}, message) when is_pid(pid), do: send(pid, message)
    defp notify(_config, _message), do: :ok
  end

  defp timed(name, config \\ %{}),
    do: {TimedAdapter, name: name, config: Map.merge(%{name: name, test_pid: self()}, config)}

  defp run(targets, extra) do
    [
      model: StepModel,
      targets: targets,
      max_runs: 3,
      max_commands: 3,
      seed: @seed,
      validate: false,
      compare: [converge_within: 30]
    ]
    |> Keyword.merge(extra)
    |> PropertyDamage.run()
  end

  # A reference that takes about 1 ms per command and a variant of about 5 ms.
  defp slow_pair, do: [timed("ref", %{sleep_ms: 1}), timed("slow", %{sleep_ms: 5})]

  defp breach!(targets, latency, extra \\ []) do
    assert {:error, %FailureReport{kind: :latency_exceeded} = report} =
             run(targets, [latency: latency] ++ extra)

    report
  end

  defp executed(name) do
    Stream.repeatedly(fn ->
      receive do
        {:executed, ^name} -> :hit
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 == :hit))
    |> length()
  end

  describe "measurement" do
    test "warmup leaves the first runs out of the metrics" do
      {:ok, counter} = Agent.start_link(fn -> %{} end)

      targets = fn ->
        for name <- ["a", "b"],
            do: timed(name, %{counter: counter, first_run_sleep_ms: 60})
      end

      {:ok, warmed} = run(targets.(), latency: [warmup: 1])
      Agent.update(counter, fn _ -> %{} end)
      {:ok, cold} = run(targets.(), latency: true)

      for name <- ["a", "b"] do
        assert warmed.metrics[name].max < 40_000
        assert cold.metrics[name].max >= 60_000
        assert warmed.metrics[name].commands < cold.metrics[name].commands
        assert warmed.metrics[name] |> Map.keys() |> Enum.sort() == @metric_keys
      end
    end

    test "by_command holds one p95 and count per root command module" do
      assert {:ok, stats} =
               run([timed("a"), timed("b")],
                 model: MixedModel,
                 latency: true,
                 max_runs: 6
               )

      generated =
        for run_number <- 0..5,
            command <-
              MixedModel
              |> Generator.generate_sequence(max_commands: 3)
              |> Generator.generate_value(Generator.run_seed(@seed, run_number))
              |> Sequence.to_list(),
            do: command.__struct__

      expected = Enum.frequencies(generated)

      for name <- ["a", "b"] do
        %{by_command: by_command, commands: commands} = stats.metrics[name]
        assert by_command |> Map.keys() |> Enum.sort() == [ProbeStep, Step]
        assert Map.new(by_command, fn {module, entry} -> {module, entry.commands} end) == expected
        assert Enum.sum(for {_module, entry} <- by_command, do: entry.commands) == commands

        for {_module, entry} <- by_command do
          assert entry |> Map.keys() |> Enum.sort() == [:commands, :p95]
          assert entry.p95 > 0
        end
      end
    end

    test "a one-target run reports its one variant" do
      assert {:ok, stats} = run([timed("solo", %{sleep_ms: 5})], latency: true)
      assert Map.keys(stats.metrics) == ["solo"]
      assert stats.metrics["solo"].min >= 5_000
    end

    test "a probe command's settle retries are one timed command" do
      counts = fn retries ->
        targets =
          for name <- ["a", "b"], do: {ProbeAdapter, name: name, config: %{retries: retries}}

        {:ok, stats} = run(targets, model: ProbeModel, latency: true)
        for name <- ["a", "b"], do: stats.metrics[name].commands
      end

      assert counts.(0) == counts.(3)
    end

    test "metrics carry no error counters" do
      assert {:ok, stats} = run([timed("a"), timed("b")], latency: true)

      for {_name, metrics} <- stats.metrics do
        refute Map.has_key?(metrics, :error_count)
        refute Map.has_key?(metrics, :error_rate)
      end
    end
  end

  describe "budget" do
    test "max_ratio on a slower variant fails with a latency report that is never shrunk" do
      report = breach!(slow_pair(), p95: [max_ratio: @tiny])

      assert %FailureReport{
               kind: :latency_exceeded,
               variant: %{index: 1, name: "slow"},
               failed_at_index: nil,
               shrink_iterations: 0,
               shrink_time_ms: 0
             } = report

      assert Failure.name(report.failure_reason) == :p95
      assert Failure.kind(report.failure_reason) == :latency_exceeded
      assert Failure.class(report.failure_reason) == :latency

      detail = Failure.detail(report.failure_reason)
      assert detail.statistic == :p95
      assert detail.bound == :max_ratio
      assert detail.limit == @tiny
      assert detail.value > 1.0
      assert_in_delta detail.value, report.metrics["slow"].p95 / report.metrics["ref"].p95, 1.0e-6
      assert detail.reference_value == report.metrics["ref"].p95
      assert detail.metrics == report.metrics["slow"]
      assert report.other_failures == []
      assert report.metrics |> Map.keys() |> Enum.sort() == ["ref", "slow"]
    end

    test "a generous max_ratio passes" do
      assert {:ok, stats} = run(slow_pair(), latency: [p95: [max_ratio: @huge]])
      assert stats.metrics["slow"].p95 > stats.metrics["ref"].p95
    end

    test "max compares with the duration converted to microseconds" do
      report = breach!([timed("solo", %{sleep_ms: 5})], p99: [max: {1, :milliseconds}])

      detail = Failure.detail(report.failure_reason)
      assert Failure.name(report.failure_reason) == :p99
      assert detail.bound == :max
      assert detail.limit == 1_000
      assert detail.value >= 5_000
      assert detail.reference_value == nil
      assert report.variant == %{index: 0, name: "solo"}
    end

    test "a generous max passes" do
      assert {:ok, _stats} =
               run([timed("a"), timed("b")], latency: [p99: [max: {1, :minutes}]])
    end

    test "the reference is judged on max and never on max_ratio" do
      ratio_only =
        breach!([timed("ref", %{sleep_ms: 1}), timed("same", %{sleep_ms: 1})],
          p50: [max_ratio: @tiny]
        )

      assert ratio_only.variant.index == 1
      assert ratio_only.other_failures == []

      absolute =
        breach!([timed("ref", %{sleep_ms: 5}), timed("same", %{sleep_ms: 5})],
          p50: [max: {1, :milliseconds}]
        )

      assert absolute.variant.index == 0
      assert [%{variant: %{index: 1}}] = absolute.other_failures
    end

    test "several breaches report the first in statistic order and list the rest" do
      report = breach!(slow_pair(), p95: [max_ratio: @tiny], p50: [max_ratio: @tiny])

      assert Failure.name(report.failure_reason) == :p50

      assert [%{variant: %{index: 1}, failure: other}] = report.other_failures
      assert Failure.name(other) == :p95
    end

    test "max is listed before max_ratio for one statistic" do
      targets = [timed("ref", %{sleep_ms: 1}), timed("slow", %{sleep_ms: 20})]
      report = breach!(targets, p50: [max_ratio: @tiny, max: {10, :milliseconds}])

      assert report.variant.index == 1
      assert Failure.detail(report.failure_reason).bound == :max
      assert [%{failure: other}] = report.other_failures
      assert Failure.detail(other).bound == :max_ratio
    end

    test "the judgment re-executes nothing and calls on_failure once with the report" do
      passing = fn ->
        {:ok, _stats} = run(slow_pair(), latency: [p95: [max_ratio: @huge]])
        executed("slow")
      end

      baseline = passing.()
      assert baseline > 0
      flush_executed()

      test_pid = self()
      on_failure = fn report -> send(test_pid, {:on_failure, report}) end

      report =
        breach!(slow_pair(), [p95: [max_ratio: @tiny]], on_failure: on_failure, shrink: true)

      assert executed("slow") == baseline
      assert_received {:on_failure, ^report}
      refute_received {:on_failure, _}
    end

    test "a check failure in the first run is reported as that kind with the metrics so far" do
      targets = [{StepAdapter, name: "a", config: %{name: "a", bad_at: 0}}, step("b")]

      assert {:error, %FailureReport{kind: :check_failed} = report} =
               run(targets,
                 model: GuardedStepModel,
                 latency: [p95: [max_ratio: @tiny]],
                 shrink: false
               )

      assert report.metrics |> Map.keys() |> Enum.sort() == ["a", "b"]
      assert report.metrics["a"].commands >= 1

      assert {:error, %FailureReport{kind: :check_failed, metrics: nil}} =
               run(targets, model: GuardedStepModel, shrink: false)
    end
  end

  describe "report" do
    @describetag :tmp_dir

    test "a latency report persists at format version 13 and a version-11 file is refused",
         %{tmp_dir: dir} do
      report = breach!(slow_pair(), p95: [max_ratio: @tiny])

      assert {:ok, path} = Persistence.save(report, dir)
      assert {:ok, <<"PD", 13::8, _rest::binary>> = binary} = File.read(path)
      assert {:ok, loaded} = Persistence.load(path)

      assert loaded.kind == :latency_exceeded
      assert loaded.metrics == report.metrics
      assert loaded.latency == report.latency
      assert loaded.failure_reason == report.failure_reason

      <<"PD", _version::8, rest::binary>> = binary
      old = Path.join(dir, "old.pd")
      File.write!(old, <<"PD", 11::8, rest::binary>>)
      assert {:error, {:unsupported_format_version, 11, 13}} = Persistence.load(old)
    end
  end

  describe "failure vocabulary" do
    test "a signature rebuilds a latency failure with its statistic" do
      failure = Failure.from_signature(:latency_exceeded, :p99)

      assert Failure.kind(failure) == :latency_exceeded
      assert Failure.name(failure) == :p99
      assert Failure.class(failure) == :latency
    end

    test "a latency report renders in every format with the verdict and no command" do
      report = breach!(slow_pair(), p95: [max_ratio: @tiny])

      for format <- [:terminal, :markdown, :json] do
        text = FailureReport.Formatter.format(report, format)
        assert text =~ "Latency Exceeded"
        assert text =~ "p95 max_ratio:"
      end

      assert PropertyDamage.Error.format(report.failure_reason, %{}) =~ "p95 max_ratio:"
    end
  end

  describe "reproduction and printing" do
    test "reproduction_command prints latency: exactly as given" do
      report = breach!(slow_pair(), p95: [max_ratio: @tiny])
      assert FailureReport.reproduction_command(report) =~ "latency: [p95: [max_ratio: 1.0e-9]]"

      failing = [{StepAdapter, name: "a", config: %{name: "a", bad_at: 0}}, step("b")]

      assert {:error, report} =
               run(failing, model: GuardedStepModel, latency: true, shrink: false)

      assert FailureReport.reproduction_command(report) =~ "latency: true"

      assert {:error, report} = run(failing, model: GuardedStepModel, shrink: false)
      refute FailureReport.reproduction_command(report) =~ "latency"
    end

    test "verbose output has the side-by-side table and, on a breach, the verdict line" do
      passing =
        capture_io(fn ->
          assert {:ok, _} = run([timed("a"), timed("b")], latency: true, verbose: true)
        end)

      for text <- ["p50", "p95", "p99", "mean", "min", "max", "commands", "(us)"] do
        assert passing =~ text
      end

      assert passing =~ ~r/^\s*p50\s+[\d.]+\s+[\d.]+\s*$/m
      assert passing =~ ~r/variant \(us\)\s+a\s+b/

      failing =
        capture_io(fn ->
          assert {:error, _} =
                   run(slow_pair(), latency: [p95: [max_ratio: @tiny]], verbose: true)
        end)

      assert failing =~ ~r/^\s*p95\s+[\d.]+\s+[\d.]+\s*$/m
      assert failing =~ ~r/variant slow exceeded p95 max_ratio: [\d.]+ against 1\.0e-9/

      absolute =
        capture_io(fn ->
          assert {:error, _} =
                   run([timed("solo", %{sleep_ms: 5})],
                     latency: [p99: [max: {1, :milliseconds}]],
                     verbose: true
                   )
        end)

      assert absolute =~ ~r/variant solo exceeded p99 max: [\d.]+ us against 1000 us/
    end
  end

  defp step(name), do: {StepAdapter, name: name, config: %{name: name}}

  defp flush_executed do
    receive do
      {:executed, _} -> flush_executed()
    after
      0 -> :ok
    end
  end

  describe "setup and teardown commands" do
    # One setup command, one teardown command and two roots per run, on two
    # targets: the setup and teardown commands are never latency samples.
    test "are not timed: commands counts the roots and by_command names root modules only" do
      model =
        SetupCommands.define_model!(Module.concat(__MODULE__, SetupTeardownModel),
          commands: [Other, Tick],
          setup: [{CreateUser, overrides: %{name: "fixture"}}],
          teardown: [{Cleanup, overrides: %{thing_id: "x"}}]
        )

      recorder = VariantSupport.start_recorder()

      assert {:ok, stats} =
               PropertyDamage.run(
                 model: model,
                 targets: [
                   SetupCommands.target("a", recorder),
                   SetupCommands.target("b", recorder)
                 ],
                 compare: [converge_within: 30],
                 latency: true,
                 max_runs: 2,
                 max_commands: 2,
                 seed: @seed,
                 shrink: false
               )

      assert stats.total_commands == 4
      assert stats.setup_commands == 2
      assert stats.teardown_commands == 2

      for name <- ["a", "b"] do
        metrics = stats.metrics[name]
        assert metrics.commands == stats.total_commands

        assert metrics.by_command |> Map.keys() |> Enum.all?(&(&1 in [Other, Tick]))
        refute Map.has_key?(metrics.by_command, CreateUser)
        refute Map.has_key?(metrics.by_command, Cleanup)

        assert metrics.by_command |> Map.values() |> Enum.map(& &1.commands) |> Enum.sum() ==
                 stats.total_commands
      end
    end
  end
end
