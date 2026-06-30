defmodule PropertyDamage.AdapterTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Adapter
  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.{DelegatingAdapter, FailingAdapter, TestAdapter}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  # A trivial Runtime handle for exercising execute/3 directly (DR-027). These
  # adapters don't inject or poll, so the closures are never called.
  defp runtime do
    %PropertyDamage.Runtime{inject: fn _ -> :ok end, start_poller: fn _ -> nil end}
  end

  describe "Adapter behaviour" do
    test "compiles with required callbacks" do
      Code.ensure_loaded!(TestAdapter)

      assert function_exported?(TestAdapter, :setup, 1)
      assert function_exported?(TestAdapter, :teardown, 1)
      assert function_exported?(TestAdapter, :execute, 3)
    end

    test "setup returns {:ok, context}" do
      {:ok, context} = TestAdapter.setup(%{test: true})

      assert is_map(context)
      assert context.config == %{test: true}
    end

    test "teardown returns :ok" do
      {:ok, context} = TestAdapter.setup(%{})
      result = TestAdapter.teardown(context)

      assert result == :ok
    end

    test "execute returns {:ok, events}" do
      {:ok, context} = TestAdapter.setup(%{})
      cmd = %CreateItem{name: "Widget", quantity: 5}

      {:ok, events} = TestAdapter.execute(cmd, context, runtime())

      assert [%ItemCreated{name: "Widget", quantity: 5}] = events
    end

    test "execute handles multiple command types" do
      {:ok, context} = TestAdapter.setup(%{})

      {:ok, [%ItemCreated{}]} =
        TestAdapter.execute(%CreateItem{name: "A", quantity: 1}, context, runtime())

      {:ok, [%ItemViewed{}]} = TestAdapter.execute(%ViewItem{item_ref: "ref"}, context, runtime())
    end
  end

  describe "delegate_execution macro" do
    test "delegates to sub-adapter" do
      {:ok, context} = DelegatingAdapter.setup(%{})
      cmd = %CreateItem{name: "Delegated", quantity: 3}

      {:ok, events} = DelegatingAdapter.execute(cmd, context, runtime())

      assert [%ItemCreated{item_ref: "delegated_item", name: "Delegated", quantity: 3}] = events
    end

    test "delegates different commands to different sub-adapters" do
      {:ok, context} = DelegatingAdapter.setup(%{})

      {:ok, [%ItemCreated{}]} =
        DelegatingAdapter.execute(%CreateItem{name: "A", quantity: 1}, context, runtime())

      {:ok, [%ItemViewed{}]} =
        DelegatingAdapter.execute(%ViewItem{item_ref: "ref"}, context, runtime())
    end
  end

  describe "error handling" do
    test "setup can return error" do
      result = FailingAdapter.setup(%{fail_setup: true})

      assert result == {:error, :setup_failed}
    end

    test "execute can return error" do
      {:ok, context} = FailingAdapter.setup(%{})
      result = FailingAdapter.execute(%{fail: true}, context, runtime())

      assert result == {:error, :execution_failed}
    end
  end

  describe "behaviour info" do
    test "required callbacks are specified" do
      callbacks = Adapter.behaviour_info(:callbacks)

      assert {:setup, 1} in callbacks
      assert {:teardown, 1} in callbacks
      # execute/3 (command, user_context, runtime) per DR-027; execute/2 is gone.
      assert {:execute, 3} in callbacks
      refute {:execute, 2} in callbacks
    end

    test "register_handler is no longer a callback (DR-027/DR-030)" do
      # The capability moved to the semantic surface (Command.awaits/2). The
      # adapter behaviour no longer declares register_handler at all.
      callbacks = Adapter.behaviour_info(:callbacks)
      refute {:register_handler, 2} in callbacks
      assert Adapter.behaviour_info(:optional_callbacks) == []
    end
  end
end
