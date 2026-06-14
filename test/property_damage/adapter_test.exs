defmodule PropertyDamage.AdapterTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Adapter
  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.{DelegatingAdapter, FailingAdapter, TestAdapter}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  describe "Adapter behaviour" do
    test "compiles with required callbacks" do
      Code.ensure_loaded!(TestAdapter)

      assert function_exported?(TestAdapter, :setup, 1)
      assert function_exported?(TestAdapter, :teardown, 1)
      assert function_exported?(TestAdapter, :execute, 2)
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

      {:ok, events} = TestAdapter.execute(cmd, context)

      assert [%ItemCreated{name: "Widget", quantity: 5}] = events
    end

    test "execute handles multiple command types" do
      {:ok, context} = TestAdapter.setup(%{})

      {:ok, [%ItemCreated{}]} = TestAdapter.execute(%CreateItem{name: "A", quantity: 1}, context)
      {:ok, [%ItemViewed{}]} = TestAdapter.execute(%ViewItem{item_ref: "ref"}, context)
    end
  end

  describe "delegate_execution macro" do
    test "delegates to sub-adapter" do
      {:ok, context} = DelegatingAdapter.setup(%{})
      cmd = %CreateItem{name: "Delegated", quantity: 3}

      {:ok, events} = DelegatingAdapter.execute(cmd, context)

      assert [%ItemCreated{item_ref: "delegated_item", name: "Delegated", quantity: 3}] = events
    end

    test "delegates different commands to different sub-adapters" do
      {:ok, context} = DelegatingAdapter.setup(%{})

      {:ok, [%ItemCreated{}]} =
        DelegatingAdapter.execute(%CreateItem{name: "A", quantity: 1}, context)

      {:ok, [%ItemViewed{}]} = DelegatingAdapter.execute(%ViewItem{item_ref: "ref"}, context)
    end
  end

  describe "error handling" do
    test "setup can return error" do
      result = FailingAdapter.setup(%{fail_setup: true})

      assert result == {:error, :setup_failed}
    end

    test "execute can return error" do
      {:ok, context} = FailingAdapter.setup(%{})
      result = FailingAdapter.execute(%{fail: true}, context)

      assert result == {:error, :execution_failed}
    end
  end

  describe "behaviour info" do
    test "required callbacks are specified" do
      callbacks = Adapter.behaviour_info(:callbacks)

      assert {:setup, 1} in callbacks
      assert {:teardown, 1} in callbacks
      assert {:execute, 2} in callbacks
    end

    test "optional callbacks are declared" do
      optional = Adapter.behaviour_info(:optional_callbacks)

      assert {:register_handler, 2} in optional
    end
  end
end
