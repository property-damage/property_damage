defmodule PropertyDamage.StepRunParityTest do
  @moduledoc """
  `PropertyDamage.Test.StepRun.run/4` answers what `Executor.run/4` answers,
  field by field, for a table of runs that covers each phase of a one-target
  run.

  Fields compared: every key of the `{:ok, result}` map. Fields normalized
  before comparing:

    * `event_log[].timestamp` is a monotonic clock reading taken per run.
    * `check_failures[].timestamp` is a monotonic clock reading, and
      `check_failures[].reason` carries a stacktrace through the caller's
      frames; its exception is compared.
    * `stacktrace` holds frames of the calling module, which differ between the
      two entry points; its first frame (the adapter's own) is compared instead.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{EventQueue, Executor, Sequence}

  alias PropertyDamage.Test.{
    ErrorAdapter,
    ExecutorModel,
    FailingAdapter,
    FailingModel,
    SetupCommands,
    SimpleAdapter,
    SimpleInjectorAdapter
  }

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Events.ItemViewed
  alias PropertyDamage.Test.SetupCommands.{Act, Cleanup, CreateUser, FixtureAdapter}
  alias PropertyDamage.Test.StepRun

  @model PropertyDamage.Test.StepRunParityModel

  defmodule RaisingAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_command, _ctx, _runtime), do: raise("adapter boom")
  end

  setup_all do
    SetupCommands.define_model!(@model)
    :ok
  end

  defp normalize({:ok, result}), do: {:ok, normalize(result)}

  defp normalize(%{event_log: log} = result) do
    result
    |> Map.put(:event_log, Enum.map(log, &%{&1 | timestamp: nil}))
    |> Map.update(:check_failures, nil, &normalize_check_failures/1)
    |> Map.update(:stacktrace, nil, fn
      nil -> nil
      [first | _] -> first
    end)
  end

  defp normalize(other), do: other

  defp normalize_check_failures(nil), do: nil

  defp normalize_check_failures(failures) do
    Enum.map(failures, fn failure ->
      failure
      |> Map.put(:timestamp, nil)
      |> Map.update(:reason, nil, fn
        {exception, _stacktrace} -> exception
        reason -> reason
      end)
    end)
  end

  # Runs `commands` both ways and asserts the two answers equal, key by key.
  defp assert_parity(commands, model, adapter, opts \\ []) do
    old = Executor.run(commands, model, adapter, opts)
    new = StepRun.run(commands, model, adapter, opts)

    case {normalize(old), normalize(new)} do
      {{:ok, old_result}, {:ok, new_result}} ->
        assert Map.keys(old_result) == Map.keys(new_result)

        for key <- Map.keys(old_result) do
          assert {key, Map.fetch!(new_result, key)} == {key, Map.fetch!(old_result, key)}
        end

      {old_answer, new_answer} ->
        assert new_answer == old_answer
    end

    {old, new}
  end

  test "a passing run" do
    {{:ok, old}, _new} =
      assert_parity(
        [%CreateItem{name: "A", quantity: 1}, %ViewItem{item_ref: "item_0"}],
        ExecutorModel,
        SimpleAdapter
      )

    assert old.success
    assert length(old.event_log) == 2
  end

  test "a failing step" do
    {{:ok, old}, _new} = assert_parity([%{fail: true}], ExecutorModel, ErrorAdapter)

    refute old.success
    assert old.failed_at_index == 0
  end

  test "a failing check" do
    {{:ok, old}, _new} =
      assert_parity([%CreateItem{name: "Huge", quantity: 150}], FailingModel, SimpleAdapter)

    refute old.success
    assert old.failed_at_index == 0
  end

  test "failing checks recorded in record mode" do
    commands = [
      %CreateItem{name: "A", quantity: 101},
      %CreateItem{name: "B", quantity: 60}
    ]

    {{:ok, old}, _new} =
      assert_parity(commands, FailingModel, SimpleAdapter, check_mode: :record)

    assert length(old.check_failures) >= 2
  end

  test "a setup command that fails" do
    config = %{name: "a", fail: %{CreateUser => :error}}

    {{:ok, old}, _new} =
      assert_parity([%Act{n: 0}], @model, FixtureAdapter,
        config: config,
        setup_commands: [%CreateUser{name: "fixture"}],
        teardown_commands: [%Cleanup{thing_id: "t"}]
      )

    refute old.success
    assert old.failed_at_index == nil
  end

  test "setup and teardown commands around a passing sequence" do
    {{:ok, old}, _new} =
      assert_parity([%Act{n: 0}], @model, FixtureAdapter,
        config: %{name: "a"},
        setup_commands: [%CreateUser{name: "fixture"}],
        teardown_commands: [%Cleanup{thing_id: "t"}]
      )

    assert old.success
    assert Enum.any?(old.event_log, &(&1.phase == :teardown))
    assert Enum.any?(old.event_log, &(&1.phase == :setup))
  end

  test "an adapter whose setup/1 fails" do
    {old, new} = assert_parity([%{}], ExecutorModel, FailingAdapter, config: %{fail_setup: true})

    assert old == {:error, :setup_failed}
    assert new == old
  end

  test "an adapter that raises" do
    {{:ok, old}, _new} =
      assert_parity([%CreateItem{name: "A", quantity: 1}], ExecutorModel, RaisingAdapter)

    refute old.success
    assert old.failed_at_index == 0
  end

  test "an event queue holding an injected event" do
    {:ok, old_queue} = EventQueue.start_link()
    {:ok, new_queue} = EventQueue.start_link()
    event = %ItemViewed{item_ref: "injected"}
    command = %CreateItem{name: "Test", quantity: 5}

    EventQueue.push(old_queue, SimpleInjectorAdapter, event)
    EventQueue.push(new_queue, SimpleInjectorAdapter, event)

    old =
      Executor.run(Sequence.linear([command]), ExecutorModel, SimpleAdapter,
        event_queue: old_queue
      )

    new =
      StepRun.run(Sequence.linear([command]), ExecutorModel, SimpleAdapter,
        event_queue: new_queue
      )

    EventQueue.stop(old_queue)
    EventQueue.stop(new_queue)

    assert normalize(new) == normalize(old)
    assert {:ok, %{event_log: log}} = old
    assert Enum.any?(log, &(&1.source == :injector))
  end

  test "an empty sequence" do
    {{:ok, old}, _new} = assert_parity([], ExecutorModel, SimpleAdapter)

    assert old.success
  end
end
