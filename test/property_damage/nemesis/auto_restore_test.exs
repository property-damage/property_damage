defmodule PropertyDamage.Nemesis.AutoRestoreTest do
  @moduledoc """
  Regression for nemesis auto-restore (P1).

  `restore/2` was promised by the behaviour and moduledoc but had zero call
  sites: faults were injected and tracked in `active_faults` but never lifted.
  The executor now (a) lifts any auto-restoring fault whose `duration_ms` has
  elapsed after each command, and (b) restores all still-active faults at
  sequence end.

  The nemeses here record every inject/restore in the executor process's
  dictionary (`Executor.run/4` executes commands synchronously in the caller),
  so the test reads the call log directly. Proven to fail pre-fix: with no
  restore call sites, no `{:restored, _}` is ever recorded.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Executor

  # ---- recording helpers (executor process dictionary) ---------------------
  #
  # inject/2 and restore/2 run synchronously in the test process (Executor.run
  # is a plain function call), so the call log lives in this process's
  # dictionary. The shared key is also written directly by the nemeses below.

  @log_key :auto_restore_log

  defp log_reset, do: Process.put(@log_key, [])
  defp log_get, do: Process.get(@log_key, []) |> Enum.reverse()

  # ---- test nemeses --------------------------------------------------------

  defmodule AutoFault do
    @moduledoc false
    @behaviour PropertyDamage.Nemesis
    # duration_ms 0 => the elapsed sweep lifts it on the very next sweep.
    defstruct duration_ms: 0, tag: :auto

    @impl true
    def precondition(_state), do: true

    @impl true
    def inject(%__MODULE__{tag: tag}, _ctx) do
      Process.put(:auto_restore_log, [{:injected, tag} | Process.get(:auto_restore_log, [])])
      {:ok, []}
    end

    @impl true
    def restore(%__MODULE__{tag: tag}, _ctx) do
      Process.put(:auto_restore_log, [{:restored, tag} | Process.get(:auto_restore_log, [])])
      {:ok, []}
    end

    @impl true
    def auto_restore?, do: true

    @impl true
    def duration_ms(%__MODULE__{duration_ms: d}), do: d
  end

  defmodule ManualFault do
    @moduledoc false
    @behaviour PropertyDamage.Nemesis
    defstruct tag: :manual

    @impl true
    def precondition(_state), do: true

    @impl true
    def inject(%__MODULE__{tag: tag}, _ctx) do
      Process.put(:auto_restore_log, [{:injected, tag} | Process.get(:auto_restore_log, [])])
      {:ok, []}
    end

    @impl true
    def restore(%__MODULE__{tag: tag}, _ctx) do
      Process.put(:auto_restore_log, [{:restored, tag} | Process.get(:auto_restore_log, [])])
      {:ok, []}
    end

    @impl true
    def auto_restore?, do: false
  end

  # ---- model / adapter -----------------------------------------------------

  defmodule NoOp do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Projection do
    @moduledoc false
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _event), do: state
  end

  defmodule Model do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [NoOp]
    @impl true
    def command_sequence_projection, do: Projection
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter
    @impl true
    def setup(_config), do: {:ok, %{}}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%NoOp{}, _ctx), do: {:ok, []}
  end

  defmodule FailAdapter do
    @moduledoc false
    use PropertyDamage.Adapter
    @impl true
    def setup(_config), do: {:ok, %{}}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%NoOp{}, _ctx), do: {:error, :boom}
  end

  setup do
    log_reset()
    :ok
  end

  test "an elapsed auto-restoring fault is lifted mid-sequence" do
    commands = [%AutoFault{duration_ms: 0, tag: :a}, %NoOp{}, %NoOp{}]
    assert {:ok, _result} = Executor.run(commands, Model, Adapter)

    # Injected once, then restored by the elapsed sweep after the nemesis
    # command (duration 0 elapses immediately).
    assert {:injected, :a} in log_get()
    assert {:restored, :a} in log_get()
  end

  test "a long-lived auto-restoring fault is restored at sequence end" do
    # 10 minutes: never elapses during a millisecond-scale run, so only the
    # end-of-sequence restore-all can lift it.
    commands = [%AutoFault{duration_ms: 600_000, tag: :b}, %NoOp{}]
    assert {:ok, _result} = Executor.run(commands, Model, Adapter)

    assert {:injected, :b} in log_get()
    assert {:restored, :b} in log_get(), "restore-all at sequence end did not run"
    # Restored exactly once (not per-command).
    assert Enum.count(log_get(), &(&1 == {:restored, :b})) == 1
  end

  test "the fault is restored even when a later command fails" do
    commands = [%AutoFault{duration_ms: 600_000, tag: :c}, %NoOp{}]
    assert {:ok, %{success: false}} = Executor.run(commands, Model, FailAdapter)

    assert {:restored, :c} in log_get(), "fault leaked when a later command failed"
  end

  test "a non-auto-restoring fault is NOT restored automatically" do
    commands = [%ManualFault{tag: :m}, %NoOp{}, %NoOp{}]
    assert {:ok, _result} = Executor.run(commands, Model, Adapter)

    assert {:injected, :m} in log_get()
    refute {:restored, :m} in log_get()
  end
end
