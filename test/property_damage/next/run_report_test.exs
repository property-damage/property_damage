defmodule PropertyDamage.Next.RunReportTest do
  # run/1 returns one report, for a passing run and inside the failure of a
  # failing one. It is the single place for the withdrawn commands, the
  # specs each layer changed, the specs never drawn, the acknowledgment
  # counts of each assign and the kept sites of dependent StreamData
  # generators. A layer that changes no spec and a spec never drawn are
  # reported, not raised, and the run still passes unless it asks to fail on
  # a never-drawn spec.
  use ExUnit.Case, async: true

  import PropertyDamage.Next.Test.OwnLog, only: [with_own_log: 1]

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Report, StepSpec}
  alias PropertyDamage.Next.Test.Fixtures, as: F
  alias PropertyDamage.Next.Test.{Scheme, Shrink}

  defmodule Rare do
    @moduledoc false
    # A command with nothing to draw, always eligible, given a low weight.
    use PropertyDamage.Next.Command

    defstruct note: :rare
  end

  defmodule Layers do
    @moduledoc false
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    # Meant for F.Plain, but the module name is misspelled, so the first
    # clause matches no spec and the layer changes nothing.
    def misspelled(%StepSpec{command: F.Plian} = spec),
      do: StepSpec.merge_command_opts(spec, note: :layered)

    def misspelled(spec), do: spec

    # The same layer with the module spelled right.
    def plain_only(%StepSpec{command: F.Plain} = spec),
      do: StepSpec.merge_command_opts(spec, note: :layered)

    def plain_only(spec), do: spec

    def retries(spec), do: StepSpec.assign(spec, :retry, StreamData.constant(true))
  end

  defmodule LayeredModel do
    @moduledoc false
    # Two specs; the misspelled layer runs first, then the right one.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.RunReportTest.{Layers, Rare}
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps do
      [F.Plain, Rare]
      |> StepSpec.normalize()
      |> StepSpec.transform([&Layers.misspelled/1, &Layers.plain_only/1])
    end

    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule NoPayModel do
    @moduledoc false
    # The scheme model with Pay removed: Refund and RefundedTotal need an
    # earlier payment, so their when: is false at every slot.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.Test.Scheme

    def steps, do: Enum.reject(Scheme.Model.steps(), &(&1.command == Scheme.Pay))
    def simulator, do: Scheme.Model.simulator()
    def command_sequence_projection, do: Scheme.Model.command_sequence_projection()
    def check_projections, do: Scheme.Model.check_projections()
  end

  defmodule RareModel do
    @moduledoc false
    # Rare is eligible at every slot but weighted 1 against 999.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.RunReportTest.Rare
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: StepSpec.normalize([{F.Plain, weight: 999}, {Rare, weight: 1}])
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule PlainModel do
    @moduledoc false
    # One command with no assigns.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: StepSpec.normalize([F.Plain])
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule RetryModel do
    @moduledoc false
    # One command whose assign :retry is always true.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.RunReportTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: [F.Plain] |> StepSpec.normalize() |> StepSpec.transform(&Layers.retries/1)
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule OkAdapter do
    @moduledoc false
    # Every command answers no events.
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, _runtime), do: {:ok, %{}}

    @impl true
    def execute(_command, _assigns, _context), do: {:ok, []}
  end

  defmodule RetryAdapter do
    @moduledoc false
    # Acknowledges :retry at each step that set it.
    @behaviour PropertyDamage.Next.Adapter

    alias PropertyDamage.Next.Runtime

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, %{retry: true}, %{pd: pd}) do
      Runtime.ack(pd, :retry)
      {:ok, []}
    end

    def execute(_command, _assigns, _context), do: {:ok, []}
  end

  @kept_site %{site: :field, command: F.PlainFrom, key: :derived, spec: nil}

  defp run(model, adapter, opts \\ []) do
    [model: model, adapter: adapter, seed: 7, max_steps: 3, max_plans: 2]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  defp report!(%Failure{} = failure), do: Map.fetch!(failure, :report)

  defp lines(report), do: report |> Report.format() |> String.split("\n")

  defp line_with?(report, parts),
    do: Enum.any?(lines(report), fn line -> Enum.all?(parts, &String.contains?(line, &1)) end)

  defp layer_name(fun), do: "#{inspect(Layers)}.#{fun}/1"

  defp row(rows, command), do: Enum.find(rows, &(&1.command == command))

  # A seed whose first plan never draws Rare although Rare is eligible at
  # each of its slots. run/1 builds its first plan from the seed itself, so
  # a one-plan run from this seed draws exactly this plan.
  defp seed_never_drawing_rare do
    Enum.find(1..100, fn seed ->
      commands = Enum.map(Next.plan(RareModel, seed, max_steps: 3).steps, & &1.command)
      commands != [] and not Enum.any?(commands, &match?(%Rare{}, &1))
    end) || flunk("every seed draws Rare")
  end

  describe "layers" do
    test "a layer that changes no spec does not raise and the run passes" do
      specs = StepSpec.normalize([F.Plain, Rare])
      transformed = StepSpec.transform(specs, &Layers.misspelled/1)

      assert Enum.map(transformed, &%{&1 | history: []}) == specs
      assert {:ok, _report} = run(LayeredModel, OkAdapter)
    end

    test "the report lists each layer in application order with the specs it changed" do
      assert {:ok, report} = run(LayeredModel, OkAdapter)

      misspelled = layer_name(:misspelled)
      plain_only = layer_name(:plain_only)

      assert [
               %{layer: ^misspelled, specs_changed: 0},
               %{layer: ^plain_only, specs_changed: 1}
             ] = report.layers
    end

    test "the formatted report gives each layer a line with its name and specs changed" do
      assert {:ok, report} = run(LayeredModel, OkAdapter)

      assert line_with?(report, [layer_name(:misspelled), "specs changed: 0"])
      assert line_with?(report, [layer_name(:plain_only), "specs changed: 1"])
    end

    test "a layer returning anything but a spec raises ArgumentError at transform" do
      assert_raise ArgumentError, fn ->
        StepSpec.transform(StepSpec.normalize([F.Plain]), fn _spec -> :not_a_spec end)
      end
    end
  end

  describe "never-drawn specs" do
    test "a spec whose when: is false at every slot is listed as never eligible" do
      assert {:ok, report} = run(NoPayModel, Scheme.Adapter)

      assert %{reason: :never_eligible, spec: id} = row(report.never_drawn, Scheme.Refund)
      assert is_integer(id)
      assert %{reason: :never_eligible} = row(report.never_drawn, Scheme.RefundedTotal)
      assert line_with?(report, [inspect(Scheme.Refund), "never eligible"])
    end

    test "a spec eligible at some slot but never picked is listed as never chosen" do
      seed = seed_never_drawing_rare()

      assert {:ok, report} = run(RareModel, OkAdapter, seed: seed, max_plans: 1)

      assert [%{command: Rare, reason: :never_chosen}] = report.never_drawn
      assert line_with?(report, [inspect(Rare), "never chosen"])
    end

    test "a run that draws every spec lists none" do
      assert {:ok, report} = run(PlainModel, OkAdapter)
      assert report.never_drawn == []
    end

    test "never_drawn: :fail fails a run that would pass, with the never-drawn rows" do
      seed = seed_never_drawing_rare()

      assert {:error, %Failure{reason: {:never_drawn, rows}, plan: nil}} =
               run(RareModel, OkAdapter, seed: seed, max_plans: 1, never_drawn: :fail)

      assert %{reason: :never_chosen} = row(rows, Rare)

      assert {:error, %Failure{reason: {:never_drawn, rows}, plan: nil}} =
               run(NoPayModel, Scheme.Adapter, never_drawn: :fail)

      assert %{reason: :never_eligible} = row(rows, Scheme.Refund)
    end

    test "never_drawn: :fail lets a run that draws every spec pass" do
      assert {:ok, _report} = run(PlainModel, OkAdapter, never_drawn: :fail)
    end
  end

  describe "the report" do
    test "a passing run returns it with the number of plans" do
      assert {:ok, report} = run(PlainModel, OkAdapter)
      assert is_struct(report, Report)
      assert %{plans: 2} = report
    end

    test "a failing run carries it on the failure" do
      assert {:error, %Failure{} = failure} =
               Next.run(
                 model: Scheme.Model,
                 adapter: Scheme.Adapter,
                 seed: 1,
                 max_steps: 20,
                 max_plans: 10,
                 config: %{fault: :skip_credit}
               )

      assert is_struct(report!(failure), Report)
      assert report!(failure).withdrawn == failure.withdrawn
    end

    test "it carries the kept sites of a passing run and of a failing one" do
      {result, _log} =
        with_own_log(fn ->
          run(F.PlainFromModel, Shrink.Adapter, seed: 3, max_steps: 4, max_plans: 3)
        end)

      assert {:ok, report} = result
      assert is_struct(report, Report)
      assert report.kept == [@kept_site]

      fails? = fn _command, _earlier -> true end

      {result, _log} =
        with_own_log(fn ->
          run(F.PlainFromModel, Shrink.Adapter,
            seed: 3,
            max_steps: 4,
            max_plans: 3,
            config: %{fails?: fails?}
          )
        end)

      assert {:error, %Failure{} = failure} = result
      assert report!(failure).kept == [@kept_site]
    end

    test "its acknowledgment counts are keyed by the target, the adapter module" do
      assert {:ok, report} = run(RetryModel, RetryAdapter)

      assert Map.keys(report.assigns) == [RetryAdapter]

      assert [%{command: F.Plain, key: :retry, set: 6, acknowledged: 6}] =
               report.assigns[RetryAdapter]
    end

    test "the formatted report opens the acknowledgment section with Assigns and its wording" do
      assert {:ok, report} = run(RetryModel, RetryAdapter)

      lines = lines(report)
      header = Enum.find_index(lines, &(&1 =~ ~r/\bAssigns\b/))
      wording = Enum.find_index(lines, &String.contains?(&1, "every assign a port acts on"))

      assert is_integer(header)
      assert is_integer(wording)
      assert header < wording
    end
  end
end
