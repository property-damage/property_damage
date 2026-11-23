defmodule PropertyDamage.Next.AssignAcksTest do
  # Acknowledgments and ignored assigns: where `Runtime.ack/2` works, which
  # misuse raises, what a search counts, and that an assign stays out of
  # the model.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{AcknowledgedIgnoredAssignError, Failure, Runtime}
  alias PropertyDamage.Next.Test.Fixtures, as: F
  alias PropertyDamage.Next.Test.Terms

  @max_steps 3
  @max_plans 2
  @steps_run @max_steps * @max_plans

  defmodule Layers do
    @moduledoc false
    alias PropertyDamage.Next.StepSpec

    def retry(spec), do: StepSpec.assign(spec, :retry, StreamData.constant(true))
    def never_retry(spec), do: StepSpec.assign(spec, :retry, StreamData.constant(false))
    def delay(spec), do: StepSpec.assign(spec, :delay, StreamData.constant(true))
    def secret(spec), do: StepSpec.assign(spec, :secret, StreamData.constant({:secret, 9137}))
  end

  defmodule RetryModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.AssignAcksTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: [F.Plain] |> StepSpec.normalize() |> StepSpec.transform(&Layers.retry/1)
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule NeverRetryModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.AssignAcksTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: [F.Plain] |> StepSpec.normalize() |> StepSpec.transform(&Layers.never_retry/1)
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule RetryDelayModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.AssignAcksTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps,
      do:
        [F.Plain]
        |> StepSpec.normalize()
        |> StepSpec.transform([&Layers.retry/1, &Layers.delay/1])

    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule DelayOnlyModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.AssignAcksTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F

    def steps, do: [F.Plain] |> StepSpec.normalize() |> StepSpec.transform(&Layers.delay/1)
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule AckAdapter do
    @moduledoc false
    # Acknowledges :retry at every step that sets it.
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, %{retry: true}, %{pd: pd}) do
      Runtime.ack(pd, :retry)
      {:ok, []}
    end

    def execute(_command, _assigns, _context), do: {:ok, []}
  end

  defmodule TaskAckAdapter do
    @moduledoc false
    # Acknowledges from a process the adapter starts.
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, _assigns, %{pd: pd}) do
      Task.async(fn -> Runtime.ack(pd, :retry) end) |> Task.await()
      {:ok, []}
    end
  end

  defmodule AlwaysAckAdapter do
    @moduledoc false
    # Acknowledges :retry at every step, whether or not the step set it.
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, _assigns, %{pd: pd}) do
      Runtime.ack(pd, :retry)
      {:ok, []}
    end
  end

  defmodule FailingAckAdapter do
    @moduledoc false
    # Acknowledges :retry, then fails from the second step of an execution on.
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime, calls: :counters.new(1, [])}}

    @impl true
    def execute(_command, _assigns, %{pd: pd, calls: calls}) do
      Runtime.ack(pd, :retry)
      :counters.add(calls, 1, 1)
      if :counters.get(calls, 1) >= 2, do: {:error, :boom}, else: {:ok, []}
    end
  end

  defmodule OutsideAdapter do
    @moduledoc false
    @behaviour PropertyDamage.Next.Adapter

    @impl true
    def setup(_config, runtime), do: {:ok, %{pd: runtime}}

    @impl true
    def execute(_command, _assigns, %{pd: pd}) do
      send(self(), {:handle, pd})
      {:ok, []}
    end
  end

  defp opts(model, adapter, more \\ []) do
    [model: model, adapter: adapter, seed: 7, max_steps: @max_steps, max_plans: @max_plans] ++
      more
  end

  describe "Runtime.ack/2" do
    test "returns :ok at a step that set the key" do
      assert {{:ok, _}, _counts} = Next.run_counted(opts(RetryModel, AckAdapter))
    end

    test "raises ArgumentError outside a step" do
      runtime = struct(Runtime)

      error = Terms.raised(fn -> Runtime.ack(runtime, :retry) end)

      assert %ArgumentError{} = error
      assert Exception.message(error) =~ "outside a step"
    end

    test "works from a process the adapter started with a Task" do
      assert {{:ok, _}, counts} = Next.run_counted(opts(RetryModel, TaskAckAdapter))

      assert %{TaskAckAdapter => [%{key: :retry, acknowledged: @steps_run}]} = counts
    end

    test "raises ArgumentError after the step ended, with the handle an adapter kept" do
      {:ok, _} = Next.run(opts(RetryModel, OutsideAdapter, ignored_assigns: [:retry]))
      assert_received {:handle, runtime}

      assert_raise ArgumentError, ~r/outside a step/, fn -> Runtime.ack(runtime, :retry) end
    end

    test "an unset acknowledgment names the key and the keys the step set, and is not shrunk" do
      error =
        assert_raise PropertyDamage.Next.AcknowledgedUnsetAssignError, fn ->
          Next.run(opts(DelayOnlyModel, AlwaysAckAdapter))
        end

      assert error.key == :retry
      assert error.assigns == [:delay]
      assert Exception.message(error) =~ ":retry"
    end

    test "an unset acknowledgment raises out of replay/2" do
      journal = Next.plan(DelayOnlyModel, 7, max_steps: @max_steps).journal

      assert_raise PropertyDamage.Next.AcknowledgedUnsetAssignError, fn ->
        Next.replay(journal, model: DelayOnlyModel, adapter: AlwaysAckAdapter)
      end
    end
  end

  describe "ignored_assigns:" do
    test "a name no spec sets raises ArgumentError before the first plan, naming the key" do
      error =
        assert_raise ArgumentError, fn ->
          Next.run(opts(RetryModel, AckAdapter, ignored_assigns: [:retyr]))
        end

      assert Exception.message(error) =~ ":retyr"
    end

    test "the load check also guards replay/2" do
      journal = Next.plan(RetryModel, 7, max_steps: @max_steps).journal

      assert_raise ArgumentError, ~r/:retyr/, fn ->
        Next.replay(journal, model: RetryModel, adapter: AckAdapter, ignored_assigns: [:retyr])
      end
    end

    test "something other than a list of keys raises ArgumentError" do
      assert_raise ArgumentError, ~r/ignored_assigns/, fn ->
        Next.run(opts(RetryModel, AckAdapter, ignored_assigns: :retry))
      end
    end

    test "acknowledging an ignored key raises at the call, naming the key and the target" do
      error =
        assert_raise AcknowledgedIgnoredAssignError, fn ->
          Next.run(opts(RetryModel, AckAdapter, ignored_assigns: [:retry]))
        end

      assert error.key == :retry
      assert error.target == AckAdapter
      assert Exception.message(error) =~ ":retry"
    end

    test "acknowledging an ignored key raises out of replay/2" do
      journal = Next.plan(RetryModel, 7, max_steps: @max_steps).journal

      assert_raise AcknowledgedIgnoredAssignError, fn ->
        Next.replay(journal, model: RetryModel, adapter: AckAdapter, ignored_assigns: [:retry])
      end
    end

    test "an ignored key the adapter leaves alone is accepted and still counted as set" do
      assert {{:ok, _}, counts} =
               Next.run_counted(opts(RetryDelayModel, AckAdapter, ignored_assigns: [:delay]))

      assert %{AckAdapter => rows} = counts
      assert %{set: @steps_run, acknowledged: 0} = Enum.find(rows, &(&1.key == :delay))
    end
  end

  describe "counts" do
    test "set counts executed steps with a truthy assign, acknowledged counts the calls" do
      assert {{:ok, _}, counts} =
               Next.run_counted(opts(RetryDelayModel, AckAdapter, ignored_assigns: [:delay]))

      assert counts == %{
               AckAdapter => [
                 %{command: F.Plain, key: :delay, set: @steps_run, acknowledged: 0},
                 %{command: F.Plain, key: :retry, set: @steps_run, acknowledged: @steps_run}
               ]
             }
    end

    test "an assign drawn as false is not counted as set" do
      assert {{:ok, _}, counts} = Next.run_counted(opts(NeverRetryModel, AckAdapter))

      assert counts == %{}
    end

    test "shrink candidates are not counted" do
      run = fn shrink -> Next.run_counted(opts(RetryModel, FailingAckAdapter, shrink: shrink)) end

      assert {{:error, %Failure{shrink_runs: 0}}, searched} = run.(false)
      assert {{:error, %Failure{shrink_runs: runs}}, shrunk} = run.(true)

      assert runs > 0
      assert shrunk == searched
    end

    test "the counts stop at the failing plan, and count its steps up to the failure" do
      assert {{:error, %Failure{plan_number: 1}}, counts} =
               Next.run_counted(opts(RetryModel, FailingAckAdapter, shrink: false))

      assert %{FailingAckAdapter => [%{set: 2, acknowledged: 2}]} = counts
    end

    test "run/1 returns the same shape as before" do
      assert {:ok, %{plans: @max_plans, kept: []}} = Next.run(opts(RetryModel, AckAdapter))
    end
  end

  describe "an assign stays out of the model" do
    defmodule SecretAdapter do
      @moduledoc false
      # Reports the assigns it receives to the process that runs the
      # execution, and echoes only the command back as an event.
      @behaviour PropertyDamage.Next.Adapter

      defmodule Event do
        @moduledoc false
        defstruct [:note]
      end

      @impl true
      def setup(_config, _runtime), do: {:ok, %{}}

      @impl true
      def execute(command, assigns, _context) do
        send(self(), {:adapter_received, assigns})
        {:ok, [%Event{note: command.note}]}
      end
    end

    defmodule RecordingSimulator do
      @moduledoc false
      @behaviour PropertyDamage.Model.Simulator

      @impl true
      def simulate(command, state) do
        Process.put(:model_saw, [{:simulate, command, state} | Process.get(:model_saw, [])])
        []
      end
    end

    defmodule RecordingProjection do
      @moduledoc false
      use PropertyDamage.Model.Projection

      @impl true
      def init, do: %{}

      @impl true
      def apply(state, event) do
        Process.put(:model_saw, [{:apply, event, state} | Process.get(:model_saw, [])])
        state
      end
    end

    defmodule SecretModel do
      @moduledoc false
      use PropertyDamage.Next.Model

      alias PropertyDamage.Next.AssignAcksTest.Layers
      alias PropertyDamage.Next.StepSpec
      alias PropertyDamage.Next.Test.Fixtures, as: F

      def steps, do: [F.Plain] |> StepSpec.normalize() |> StepSpec.transform(&Layers.secret/1)
      def simulator, do: PropertyDamage.Next.AssignAcksTest.RecordingSimulator
      def command_sequence_projection, do: PropertyDamage.Next.AssignAcksTest.RecordingProjection
    end

    test "the adapter receives the assign, and no simulator or projection sees its value" do
      Process.delete(:model_saw)

      assert {:ok, _} = Next.run(opts(SecretModel, SecretAdapter, ignored_assigns: [:secret]))

      assert_received {:adapter_received, %{secret: {:secret, 9137}}}

      saw = Process.get(:model_saw)
      assert is_list(saw) and saw != []
      refute Terms.mentions?(saw, {:secret, 9137})
      refute Terms.mentions?(saw, 9137)
      refute Terms.mentions?(saw, :secret)
    end
  end
end
