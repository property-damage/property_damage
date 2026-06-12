defmodule PropertyDamage.Test.TestAdapter do
  @moduledoc """
  Test adapter implementing all callbacks, with unique per-run item refs.
  """
  use PropertyDamage.Adapter

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem, MinimalCommand}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @impl true
  def setup(config) do
    Process.put({__MODULE__, :item_counter}, 0)
    {:ok, %{config: config}}
  end

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(%CreateItem{name: name, quantity: qty}, _context) do
    counter = Process.get({__MODULE__, :item_counter}, 0)
    Process.put({__MODULE__, :item_counter}, counter + 1)

    event = %ItemCreated{
      item_ref: "item_#{counter}",
      name: name,
      quantity: qty
    }

    {:ok, [event]}
  end

  def execute(%ViewItem{item_ref: ref}, _context) do
    event = %ItemViewed{item_ref: ref}
    {:ok, [event]}
  end

  def execute(%MinimalCommand{}, _context) do
    {:ok, []}
  end
end

defmodule PropertyDamage.Test.DelegatingAdapter do
  @moduledoc """
  Test adapter demonstrating delegation.
  """
  use PropertyDamage.Adapter

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}

  delegate_execution(for: [CreateItem], to: PropertyDamage.Test.ItemSubAdapter)
  delegate_execution(for: [ViewItem], to: PropertyDamage.Test.ViewSubAdapter)

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok
end

defmodule PropertyDamage.Test.ItemSubAdapter do
  @moduledoc """
  Sub-adapter for item creation commands.
  """
  alias PropertyDamage.Test.Events.ItemCreated

  def execute(%{name: name, quantity: qty}, _context) do
    {:ok, [%ItemCreated{item_ref: "delegated_item", name: name, quantity: qty}]}
  end
end

defmodule PropertyDamage.Test.ViewSubAdapter do
  @moduledoc """
  Sub-adapter for view commands.
  """
  alias PropertyDamage.Test.Events.ItemViewed

  def execute(%{item_ref: ref}, _context) do
    {:ok, [%ItemViewed{item_ref: ref}]}
  end
end

defmodule PropertyDamage.Test.FailingAdapter do
  @moduledoc """
  Test adapter that fails on setup or execute.
  """
  use PropertyDamage.Adapter

  @impl true
  def setup(%{fail_setup: true}) do
    {:error, :setup_failed}
  end

  def setup(config) do
    {:ok, config}
  end

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(%{fail: true}, _context) do
    {:error, :execution_failed}
  end

  def execute(_command, _context) do
    {:ok, []}
  end
end
