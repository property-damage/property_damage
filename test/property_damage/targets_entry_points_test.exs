defmodule PropertyDamage.TargetsEntryPointsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Pd.Scaffold

  alias PropertyDamage.{
    Differential,
    Export,
    FailureReport,
    Integration,
    LoadTest,
    Mutation,
    Replay
  }

  alias PropertyDamage.Test.{ExecutorModel, SimpleAdapter, TestAdapter}

  defp assert_retired(fun, key, replacement_text) do
    error = assert_raise NimbleOptions.ValidationError, fun
    assert error.key == key
    assert Exception.message(error) =~ "`#{key}:` was replaced by `targets:`"
    assert Exception.message(error) =~ replacement_text
  end

  describe "retired run-level keys on each entry point" do
    test "execute/2 rejects adapter: and accepts targets:" do
      assert_retired(fn -> PropertyDamage.execute([], adapter: SimpleAdapter) end, :adapter, "")
      assert {:ok, []} = PropertyDamage.execute([], targets: [SimpleAdapter])
    end

    test "LoadTest.run/1 rejects adapter_config:" do
      assert_retired(
        fn ->
          LoadTest.run(
            model: ExecutorModel,
            targets: [SimpleAdapter],
            adapter_config: %{},
            arrival_rate: 1,
            duration: {1, :seconds}
          )
        end,
        :adapter_config,
        "as `config:`"
      )
    end

    test "Mutation.run/1 rejects adapter:" do
      assert_retired(
        fn -> Mutation.run(model: ExecutorModel, adapter: SimpleAdapter) end,
        :adapter,
        ""
      )
    end

    test "Integration.run/1 and hunt_bugs/1 reject adapter_config:" do
      for fun <- [&Integration.run/1, &Integration.hunt_bugs/1] do
        assert_retired(
          fn ->
            fun.(model: ExecutorModel, targets: [SimpleAdapter], adapter_config: %{})
          end,
          :adapter_config,
          "as `config:`"
        )
      end
    end

    test "Export.to_exunit/2 rejects adapter_config: and accepts targets:" do
      report = failure_report()

      assert_retired(
        fn -> Export.to_exunit(report, adapter_config: %{a: 1}) end,
        :adapter_config,
        "as `config:`"
      )

      source = Export.to_exunit(report, targets: [{TestAdapter, config: %{a: 1}}])
      assert source =~ "targets: [{Adapter, config: %{a: 1}}]"
    end

    test "Replay.start/2 rejects adapter_config: and accepts a targets: override" do
      report = %FailureReport{model: nil, adapter: SimpleAdapter}

      assert_retired(
        fn -> Replay.start(report, adapter_config: %{a: 1}) end,
        :adapter_config,
        "as `config:`"
      )

      assert {:error, :missing_model} = Replay.start(report, targets: [SimpleAdapter])
    end
  end

  describe "entry keys an entry point cannot honor" do
    test "Differential.run/1 rejects injectors:" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          Differential.run(
            model: ExecutorModel,
            targets: [SimpleAdapter, {TestAdapter, injectors: [SimpleAdapter]}],
            compare: :correctness
          )
        end

      assert error.key == :targets

      assert Exception.message(error) =~
               "`injectors:` is not supported by PropertyDamage.Differential.run/1"
    end

    test "LoadTest.run/1 rejects injectors:" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          LoadTest.run(
            model: ExecutorModel,
            targets: [{SimpleAdapter, injectors: [TestAdapter]}],
            arrival_rate: 1,
            duration: {1, :seconds}
          )
        end

      assert error.key == :targets
      assert Exception.message(error) =~ "`injectors:` is not supported by"
    end

    test "execute/2 rejects mocks:" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          PropertyDamage.execute([], targets: [{SimpleAdapter, mocks: [TestAdapter]}])
        end

      assert error.key == :targets
      assert Exception.message(error) =~ "`mocks:` is not supported by PropertyDamage.execute/2"
    end
  end

  describe "generated source" do
    test "the reproduction command names the adapter under targets:" do
      report = %FailureReport{seed: 5, model: ExecutorModel, adapter: SimpleAdapter}

      assert FailureReport.reproduction_command(report) ==
               "PropertyDamage.run(model: PropertyDamage.Test.ExecutorModel, " <>
                 "targets: [PropertyDamage.Test.SimpleAdapter], seed: 5, max_runs: 1)"
    end

    test "the generated ExUnit test passes targets: and no adapter:" do
      source = Export.to_exunit(failure_report())

      assert source =~ "targets: [Adapter]"
      refute source =~ ~r/\badapter:/
    end

    test "the scaffolded adapter shows a targets: run call" do
      api_info = %{title: "Demo", version: "1", base_url: "http://localhost:4000"}
      source = Scaffold.generate_adapter([], "Demo", api_info, [])

      assert source =~ "targets: ["
      refute source =~ "adapter_config"
    end
  end

  defp failure_report do
    commands = [%PropertyDamage.Test.Commands.CreateItem{name: "a", quantity: 1}]

    %FailureReport{
      seed: 1,
      run_number: 1,
      failed_at_index: 0,
      failure_reason: PropertyDamage.Failure.check_failed(:check, "boom"),
      original_sequence: PropertyDamage.Sequence.linear(commands),
      trace: PropertyDamage.RunTrace.new(plan: PropertyDamage.Sequence.linear(commands)),
      timestamp: ~U[2025-12-26 14:30:00Z],
      model: ExecutorModel,
      adapter: SimpleAdapter
    }
  end
end
