defmodule PropertyDamage.AdapterTimeoutTest do
  @moduledoc """
  DR-032: command execution in the core Executor is bounded by `adapter.timeout/1`.

  A wedged `execute/3` in an ordinary run used to have no wall-clock bound (only
  the load-test worker enforced `timeout/1`). The timeout now wraps each
  `adapter.execute/3` attempt and surfaces a `CommandTimeoutError` through the
  adapter-error channel rather than hanging.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{CommandTimeoutError, Executor, Sequence}

  defmodule Cmd do
    defstruct [:value]
    def generator(_overrides \\ %{}), do: StreamData.constant(%{value: 1})
  end

  defmodule Ev, do: defstruct([:type])

  defmodule Proj do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{count: 0}
    @impl true
    def apply(state, _event), do: %{state | count: state.count + 1}
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: Proj
    @impl true
    def assertion_projections, do: []
  end

  defmodule SlowAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_user_context), do: :ok

    # A very short per-command wall-clock budget.
    @impl true
    def timeout(_command), do: {50, :milliseconds}

    # ...but execute hangs well past it.
    @impl true
    def execute(_cmd, _user_context, _runtime) do
      Process.sleep(2_000)
      {:ok, [%Ev{type: :done}]}
    end
  end

  defmodule FastAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_user_context), do: :ok

    @impl true
    def timeout(_command), do: {1_000, :milliseconds}

    @impl true
    def execute(_cmd, _user_context, _runtime), do: {:ok, [%Ev{type: :done}]}
  end

  test "a wedged execute/3 produces a CommandTimeoutError instead of hanging" do
    seq = Sequence.linear([%Cmd{value: 1}])

    start = System.monotonic_time(:millisecond)
    {:ok, result} = Executor.run(seq, Model, SlowAdapter)
    elapsed = System.monotonic_time(:millisecond) - start

    refute result.success
    assert {:adapter_error, %CommandTimeoutError{} = err} = result.failure_reason
    assert err.timeout_ms == 50

    # The run returns near the timeout, not the 2s sleep.
    assert elapsed < 1_500, "expected the run to honor the 50ms timeout, took #{elapsed}ms"
  end

  test "a fast adapter is unaffected by the timeout" do
    seq = Sequence.linear([%Cmd{value: 1}])

    {:ok, result} = Executor.run(seq, Model, FastAdapter)

    assert result.success
  end

  # The timeout wraps execute/3 in a Task, which means it runs in a child
  # process. Connection-ownership libraries (Ecto SQL Sandbox, Mox) resolve
  # access through the `$callers` chain that Task.async sets. This proves the
  # run process is reachable in that chain from inside execute/3, so such
  # adapters keep working with no changes (DR-032).
  defmodule CallersAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_user_context), do: :ok

    @impl true
    def execute(_cmd, %{test_pid: pid}, _runtime) do
      send(pid, {:callers, Process.get(:"$callers")})
      {:ok, [%Ev{type: :done}]}
    end
  end

  test "$callers chain reaches the run process from inside execute/3" do
    run_pid = self()
    seq = Sequence.linear([%Cmd{value: 1}])

    {:ok, result} = Executor.run(seq, Model, CallersAdapter, adapter_config: %{test_pid: run_pid})

    assert result.success
    assert_received {:callers, callers}
    assert is_list(callers)

    assert run_pid in callers,
           "the run process must be in $callers so sandbox/Mox ownership resolves cross-process"
  end
end
