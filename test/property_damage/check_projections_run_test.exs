defmodule PropertyDamage.CheckProjectionsRunTest do
  @moduledoc """
  `Model.check_projections/0` is the only place the model lists projections
  that hold checks: a failing check there must fail the run.
  """
  use ExUnit.Case, async: true

  defmodule Send do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})
  end

  defmodule CountProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}
    @impl true
    def apply(state, %Send{}), do: %{state | count: state.count + 1}
    def apply(state, _), do: state
  end

  defmodule FailingCheck do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}
    @impl true
    def apply(state, %Send{}), do: %{state | count: state.count + 1}
    def apply(state, _), do: state

    @check every: 1
    def always_fails(state, _cmd_or_event) do
      if state.count >= 1, do: PropertyDamage.fail!("check ran", count: state.count)
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [Send]
    @impl true
    def command_sequence_projection, do: CountProjection
    @impl true
    def check_projections, do: [FailingCheck]
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_command, _state), do: []
  end

  defmodule NoOpAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Send{}, _ctx, _runtime), do: {:ok, []}
  end

  test "a failing check on a check_projections/0 projection fails the run" do
    result =
      PropertyDamage.run(
        model: Model,
        adapter: NoOpAdapter,
        seed: 12_345,
        max_runs: 1,
        shrink: false
      )

    assert {:error, report} = result
    assert inspect(report.failure_reason) =~ "check ran"
  end
end
