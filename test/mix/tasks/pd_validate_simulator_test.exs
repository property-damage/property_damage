defmodule Mix.Tasks.Pd.ValidateSimulatorTest do
  # async: false because the task prints to stdout, which the test captures.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Validate

  @message "Model defines no simulator/0: without a simulator no placeholders are minted"

  defmodule Done do
    defstruct []
  end

  defmodule Cmd do
    use PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Count do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: 0
    @impl true
    def apply(count, %Done{}), do: count + 1
    def apply(count, _event), do: count
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def execute(_command, _ctx, _runtime), do: {:ok, [%Done{}]}
    @impl true
    def teardown(_ctx), do: :ok
  end

  defmodule NoSimulatorModel do
    use PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: Count
  end

  defmodule Simulator do
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def simulate(_command, _state), do: []
  end

  defmodule SimulatorModel do
    use PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: Count
    @impl true
    def simulator, do: Simulator
  end

  defp output_of(args), do: capture_io(fn -> Validate.exec(args) end)

  test "warns when the model defines no simulator, with and without an adapter" do
    for args <- [[inspect(NoSimulatorModel)], [inspect(NoSimulatorModel), inspect(Adapter)]] do
      output = output_of(args)
      assert output =~ @message
      assert output =~ "an `external()` field"
    end
  end

  test "a model with a simulator gets no such warning (control)" do
    for args <- [[inspect(SimulatorModel)], [inspect(SimulatorModel), inspect(Adapter)]] do
      refute output_of(args) =~ "defines no simulator"
    end
  end

  test "--strict fails on the warning" do
    status = fn ->
      send(self(), {:status, Validate.exec([inspect(NoSimulatorModel), "--strict"])})
    end

    capture_io(status)
    assert_received {:status, :error}
  end
end
