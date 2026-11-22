defmodule PropertyDamage.Next.ChecksTest do
  # Which projections' checks an execution runs: those of the check
  # projections and those of the command-sequence projection, each
  # projection's checks once per trigger even when it is listed in both
  # roles. A check form this engine does not run, @compare included, is
  # refused when the run loads the model.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, StepSpec}
  alias PropertyDamage.Next.Test.Fixtures, as: F
  alias PropertyDamage.Next.Test.Shrink
  alias PropertyDamage.Next.Test.Terms

  defmodule Tick do
    @moduledoc false
    use PropertyDamage.Next.Command

    defstruct [:n]

    def generator(_state, _opts), do: %{n: integer(1..3)}
  end

  defmodule Counted do
    @moduledoc false
    # Counts each run of its check in a counter the test owns.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: PropertyDamage.Next.ChecksTest.Tick
    def counted(_state, _command) do
      :counters.add(:persistent_term.get({__MODULE__, :calls}), 1, 1)
      true
    end
  end

  defmodule Tripwire do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: PropertyDamage.Next.ChecksTest.Tick
    def tripwire(_state, _command), do: PropertyDamage.fail!("a tick ran")
  end

  defmodule Compared do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @compare every: :end
    def observed(state, _root), do: state
  end

  defmodule BothRolesModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    def steps, do: StepSpec.normalize([PropertyDamage.Next.ChecksTest.Tick])
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: PropertyDamage.Next.ChecksTest.Counted
    def check_projections, do: [PropertyDamage.Next.ChecksTest.Counted]
  end

  defmodule CheckRoleModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    def steps, do: StepSpec.normalize([PropertyDamage.Next.ChecksTest.Tick])
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
    def check_projections, do: [PropertyDamage.Next.ChecksTest.Counted]
  end

  defmodule SequenceOnlyModel do
    @moduledoc false
    # The tripwire is the command-sequence projection and no check projection.
    use PropertyDamage.Next.Model

    def steps, do: StepSpec.normalize([PropertyDamage.Next.ChecksTest.Tick])
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: PropertyDamage.Next.ChecksTest.Tripwire
  end

  defmodule CompareModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    def steps, do: StepSpec.normalize([PropertyDamage.Next.ChecksTest.Tick])
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
    def check_projections, do: [PropertyDamage.Next.ChecksTest.Compared]
  end

  setup do
    counter = :counters.new(1, [])
    :persistent_term.put({Counted, :calls}, counter)
    on_exit(fn -> :persistent_term.erase({Counted, :calls}) end)
    %{counter: counter}
  end

  defp run(model, opts \\ []) do
    [model: model, adapter: Shrink.Adapter, seed: 1, max_steps: 7, max_plans: 2]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  test "a projection listed in both roles runs each check once per step", %{counter: counter} do
    assert {:ok, %{plans: 2}} = run(BothRolesModel)
    assert :counters.get(counter, 1) == 2 * 7
  end

  test "a projection listed as a check projection runs each check once per step",
       %{counter: counter} do
    assert {:ok, %{plans: 2}} = run(CheckRoleModel)
    assert :counters.get(counter, 1) == 2 * 7
  end

  test "the checks of the command-sequence projection run when it is no check projection" do
    assert {:error, %Failure{reason: {:check, :tripwire, message}}} = run(SequenceOnlyModel)

    assert message =~ "a tick ran"
  end

  test "a check projection that declares @compare is refused when the run loads the model" do
    error = Terms.raised(fn -> run(CompareModel) end)

    assert %ArgumentError{} = error
    assert Exception.message(error) =~ inspect(Compared)
  end
end
