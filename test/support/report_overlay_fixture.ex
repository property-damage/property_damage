defmodule PropertyDamage.Test.ReportOverlayFixture do
  @moduledoc false
  # A model whose run fails on its second send, with one setup command, one
  # teardown command and an adapter that logs a line per command. The failing
  # report it yields is deterministic for a fixed seed.

  defmodule Opened do
    @moduledoc false
    defstruct []
  end

  defmodule Sent do
    @moduledoc false
    defstruct [:n]
  end

  defmodule Closed do
    @moduledoc false
    defstruct []
  end

  defmodule Open do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})

    @impl true
    def label(_state, %__MODULE__{}), do: "open step"
  end

  defmodule Send do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})

    @impl true
    def label(_state, %__MODULE__{}), do: "send step"
  end

  defmodule Close do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})

    @impl true
    def label(_state, %__MODULE__{}), do: "close step"
  end

  defmodule Count do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}
    @impl true
    def apply(state, %Sent{}), do: %{state | count: state.count + 1}
    def apply(state, _), do: state

    @check every: 1
    def at_most_one(state, _cmd_or_event) do
      state.count < 2 or PropertyDamage.fail!("two sends", count: state.count)
    end
  end

  defmodule Model do
    @moduledoc false
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model
    @impl true
    def commands, do: [Send]
    @impl true
    def setup_each, do: [Open]
    @impl true
    def teardown_each, do: [Close]
    @impl true
    def command_sequence_projection, do: Count
    @impl true
    def check_projections, do: [Count]
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_command, _state), do: []
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Open{}, _ctx, runtime) do
      PropertyDamage.Runtime.log(runtime, "opened")
      {:ok, [%Opened{}]}
    end

    def execute(%Send{}, _ctx, runtime) do
      PropertyDamage.Runtime.log(runtime, "sent")
      {:ok, [%Sent{n: 1}]}
    end

    def execute(%Close{}, _ctx, runtime) do
      PropertyDamage.Runtime.log(runtime, "closed")
      {:ok, [%Closed{}]}
    end
  end

  @seed 12_345

  @doc "The fixed failing report: seed #{@seed}, one run, no shrinking."
  def failing_report do
    {:error, %PropertyDamage.FailureReport{} = report} =
      PropertyDamage.run(
        model: Model,
        targets: [Adapter],
        seed: @seed,
        max_runs: 1,
        shrink: false
      )

    report
  end
end
