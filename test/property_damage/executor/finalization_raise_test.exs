defmodule PropertyDamage.Executor.FinalizationRaiseTest do
  @moduledoc """
  A raise during finalization (here a projection rejecting an event a
  resource poller delivers after the last command) still runs the teardown
  commands, then `teardown/1`, and the raise propagates.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{EventQueue, Executor, ProjectionError, Sequence}

  defmodule Late, do: defstruct([])

  defmodule Start do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Release do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Rejecting do
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(_state, %Late{}), do: raise("late event rejected")
    def apply(state, _other), do: state
  end

  defmodule Model do
    use PropertyDamage.Model

    @impl true
    def commands, do: [Start]

    @impl true
    def command_sequence_projection, do: Rejecting
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(context) do
      send(context.test_pid, :teardown)
      :ok
    end

    # The poller delivers `Late` well after the step has drained its events
    # (finalization awaits every resource poller), so the settle drain of
    # finalization folds it, even when a loaded machine slows the step.
    @impl true
    def execute(%Start{}, _context, runtime) do
      runtime.start_poller.(
        poll_fn: fn ->
          Process.sleep(200)
          :tick
        end,
        handler: fn _ -> {:done, [%Late{}]} end,
        interval_ms: 5,
        timeout_ms: 1_000
      )

      {:ok, []}
    end

    def execute(%Release{}, context, _runtime) do
      send(context.test_pid, {:execute, Release})
      {:ok, []}
    end
  end

  test "a raise during finalization runs the teardown commands before teardown/1" do
    {:ok, queue} = EventQueue.start_link()

    assert_raise ProjectionError, fn ->
      Executor.run(Sequence.linear([%Start{}]), Model, Adapter,
        config: %{test_pid: self()},
        event_queue: queue,
        teardown_commands: [%Release{}]
      )
    end

    assert {:messages, [{:execute, Release}, :teardown]} = Process.info(self(), :messages)
  end
end
