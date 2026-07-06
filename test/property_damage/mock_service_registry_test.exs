defmodule PropertyDamage.MockServiceRegistryTest do
  @moduledoc """
  The registry runs user mock callbacks (`on_command/2`, `on_event/2`) inside its
  own GenServer. A callback that raises, exits, or throws must not take the
  registry down — and, through the `start_link`, the run with it. It is surfaced
  as an error result instead (J13).
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.MockServiceRegistry

  defmodule Cmd do
    defstruct [:tag]
  end

  defmodule Evt do
    defstruct [:tag]
  end

  defmodule RaisingOnCommandMock do
    use PropertyDamage.MockServiceAdapter
    def init_state, do: %{}
    def on_command(_command, _state), do: raise("on_command boom")
    def handle_request(_request, _state), do: {:reply, %{}, []}
  end

  defmodule ExitingOnCommandMock do
    use PropertyDamage.MockServiceAdapter
    def init_state, do: %{}
    def on_command(_command, _state), do: exit(:on_command_boom)
    def handle_request(_request, _state), do: {:reply, %{}, []}
  end

  defmodule RaisingOnEventMock do
    use PropertyDamage.MockServiceAdapter
    def init_state, do: %{}
    def on_command(_command, state), do: state
    def on_event(_event, _state), do: throw(:on_event_boom)
    def handle_request(_request, _state), do: {:reply, %{}, []}
  end

  @tag :capture_log
  test "a raising on_command surfaces an error and leaves the registry alive" do
    {:ok, reg} = MockServiceRegistry.start_link([])
    :ok = MockServiceRegistry.register(reg, RaisingOnCommandMock)

    assert {:error, _reason} = MockServiceRegistry.notify_command(reg, %Cmd{tag: :x})
    assert Process.alive?(reg)

    MockServiceRegistry.stop(reg)
  end

  @tag :capture_log
  test "an exiting on_command surfaces an error and leaves the registry alive" do
    {:ok, reg} = MockServiceRegistry.start_link([])
    :ok = MockServiceRegistry.register(reg, ExitingOnCommandMock)

    assert {:error, _reason} = MockServiceRegistry.notify_command(reg, %Cmd{tag: :x})
    assert Process.alive?(reg)

    MockServiceRegistry.stop(reg)
  end

  @tag :capture_log
  test "a throwing on_event surfaces an error and leaves the registry alive" do
    {:ok, reg} = MockServiceRegistry.start_link([])
    :ok = MockServiceRegistry.register(reg, RaisingOnEventMock)

    assert {:error, _reason} = MockServiceRegistry.notify_event(reg, %Evt{tag: :x})
    assert Process.alive?(reg)

    MockServiceRegistry.stop(reg)
  end
end
