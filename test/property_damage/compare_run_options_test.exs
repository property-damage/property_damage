defmodule PropertyDamage.CompareRunOptionsTest do
  # The run options of boundary comparison: `compare: [converge_within: ms]`,
  # the removed comparison options, the no-observation guard and the
  # `latency:` measurement and budget grammar. Every option error is raised before any
  # adapter setup.
  use ExUnit.Case, async: true

  alias PropertyDamage.Options
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.{PayModel, PlainModel}

  @ns inspect(__MODULE__)

  @header """
    use PropertyDamage.Model.Projection
    alias PropertyDamage.Test.Compare.{Paid, Read, Settled}

    @impl true
    def init, do: %{settled: 0, paid: 0}

    @impl true
    def apply(s, %Paid{}), do: %{s | paid: s.paid + 1}
    def apply(s, %Settled{amount: a}), do: %{s | settled: s.settled + a}
    def apply(s, _), do: s
  """

  @sources %{
    agree: """
    defmodule #{@ns}.Agree do
    #{@header}
      @compare every: 1
      def totals(s, _root), do: %{settled: s.settled}
    end
    """,
    never: """
    defmodule #{@ns}.Never do
    #{@header}
      @compare every: Read
      def reads(s, _root), do: s.paid
    end
    """
  }

  @metric_keys [:by_command, :commands, :max, :mean, :min, :p50, :p95, :p99]

  setup_all do
    compiled = Compare.compile_all(@sources)

    models =
      for name <- Map.keys(@sources), into: %{} do
        projection = Module.concat(__MODULE__, Macro.camelize(Atom.to_string(name)))
        module = Module.concat([__MODULE__, "Model", Macro.camelize(Atom.to_string(name))])
        {name, Compare.define_model!(module, [projection])}
      end

    {:ok, compiled: compiled, models: models}
  end

  defp model!(ctx, name) do
    Compare.fixture!(ctx.compiled, name)
    Map.fetch!(ctx.models, name)
  end

  defp two_targets, do: [Compare.target("a"), Compare.target("b")]

  # The error a two-target run raises with `extra`; no adapter was set up.
  defp option_error(ctx, extra) do
    error = Compare.raised(fn -> Compare.run(model!(ctx, :agree), two_targets(), extra) end)

    assert is_exception(error, NimbleOptions.ValidationError) or
             is_exception(error, ArgumentError)

    refute_received {:setup, _name}
    Exception.message(error)
  end

  describe "compare: [converge_within: ms]" do
    test "defaults to 5000 milliseconds, with or without compare:", ctx do
      base = [model: model!(ctx, :agree), targets: two_targets()]

      for opts <- [base, base ++ [compare: []]] do
        validated = Options.validate_run!(opts)
        assert validated |> Keyword.fetch!(:compare) |> Keyword.fetch!(:converge_within) == 5_000
      end

      validated = Options.validate_run!(base ++ [compare: [converge_within: 250]])
      assert validated |> Keyword.fetch!(:compare) |> Keyword.fetch!(:converge_within) == 250
    end

    for value <- [{5, :seconds}, 1.5, 0, -1] do
      test "converge_within: #{inspect(value)} is an option error naming milliseconds", ctx do
        message = option_error(ctx, compare: [converge_within: unquote(Macro.escape(value))])
        assert message =~ "converge_within"
        assert message =~ "millisecond"
      end
    end

    test "compare: [settle: 100] is an option error naming converge_within:", ctx do
      assert option_error(ctx, compare: [settle: 100]) =~ "converge_within"
    end
  end

  describe "removed comparison options" do
    test "compare: :correctness says comparison is on by default and names converge_within",
         ctx do
      message = option_error(ctx, compare: :correctness)
      assert message =~ "default"
      assert message =~ "compare: [converge_within:"
    end

    for mode <- [:performance, :both] do
      test "compare: #{inspect(mode)} is an option error naming latency:", ctx do
        assert option_error(ctx, compare: unquote(mode)) =~ "latency: true"
      end
    end

    test "any other atom for compare: is an option error", ctx do
      option_error(ctx, compare: :sometimes)
    end

    test "equivalence: is an option error naming @compare and using:", ctx do
      for value <- [:structural, :exact, fn a, b -> a == b end] do
        message = option_error(ctx, equivalence: value)
        assert message =~ "@compare"
        assert message =~ "using:"
      end
    end
  end

  describe "the no-observation guard" do
    test "two targets and no @compare on any projection fail before any adapter setup" do
      for model <- [PayModel, PlainModel] do
        error = Compare.raised(fn -> Compare.run(model, two_targets()) end)
        assert Exception.message(error) =~ "@compare"
        refute_received {:setup, _name}
      end
    end

    test "one target without any @compare runs" do
      assert {:ok, _stats} = Compare.run(PayModel, [Compare.target("a")])
    end

    test "the guard is static: a declared schedule that never fires is not an error", ctx do
      never = Compare.fixture!(ctx.compiled, :never)

      assert {:ok, stats} = Compare.run(model!(ctx, :never), two_targets())
      assert Compare.counts(stats, {never, :reads}).compared_at == 0
    end
  end

  describe "latency:" do
    test "latency: true measures every run and reports per-target metrics by target name", ctx do
      assert {:ok, stats} =
               Compare.run(model!(ctx, :agree), two_targets(),
                 latency: true,
                 concurrency: :serial,
                 max_runs: 2
               )

      metrics = Map.fetch!(stats, :metrics)
      assert metrics |> Map.keys() |> Enum.sort() == ["a", "b"]

      for name <- ["a", "b"] do
        assert metrics[name] |> Map.keys() |> Enum.sort() == @metric_keys
        assert metrics[name].commands == 6
        assert metrics[name].by_command |> Map.keys() == [Compare.Pay]
        assert metrics[name].by_command[Compare.Pay].commands == 6
      end
    end

    test "latency: defaults to false and a run without it reports no metrics", ctx do
      validated = Options.validate_run!(model: model!(ctx, :agree), targets: two_targets())
      assert Keyword.fetch!(validated, :latency) == false

      assert {:ok, stats} = Compare.run(model!(ctx, :agree), two_targets())
      refute Map.has_key?(stats, :metrics)
    end

    @accepted [
      {true, [warmup: 0]},
      {[warmup: 2], [warmup: 2]},
      {[], [warmup: 0]},
      {[p95: [max_ratio: 1.5]], [warmup: 0, p95: [max_ratio: 1.5]]},
      {[p99: [max: {800, :milliseconds}]], [warmup: 0, p99: [max: {800, :milliseconds}]]},
      {[warmup: 5, p95: [max_ratio: 1.5], p99: [max: {800, :milliseconds}]],
       [warmup: 5, p95: [max_ratio: 1.5], p99: [max: {800, :milliseconds}]]},
      {[mean: [max: {2, :seconds}, max_ratio: 3]],
       [warmup: 0, mean: [max: {2, :seconds}, max_ratio: 3]]}
    ]

    for {given, normalized} <- @accepted do
      test "latency: #{inspect(given)} validates and normalizes", ctx do
        validated =
          Options.validate_run!(
            model: model!(ctx, :agree),
            targets: two_targets(),
            latency: unquote(Macro.escape(given))
          )

        assert Keyword.fetch!(validated, :latency) == unquote(Macro.escape(normalized))
      end
    end

    test "a bare integer duration is an option error that says the unit must be written",
         ctx do
      message = option_error(ctx, latency: [p95: [max: 800]])
      assert message =~ "latency"
      assert message =~ "seconds"
      assert message =~ "milliseconds"
      assert message =~ "{800, :milliseconds}"
    end

    test "a non-positive or unknown-unit duration is an option error", ctx do
      assert option_error(ctx, latency: [p95: [max: {0, :seconds}]]) =~ "positive"
      assert option_error(ctx, latency: [p95: [max: {5, :hours}]]) =~ ":milliseconds"
    end

    test "a statistic with an empty bound list is an option error naming the statistic", ctx do
      message = option_error(ctx, latency: [p95: []])
      assert message =~ "p95"
      assert message =~ "max"
      assert message =~ "max_ratio"
    end

    test "an unknown statistic is an option error naming the allowed statistics", ctx do
      message = option_error(ctx, latency: [p42: [max: {1, :seconds}]])
      assert message =~ "p42"
      assert message =~ "p50"
      assert message =~ "p99"
      assert message =~ "mean"
    end

    test "an unknown bound is an option error naming max and max_ratio", ctx do
      message = option_error(ctx, latency: [p95: [min: {1, :seconds}]])
      assert message =~ "min"
      assert message =~ "max_ratio"
    end

    test "a non-positive ratio is an option error", ctx do
      assert option_error(ctx, latency: [p95: [max_ratio: 0]]) =~ "positive"
    end

    test "a negative warmup is an option error naming warmup", ctx do
      message = option_error(ctx, latency: [warmup: -1])
      assert message =~ "warmup"
      assert message =~ "non-negative"
    end

    for {key, value, replacement} <- [
          {:metrics, [:latency], "latency:"},
          {:percentiles, [50], "latency:"},
          {:warmup_runs, 3, "latency: [warmup: n]"}
        ] do
      test "#{key}: is an option error naming #{replacement}", ctx do
        message = option_error(ctx, [{unquote(key), unquote(value)}])
        assert message =~ "`#{unquote(key)}:`"
        assert message =~ unquote(replacement)
      end
    end

    test "latency: of any truthy shape with concurrency: :parallel is an option error", ctx do
      for latency <- [true, [p95: [max_ratio: 1.5]], [warmup: 1]] do
        message = option_error(ctx, latency: latency, concurrency: :parallel)
        assert message =~ "latency:"
        assert message =~ "concurrency: :serial"
      end
    end

    test "latency: false with concurrency: :parallel is not an error", ctx do
      assert {:ok, _stats} =
               Compare.run(model!(ctx, :agree), two_targets(),
                 latency: false,
                 concurrency: :parallel
               )
    end

    test "max_ratio: on one target is an option error before any adapter setup", ctx do
      error =
        Compare.raised(fn ->
          Compare.run(model!(ctx, :agree), [Compare.target("a")],
            latency: [p95: [max_ratio: 1.5]]
          )
        end)

      assert is_exception(error, NimbleOptions.ValidationError)
      assert Exception.message(error) =~ "max_ratio"
      assert Exception.message(error) =~ "at least two targets"
      refute_received {:setup, _name}
    end

    test "max: on one target is accepted", ctx do
      assert {:ok, stats} =
               Compare.run(model!(ctx, :agree), [Compare.target("a")],
                 latency: [p99: [max: {1, :minutes}]]
               )

      assert Map.keys(stats.metrics) == ["a"]
    end
  end
end
