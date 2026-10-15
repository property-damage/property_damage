defmodule PropertyDamage.SetupCaptureOrderTest do
  @moduledoc """
  An event a setup command injects through `runtime.inject` before it answers
  does not resolve that command's `external()` when the event is not of the
  module the external belongs to.
  """
  use ExUnit.Case, async: true

  defmodule Created do
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Unrelated, do: defstruct([:id])
  defmodule Used, do: defstruct([:id])

  defmodule Create do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Use do
    use PropertyDamage.Command
    defstruct [:id]

    @impl true
    def generator(overrides \\ %{}) do
      %{id: StreamData.constant(nil)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule World do
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{id: nil}

    @impl true
    def apply(state, %Created{id: id}), do: %{state | id: id}
    def apply(state, _item), do: state
  end

  defmodule Simulator do
    @behaviour PropertyDamage.Model.Simulator

    @impl true
    def simulate(%Create{}, _state), do: [%Created{}]
    def simulate(%Use{id: id}, _state), do: [%Used{id: id}]
  end

  defmodule Model do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{Use, overrides: fn state -> %{id: state.id} end}]

    @impl true
    def command_sequence_projection, do: World

    @impl true
    def simulator, do: Simulator

    @impl true
    def setup_each, do: [Create]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Create{}, _ctx, runtime) do
      runtime.inject.(%Unrelated{id: "injected"})
      {:ok, [%Created{id: "created"}]}
    end

    def execute(%Use{id: id}, ctx, _runtime) do
      send(ctx.test_pid, {:used, id})
      {:ok, [%Used{id: id}]}
    end
  end

  test "an injected event of another module does not resolve a setup command's external" do
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: Model,
               targets: [{Adapter, config: %{test_pid: self()}}],
               max_runs: 1,
               max_commands: 1,
               seed: 1,
               validate: false,
               shrink: false
             )

    assert_received {:used, "created"}
  end
end
