defmodule PropertyDamage.ExpansionPathsTest do
  # The paths that execute a report's sequence again run each root as the
  # report's run ran it, from the choices the report's trace records, and
  # never draw an expansion again. A path that cannot run a target's leaves,
  # or that is asked to run a target whose choices the report does not
  # record, raises instead of running the roots as themselves.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{FailureReport, RunTrace, Sequence, Shrinker}
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.{Credit, Refund, SecondCreditFails, Totals}

  defp model_once!(name, opts) do
    module = Module.concat(ExpansionPaths, name)
    if Code.ensure_loaded?(module), do: module, else: X.define_model!(module, opts)
  end

  defp run(model, targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 12,
          validate: false
        ],
        extra
      )
    )
  end

  # An unshrunk divergence: "beta" credits one too much on every Credit leaf,
  # so only a Refund's rewrite exposes it. The first seed in 1..30 that fails.
  defp diverged! do
    model = model_once!(Diverged, expansions: [{Refund, &X.refund_two/2}])

    Enum.find_value(1..30, fn seed ->
      recorder = start_recorder()
      targets = [X.target("alpha", recorder), X.target("beta", recorder, %{bug: :credit})]

      case run(model, targets, seed: seed, shrink: false) do
        {:error, %FailureReport{} = report} -> {report, recorder}
        {:ok, _stats} -> nil
      end
    end) || flunk("no seed in 1..30 fails: the second variant never ran a Refund rewrite")
  end

  # A one-target run whose check fails on the second leaf of a Refund rewrite.
  defp leaf_failure! do
    model =
      model_once!(LeafFailure,
        expansions: [{Refund, &X.refund_rewrite/2}],
        checks: [Totals, SecondCreditFails]
      )

    seed =
      X.find_seed(model, 6, 1..2_000, &Enum.any?(&1, fn root -> match?(%Refund{}, root) end)) ||
        flunk("no seed in 1..2000 generates a Refund root")

    assert {:error, %FailureReport{} = report} =
             run(model, [X.target("solo", nil)], seed: seed, max_commands: 6, shrink: false)

    report
  end

  defp shrunk(report), do: report |> FailureReport.shrunk_sequence() |> Sequence.to_list()

  defp signature(report),
    do: Shrinker.failure_signature(report.failure_reason, report.variant.index)

  describe "PropertyDamage.shrink_further/2" do
    test "shrinks with each target's entries carried, never picked again" do
      {report, recorder} = diverged!()

      assert {:ok, further} = PropertyDamage.shrink_further(report)
      assert length(shrunk(further)) < length(shrunk(report))
      assert signature(further) == signature(report)

      assert %{entry: "Refund[1]", leaves: [Credit, Credit]} =
               further.expansions |> Map.fetch!("beta") |> Enum.at(further.failed_at_index)

      for name <- ["alpha", "beta"] do
        [explored | later] = recorder |> recorded() |> X.segments(name)
        original = Map.new(X.by_root(explored))

        for segment <- later, {tag, commands} <- X.by_root(segment) do
          assert X.modules(commands) == X.modules(original[tag])
        end
      end
    end

    test "raises for a target whose choices the report does not record" do
      {report, _recorder} = diverged!()

      error =
        assert_raise ArgumentError, fn ->
          PropertyDamage.shrink_further(report, targets: [X.target("gamma", nil)])
        end

      assert error.message =~ "gamma"
      assert error.message =~ "shrink_further"
    end
  end

  describe "PropertyDamage.Replay" do
    test "raises for a target whose choices the report does not record" do
      {report, _recorder} = diverged!()

      error =
        assert_raise ArgumentError, fn ->
          PropertyDamage.Replay.run(report, targets: [X.target("gamma", nil)])
        end

      assert error.message =~ "gamma"
      assert error.message =~ "Replay"
    end
  end

  describe "PropertyDamage.Analysis.isolate_trigger/2" do
    test "raises when the target ran roots as expansions" do
      report = leaf_failure!()

      error =
        assert_raise ArgumentError, fn -> PropertyDamage.Analysis.isolate_trigger(report) end

      assert error.message =~ "isolate_trigger"
      assert error.message =~ "expansion"
    end
  end

  describe "an exported script" do
    # "beta" refuses the second Credit leaf: an adapter failure in the second
    # target, while the reference ran every root as itself.
    test "runs what the reference ran, when another target failed" do
      model = model_once!(ExportReference, expansions: [{Refund, &X.refund_rewrite/2}])

      report =
        Enum.find_value(1..30, fn seed ->
          targets = [
            X.target("alpha", nil, %{}, expansion: :identity),
            X.target("beta", nil, %{fail_part: 1})
          ]

          case run(model, targets, seed: seed, shrink: false) do
            {:error, %FailureReport{} = report} -> report
            {:ok, _stats} -> nil
          end
        end) || flunk("no seed in 1..30 fails")

      assert report.variant.name == "beta"
      roots = report |> FailureReport.shrunk_sequence() |> Sequence.to_list()
      assert Enum.any?(roots, &match?(%Refund{}, &1))

      script =
        PropertyDamage.Export.to_script(report, :curl,
          base_url: "http://localhost:4000",
          adapter: X.RecordingAdapter
        )

      steps = for [_, name] <- Regex.scan(~r/=== Step \d+: (\w+)/, script), do: name
      assert steps == Enum.map(roots, &X.short(&1.__struct__))

      [header | _] = String.split(script, "=== Step 1:", parts: 2)
      assert header =~ ~s(reference target "alpha")
    end
  end

  describe "PropertyDamage.RunTrace.capture/1" do
    test "runs the target's expansions from the seed and records them" do
      model = model_once!(Capture, expansions: [{Refund, &X.refund_rewrite/2}])

      seed =
        X.find_seed(model, 6, 1..2_000, &Enum.any?(&1, fn root -> match?(%Refund{}, root) end)) ||
          flunk("no seed in 1..2000 generates a Refund root")

      recorder = start_recorder()

      trace =
        RunTrace.capture(
          model: model,
          targets: [X.target("solo", recorder)],
          seed: seed,
          max_commands: 6
        )

      executed = recorder |> recorded() |> X.segments("solo") |> List.last()
      assert Enum.any?(executed, &match?(%Credit{}, &1))
      refute Enum.any?(executed, &match?(%Refund{}, &1))

      choices = Map.fetch!(trace.expansion, "solo")
      assert Enum.flat_map(choices, & &1.commands) == executed
    end
  end
end
