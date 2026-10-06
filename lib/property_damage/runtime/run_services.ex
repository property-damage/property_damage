defmodule PropertyDamage.Runtime.RunServices do
  @moduledoc false
  # Per-run wiring of a target's injector adapters and mock services.
  #
  # A run brings up the injectors and mocks its target declares against that
  # run's event queue, and tears them down when the run ends. The one-target
  # branching path of `PropertyDamage.run/1`, its shrink attempts, and
  # `PropertyDamage.Variant` all do this, so the wiring lives here once and all
  # of them observe the same setup and teardown calls.

  alias PropertyDamage.{EventQueue, MockServiceRegistry}

  @doc false
  # Starts an event queue with the target's injectors and mocks for the linear
  # engine, runs `fun` with the queue and the mock registry, and releases all
  # of them again. The queue's stop is guaranteed by the outer `after`, so a
  # raise in injector or mock setup cannot leak it.
  def with_services(target, fun) do
    {:ok, event_queue} = EventQueue.start_link()

    try do
      setup_injectors(target.injectors, event_queue)
      {mock_registry, mock_contexts} = setup_mocks(target.mocks, event_queue)

      try do
        fun.(event_queue, mock_registry)
      after
        teardown_mocks(mock_registry, mock_contexts)
        teardown_injectors(target.injectors)
      end
    after
      EventQueue.stop(event_queue)
    end
  end

  @doc false
  # Call setup/1 on each injector adapter with the run's event queue.
  def setup_injectors(injectors, event_queue) do
    for adapter <- injectors do
      if exports?(adapter, :setup) do
        adapter.setup(%{event_queue: event_queue})
      end
    end
  end

  @doc false
  def teardown_injectors(injectors) do
    for adapter <- injectors do
      if exports?(adapter, :teardown) do
        adapter.teardown(%{})
      end
    end
  end

  @doc false
  # Start a per-run MockServiceRegistry and bring up each declared mock: register
  # it (init_state/0) and call its setup/1 with the entry's config merged with
  # the framework channels (:registry and :event_queue). Returns the registry pid
  # (or nil when no mocks are declared) plus the per-mock setup contexts, which
  # teardown_mocks/2 later hands back to each mock's teardown/1. Mirrors the event
  # queue's per-run lifecycle.
  def setup_mocks([], _event_queue), do: {nil, []}

  def setup_mocks(mocks, event_queue) do
    {:ok, registry} = MockServiceRegistry.start_link([])

    contexts =
      for {module, config} <- mocks do
        :ok = MockServiceRegistry.register(registry, module)

        context =
          if exports?(module, :setup) do
            case module.setup(Map.merge(config, %{registry: registry, event_queue: event_queue})) do
              {:ok, ctx} -> ctx
              :ok -> %{}
            end
          else
            %{}
          end

        {module, context}
      end

    {registry, contexts}
  end

  @doc false
  # Tear each mock down (best-effort, in reverse setup order) then stop the
  # registry. A nil registry means no mocks were declared, so this is a no-op.
  def teardown_mocks(nil, _contexts), do: :ok

  def teardown_mocks(registry, contexts) do
    for {module, context} <- Enum.reverse(contexts) do
      if exports?(module, :teardown) do
        module.teardown(context)
      end
    end

    MockServiceRegistry.stop(registry)
    :ok
  end

  # `function_exported?/3` does not load the module, so an injector or mock
  # that nothing has called yet would look like it has no callback.
  defp exports?(module, fun),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, 1)
end
