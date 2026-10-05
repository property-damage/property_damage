defmodule PropertyDamage.Test.LazyInjector do
  @moduledoc false
  # An injector that only the scheduler lifecycle test names, and only as a
  # module atom, so it is not loaded when that test hands it to a run. It
  # delivers one Noted event as soon as it is set up.
  use PropertyDamage.Adapter.Injector

  alias PropertyDamage.EventQueue
  alias PropertyDamage.Test.Lockstep.Noted

  @emits [Noted]

  @impl true
  def setup(%{event_queue: queue} = config) do
    EventQueue.push(queue, __MODULE__, %Noted{value: :lazy})
    {:ok, config}
  end

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def to_event(payload), do: {:ok, payload}
end
