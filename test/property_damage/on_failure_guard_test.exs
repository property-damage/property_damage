defmodule PropertyDamage.OnFailureGuardTest do
  @moduledoc """
  A raising on_failure handler must not destroy the failure PropertyDamage just
  found: the run still returns {:error, report}.
  """
  use ExUnit.Case, async: true

  defmodule Cmd do
    use PropertyDamage.Command
    defstruct [:n]
    @impl true
    def generator(_overrides), do: StreamData.fixed_map(%{n: StreamData.integer(0..10)})
  end

  defmodule State do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
  end

  defmodule AlwaysFail do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state

    @trigger every: 1
    def assert_never(_state, _cmd_or_event), do: PropertyDamage.fail!("always fails")
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    def commands, do: [Cmd]
    def command_sequence_projection, do: State
    def assertion_projections, do: [AlwaysFail]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    def setup(config), do: {:ok, config}
    def teardown(_context), do: :ok
    def execute(_command, _context, _runtime), do: {:ok, []}
  end

  test "a raising on_failure handler is caught; the failure report survives" do
    result =
      PropertyDamage.run(
        model: Model,
        adapter: Adapter,
        max_runs: 3,
        max_commands: 3,
        shrink: false,
        validate: false,
        on_failure: fn _report -> raise "boom in handler" end
      )

    assert {:error, _report} = result
  end
end
