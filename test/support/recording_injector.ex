defmodule PropertyDamage.Test.RecordingInjector do
  @moduledoc false
  # An injector that reports what the framework hands it. Its setup/1 sends
  # {:injector_setup, config, context} to the config's `:test_pid` and returns
  # a context holding a fresh reference. Its teardown/1 sends
  # {:injector_teardown, context} to the `:test_pid` in that context, so a test
  # can match each teardown to the setup that produced its context. Without a
  # `:test_pid` it sends nothing.
  use PropertyDamage.Adapter.Injector

  @emits []

  @impl true
  def setup(config) do
    context = %{test_pid: config[:test_pid], tenant: config[:tenant], listener: make_ref()}
    notify(config[:test_pid], {:injector_setup, config, context})
    {:ok, context}
  end

  @impl true
  def teardown(context) do
    notify(context[:test_pid], {:injector_teardown, context})
    :ok
  end

  @impl true
  def to_event(_payload), do: :skip

  defp notify(nil, _message), do: :ok
  defp notify(pid, message), do: send(pid, message)
end

defmodule PropertyDamage.Test.RefusingInjector do
  @moduledoc false
  # An injector whose setup/1 returns the config's `:injector_reply` as is, for
  # example a value the contract does not allow, and {:error, :no_listener}
  # when the config sets none.
  use PropertyDamage.Adapter.Injector

  @emits []

  @impl true
  def setup(config), do: Map.get(config, :injector_reply, {:error, :no_listener})

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def to_event(_payload), do: :skip
end
