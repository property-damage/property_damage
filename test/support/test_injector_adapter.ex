defmodule PropertyDamage.Test.SimpleInjectorAdapter do
  @moduledoc """
  Simple test injector adapter demonstrating basic usage.

  Transforms simple payloads to test events.
  """
  use PropertyDamage.Adapter.Injector

  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @emits [ItemCreated, ItemViewed]

  @impl true
  def setup(config) do
    # Store event_queue for later use
    {:ok, %{event_queue: config[:event_queue], setup_called: true}}
  end

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def to_event(%{type: :item_created, name: name, quantity: qty}) do
    {:ok, %ItemCreated{item_ref: nil, name: name, quantity: qty}}
  end

  def to_event(%{type: :item_viewed, item_ref: ref}) do
    {:ok, %ItemViewed{item_ref: ref}}
  end

  def to_event(%{type: :unknown}), do: :skip

  def to_event(%{type: :invalid}), do: {:error, :invalid_payload}

  def to_event(_), do: :skip
end

defmodule PropertyDamage.Test.RespondingInjectorAdapter do
  @moduledoc """
  Test injector adapter demonstrating respond/2 callback.
  """
  use PropertyDamage.Adapter.Injector

  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @emits [ItemCreated, ItemViewed]

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def to_event(%{type: :item_created, name: name, quantity: qty}) do
    {:ok, %ItemCreated{item_ref: nil, name: name, quantity: qty}}
  end

  def to_event(_), do: :skip

  @impl true
  def respond(%ItemCreated{name: name}, _context) do
    {:ok, %{status: 200, body: "Created: #{name}"}}
  end

  def respond(%ItemViewed{}, _context), do: :none
end

defmodule PropertyDamage.Test.FailingInjectorAdapter do
  @moduledoc """
  Test injector adapter that can fail setup.
  """
  use PropertyDamage.Adapter.Injector

  @emits []

  @impl true
  def setup(%{fail_setup: true}), do: {:error, :setup_failed}
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def to_event(_), do: :skip
end

defmodule PropertyDamage.Test.UnloadedEmitsInjector do
  @moduledoc """
  Injector for the "unloaded module" validation regression test.

  Lives in test/support (so it is compiled to a findable `.beam` on the code
  path, exactly like a real injector adapter) but is referenced only by that one
  test, which purges it before validating. This mirrors the real case: an
  injector passed by name that has not yet been loaded into the VM, which
  `Code.ensure_loaded?` must load before `function_exported?/3` can see `@emits`.
  """
  use PropertyDamage.Adapter.Injector

  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @emits [ItemCreated, ItemViewed]

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def to_event(_payload), do: :skip
end

defmodule PropertyDamage.Test.NoEmitsInjectorAdapter do
  @moduledoc """
  Test injector adapter without @emits attribute.

  Used to test default behavior when @emits is not specified.
  """
  use PropertyDamage.Adapter.Injector

  # No @emits attribute

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def to_event(_), do: :skip
end
