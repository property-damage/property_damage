defmodule PropertyDamage.IExTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PropertyDamage.IEx

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.Events.ItemCreated
  alias PropertyDamage.Test.ExecutorModel
  alias PropertyDamage.Test.Projections.ModelState
  alias PropertyDamage.Test.SimpleModel

  # `IEx.debug_command/3` consumes `adapter.execute/2` results as `{:ok,
  # events}` (the contract's event list; a bare struct is also tolerated) or
  # `{:error, reason}`. These local adapters cover the single-struct/error/
  # setup-failure branches; a separate test exercises the conforming
  # `{:ok, [events]}` list shape via `PropertyDamage.Test.SimpleAdapter`.
  defmodule SingleEventAdapter do
    @moduledoc false
    def setup(opts), do: {:ok, Map.new(opts)}
    def teardown(_context), do: :ok

    def execute(%CreateItem{name: name, quantity: qty}, _context, _runtime) do
      {:ok, %ItemCreated{item_ref: "item_0", name: name, quantity: qty}}
    end
  end

  defmodule ErrorReturningAdapter do
    @moduledoc false
    def setup(opts), do: {:ok, Map.new(opts)}
    def teardown(_context), do: :ok
    def execute(_command, _context, _runtime), do: {:error, :boom}
  end

  defmodule SetupFailingAdapter do
    @moduledoc false
    def setup(_opts), do: {:error, :no_connection}
    def teardown(_context), do: :ok
    def execute(_command, _context, _runtime), do: {:ok, %ItemCreated{}}
  end

  defmodule EmptyModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: []

    @impl true
    def command_sequence_projection, do: ModelState
  end

  describe "explain/1" do
    test "does not crash on a model with zero commands (I3)" do
      output = capture_io(fn -> assert IEx.explain(EmptyModel) == :ok end)

      assert output =~ "COMMANDS (0 total)"
    end

    test "prints model name, command table, and projections; returns :ok" do
      output = capture_io(fn -> assert IEx.explain(ExecutorModel) == :ok end)

      # Header carries the inspected module name.
      assert output =~ "ExecutorModel"

      # Command table section with both commands listed.
      assert output =~ "COMMANDS (2 total)"
      assert output =~ "Weight"
      assert output =~ "CreateItem"
      assert output =~ "ViewItem"

      # Projections section lists the command-sequence projection and extras.
      assert output =~ "PROJECTIONS"
      assert output =~ "ModelState"
      assert output =~ "TestAssertions"
    end

    test "reports (none) for a model without assertion projections" do
      output = capture_io(fn -> assert IEx.explain(SimpleModel) == :ok end)

      assert output =~ "PROJECTIONS"
      assert output =~ "(none)"
    end
  end

  describe "dry_run/2" do
    test "prints a generated sequence with a reproducible seed; returns :ok" do
      output =
        capture_io(fn ->
          assert IEx.dry_run(ExecutorModel, commands: 5, seed: 12_345) == :ok
        end)

      assert output =~ "Generated sequence"
      assert output =~ "Seed: 12345 (use this to reproduce)"
    end

    test "is deterministic for a fixed seed" do
      run = fn -> capture_io(fn -> IEx.dry_run(ExecutorModel, commands: 5, seed: 999) end) end

      assert run.() == run.()
    end

    test "verbose mode expands command fields" do
      output =
        capture_io(fn ->
          assert IEx.dry_run(ExecutorModel, commands: 3, seed: 7, verbose: true) == :ok
        end)

      assert output =~ "Generated sequence"
      assert output =~ "Seed: 7"
    end

    test "works with default options (no seed given)" do
      output = capture_io(fn -> assert IEx.dry_run(SimpleModel) == :ok end)

      assert output =~ "Generated sequence"
      assert output =~ "Seed:"
    end
  end

  describe "debug_command/3" do
    test "executes a command and prints status and result event; returns :ok" do
      command = %CreateItem{name: "widget", quantity: 3}

      output =
        capture_io(fn ->
          assert IEx.debug_command(command, SingleEventAdapter) == :ok
        end)

      assert output =~ "COMMAND EXECUTION"
      assert output =~ "CreateItem"
      assert output =~ "name:"
      assert output =~ "Status: OK"
      assert output =~ "RESULT EVENT"
      assert output =~ "ItemCreated"
    end

    test "shows ref resolution annotation when refs are supplied" do
      command = %CreateItem{name: :ref0, quantity: 1}

      output =
        capture_io(fn ->
          assert IEx.debug_command(command, SingleEventAdapter, refs: %{ref0: "resolved_name"}) ==
                   :ok
        end)

      # The COMMAND section annotates the resolved ref value, and the adapter
      # received the resolved struct (name => "resolved_name").
      assert output =~ "resolved_name"
    end

    test "prints ERROR status when the adapter returns an error" do
      command = %CreateItem{name: "widget", quantity: 1}

      output =
        capture_io(fn ->
          assert IEx.debug_command(command, ErrorReturningAdapter) == :ok
        end)

      assert output =~ "Status: ERROR"
      assert output =~ "Reason: :boom"
    end

    test "returns {:error, {:setup_failed, reason}} when adapter setup fails" do
      command = %CreateItem{name: "widget", quantity: 1}

      output =
        capture_io(fn ->
          assert IEx.debug_command(command, SetupFailingAdapter) ==
                   {:error, {:setup_failed, :no_connection}}
        end)

      assert output =~ "ADAPTER SETUP FAILED"
      assert output =~ ":no_connection"
    end

    test "handles the {:ok, [events]} list contract of a conforming adapter" do
      command = %CreateItem{name: "widget", quantity: 3}

      output =
        capture_io(fn ->
          assert IEx.debug_command(command, PropertyDamage.Test.SimpleAdapter) == :ok
        end)

      assert output =~ "Status: OK"
      assert output =~ "RESULT EVENT"
      assert output =~ "ItemCreated"
    end
  end

  describe "inspect_state/2" do
    test "applies events through a projection and prints final state; returns :ok" do
      events = [
        %ItemCreated{item_ref: "item_0", name: "a", quantity: 1},
        %ItemCreated{item_ref: "item_1", name: "b", quantity: 2}
      ]

      output =
        capture_io(fn ->
          assert IEx.inspect_state(events, ModelState) == :ok
        end)

      assert output =~ "STATE AFTER 2 EVENTS"
      # ModelState tracks created items keyed by ref.
      assert output =~ "item_0"
      assert output =~ "item_1"
    end

    test "handles an empty event list" do
      output =
        capture_io(fn ->
          assert IEx.inspect_state([], ModelState) == :ok
        end)

      assert output =~ "STATE AFTER 0 EVENTS"
    end
  end

  describe "check_preconditions/2" do
    test "marks commands valid/invalid for a given state; returns :ok" do
      # Empty state: ViewItem's `when:` (items must exist) is false,
      # CreateItem's default precondition is true.
      empty_state = %{items: %{}, view_count: 0}

      output =
        capture_io(fn ->
          assert IEx.check_preconditions(empty_state, ExecutorModel) == :ok
        end)

      assert output =~ "PRECONDITION CHECK"
      assert output =~ "CreateItem"
      assert output =~ "ViewItem"
      assert output =~ "VALID"
      assert output =~ "INVALID"
      assert output =~ "1/2 commands valid in current state"
    end

    test "all commands valid when state satisfies every precondition" do
      state = %{items: %{"item_0" => %{name: "a", quantity: 1}}, view_count: 0}

      output =
        capture_io(fn ->
          assert IEx.check_preconditions(state, ExecutorModel) == :ok
        end)

      assert output =~ "2/2 commands valid in current state"
    end
  end
end
