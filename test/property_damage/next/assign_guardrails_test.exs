defmodule PropertyDamage.Next.AssignGuardrailsTest do
  # A layer sets an assign beside the command, and a port acknowledges each
  # assign it takes into account at a step. Two mistakes are caught: a run
  # whose assign was set but never acknowledged by any port fails after the
  # search with both counts, and a port that acknowledges an assign no spec
  # set at that step raises at the call.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Report}
  alias PropertyDamage.Next.Test.Fixtures, as: F

  @max_steps 3
  @max_plans 2
  # Every slot draws the model's only spec, and every plan passes, so each
  # executed step carries the assign: three slots in each of two plans.
  @steps_run @max_steps * @max_plans

  defmodule Layers do
    @moduledoc false
    alias PropertyDamage.Next.StepSpec

    def retries(spec), do: StepSpec.assign(spec, :retry, StreamData.constant(true))
    def no_retries(spec), do: StepSpec.assign(spec, :retry, StreamData.constant(false))
    def delays(spec), do: StepSpec.assign(spec, :delay, StreamData.constant(true))
  end

  defmodule RetryModel do
    @moduledoc false
    # One command; a layer sets the assign :retry to true on it.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.AssignGuardrailsTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: [F.Plain] |> StepSpec.normalize() |> StepSpec.transform(&Layers.retries/1)
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule FalseRetryModel do
    @moduledoc false
    # As RetryModel, but the drawn :retry is always false.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.AssignGuardrailsTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: [F.Plain] |> StepSpec.normalize() |> StepSpec.transform(&Layers.no_retries/1)
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule DelayModel do
    @moduledoc false
    # One command whose only assign is :delay; nothing sets :retry.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.AssignGuardrailsTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: [F.Plain] |> StepSpec.normalize() |> StepSpec.transform(&Layers.delays/1)
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule MisspelledAdapter do
    @moduledoc false
    # Its retry clause matches :retyr, a key no layer sets, so the clause
    # never runs and no port acknowledges :retry.
    @behaviour PropertyDamage.Next.Adapter

    alias PropertyDamage.Next.Runtime

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, %{retyr: true}, %{pd: pd}) do
      Runtime.ack(pd, :retyr)
      {:ok, []}
    end

    def execute(_command, _assigns, _context), do: {:ok, []}
  end

  defmodule RetryAdapter do
    @moduledoc false
    # The same adapter with the key spelled right: its retry clause runs
    # and acknowledges :retry.
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

  defmodule AlwaysAckAdapter do
    @moduledoc false
    # Acknowledges :retry at every step, whether or not the step set it.
    @behaviour PropertyDamage.Next.Adapter

    alias PropertyDamage.Next.Runtime

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, _assigns, %{pd: pd}) do
      Runtime.ack(pd, :retry)
      {:ok, []}
    end
  end

  defp run(model, adapter) do
    Next.run(
      model: model,
      adapter: adapter,
      seed: 7,
      max_steps: @max_steps,
      max_plans: @max_plans
    )
  end

  defp row(rows, command, key), do: Enum.find(rows, &(&1.command == command and &1.key == key))

  describe "an assign set but acknowledged by no port" do
    test "fails the run after the search, with a row for the command and key and both counts" do
      assert {:error, %Failure{reason: {:unacknowledged_assigns, rows}} = failure} =
               run(RetryModel, MisspelledAdapter)

      assert %{set: @steps_run, acknowledged: 0} = row(rows, F.Plain, :retry)
      assert failure.plan == nil
      assert failure.journal == nil
      assert failure.step == nil
    end

    test "the failure's rendered report names the key and both counts" do
      assert {:error, %Failure{reason: {:unacknowledged_assigns, _rows}} = failure} =
               run(RetryModel, MisspelledAdapter)

      text = Report.format(Map.fetch!(failure, :report))

      assert text =~ "retry"
      assert text =~ "set #{@steps_run}"
      assert text =~ "acknowledged 0"
    end

    test "the run passes when the clause is spelled right, and counts every acknowledgment" do
      assert {:ok, report} = run(RetryModel, RetryAdapter)

      assert %{RetryAdapter => rows} = report.assigns
      assert %{set: @steps_run, acknowledged: @steps_run} = row(rows, F.Plain, :retry)
    end
  end

  describe "acknowledging an assign the step did not set" do
    test "raises AcknowledgedUnsetAssignError out of run/1, naming the key and the keys set" do
      error =
        assert_raise PropertyDamage.Next.AcknowledgedUnsetAssignError, fn ->
          run(DelayModel, AlwaysAckAdapter)
        end

      assert error.key == :retry
      assert :delay in error.assigns
      refute :retry in error.assigns
    end

    test "raises when the step drew the assign as false" do
      assert_raise PropertyDamage.Next.AcknowledgedUnsetAssignError, fn ->
        run(FalseRetryModel, AlwaysAckAdapter)
      end
    end

    test "does not raise when the step set the assign" do
      assert {:ok, _report} = run(RetryModel, AlwaysAckAdapter)
    end
  end
end
