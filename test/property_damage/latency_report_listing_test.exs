defmodule PropertyDamage.LatencyReportListingTest do
  # A latency report carries the last run of the target that broke the budget,
  # so its listing shows that target's events and log lines under each step.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.Lockstep.{Step, StepModel, Stepped}

  defmodule NamedAdapter do
    @moduledoc false
    # Answers each Step after `sleep_ms` and logs which target answered.
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Step{value: value}, ctx, runtime) do
      Process.sleep(ctx.sleep_ms)
      :ok = PropertyDamage.Runtime.log(runtime, "stepped by #{ctx.name}", [])
      {:ok, [%Stepped{value: value}]}
    end
  end

  defp breach! do
    targets = [
      {NamedAdapter, name: "ref", config: %{name: "ref", sleep_ms: 1}},
      {NamedAdapter, name: "slow", config: %{name: "slow", sleep_ms: 5}}
    ]

    assert {:error, %FailureReport{kind: :latency_exceeded} = report} =
             PropertyDamage.run(
               model: StepModel,
               targets: targets,
               max_runs: 3,
               max_commands: 3,
               seed: 4_321,
               validate: false,
               compare: [converge_within: 30],
               latency: [p95: [max_ratio: 1.0e-9]]
             )

    report
  end

  test "the listing shows the failing target's events and log lines" do
    report = breach!()
    assert report.variant.name == "slow"
    assert report.failed_at_index == nil

    text = Formatter.format(report, :terminal, color: false)

    assert text =~ "Stepped"
    assert text =~ "stepped by slow"
    refute text =~ "stepped by ref"
    assert FailureReport.event_log(report) != []
  end
end
