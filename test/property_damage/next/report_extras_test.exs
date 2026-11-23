defmodule PropertyDamage.Next.ReportExtrasTest do
  # The parts of the run report the acceptance tests leave open: an ignored
  # key is not reported as unacknowledged, a failing plan wins over the
  # unacknowledged check, anonymous layers get a readable name, the text is
  # stable, and a bad :never_drawn option is refused.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Report, Runtime, StepSpec}
  alias PropertyDamage.Next.Test.Fixtures, as: F

  defmodule SilentAdapter do
    @moduledoc false
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, _runtime), do: {:ok, %{}}

    @impl true
    def execute(_command, _assigns, _context), do: {:ok, []}
  end

  defmodule FailingAdapter do
    @moduledoc false
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, _assigns, _context), do: {:error, :boom}
  end

  defmodule AckAdapter do
    @moduledoc false
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, _assigns, %{pd: pd}) do
      Runtime.ack(pd, :retry)
      {:ok, []}
    end
  end

  defmodule RetryModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps do
      [F.Plain]
      |> StepSpec.normalize()
      |> StepSpec.transform(fn spec ->
        StepSpec.assign(spec, :retry, StreamData.constant(true))
      end)
    end

    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defp run(adapter, opts \\ []) do
    [model: RetryModel, adapter: adapter, seed: 7, max_steps: 3, max_plans: 2]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  test "an ignored key that no port acknowledges does not fail the run" do
    assert {:ok, report} = run(SilentAdapter, ignored_assigns: [:retry])
    assert [%{key: :retry, set: 6, acknowledged: 0}] = report.assigns[SilentAdapter]
  end

  test "a plan that fails first wins, and its report still carries the counts" do
    assert {:error, %Failure{reason: {:adapter_error, :boom}} = failure} =
             run(FailingAdapter, shrink: false)

    assert [%{key: :retry, set: 1, acknowledged: 0}] = failure.report.assigns[FailingAdapter]
  end

  test "an assign acknowledged by one command is acknowledged for the key" do
    assert {:ok, %Report{}} = run(AckAdapter)
  end

  test "an anonymous layer is named by its module and function" do
    [spec] = StepSpec.transform(StepSpec.normalize([F.Plain]), fn spec -> spec end)

    assert [%{layer: name, specs_changed: 0}] = Report.layers([spec])
    assert name =~ "anonymous function in #{inspect(__MODULE__)}"
  end

  test "the same report renders the same text" do
    assert {:ok, first} = run(AckAdapter)
    assert {:ok, second} = run(AckAdapter)

    assert Report.format(first) == Report.format(second)
    assert Report.format(first) =~ "#{inspect(F.Plain)} retry: set 6, acknowledged 6"
  end

  test "a :never_drawn option other than :report or :fail raises" do
    assert_raise ArgumentError, ~r/:never_drawn/, fn -> run(AckAdapter, never_drawn: :raise) end
  end
end
