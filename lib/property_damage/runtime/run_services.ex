defmodule PropertyDamage.Runtime.RunServices do
  @moduledoc false
  # Per-run wiring of a target's injector adapters and mock services.
  #
  # A run brings up the injectors and mocks its target declares against that
  # run's event queue, and tears them down when the run ends. The one-target
  # branching path of `PropertyDamage.run/1`, its shrink attempts, and
  # `PropertyDamage.Variant` all do this, so the wiring lives here once and all
  # of them observe the same setup and teardown calls.

  alias PropertyDamage.{EventQueue, Log, MockServiceRegistry}

  @doc false
  # Starts an event queue with the target's injectors and mocks for the linear
  # engine, runs `fun` with the queue and the mock registry, and releases all
  # of them again. The queue's stop is guaranteed by the outer `after`, so a
  # raise in injector or mock setup cannot leak it; the injectors are torn
  # down even when a mock setup or `fun` raises. An injector setup that fails
  # or raises returns `{:error, reason}` without calling `fun`, the shape
  # `PropertyDamage.Executor.run/4` gives when the adapter's setup fails.
  #
  # Injector and mock setup and teardown are execution points (DR-054). When
  # `fun` returns `{:ok, result}` with a `logs` map, the lines their setup
  # wrote go before the adapter's own under `:adapter_setup`, and the lines
  # their teardown wrote after them under `:adapter_teardown`; any other
  # result drops them.
  def with_services(target, fun) do
    {:ok, event_queue} = EventQueue.start_link()

    try do
      {set_up, setup_lines} =
        Log.inline(fn -> setup_injectors(target.injectors, target.config, event_queue) end)

      case set_up do
        {:ok, injector_contexts} ->
          with_injectors(target, injector_contexts, event_queue, setup_lines, fun)

        {:error, reason} ->
          {:error, reason}
      end
    after
      EventQueue.stop(event_queue)
    end
  end

  defp with_injectors(target, injector_contexts, event_queue, setup_lines, fun) do
    {{mock_registry, mock_contexts}, mock_lines} =
      try do
        Log.inline(fn -> setup_mocks(target.mocks, event_queue) end)
      catch
        kind, reason ->
          Log.inline(fn -> teardown_injectors(injector_contexts) end)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    tear_down = fn ->
      Log.inline(fn ->
        try do
          teardown_mocks(mock_registry, mock_contexts)
        after
          teardown_injectors(injector_contexts)
        end
      end)
    end

    result =
      try do
        fun.(event_queue, mock_registry)
      catch
        kind, reason ->
          tear_down.()
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    {_torn_down, teardown_lines} = tear_down.()
    with_service_lines(result, setup_lines ++ mock_lines, teardown_lines)
  end

  defp with_service_lines({:ok, %{logs: logs} = result}, setup_lines, teardown_lines) do
    logs =
      logs
      |> Map.update(:adapter_setup, setup_lines, &(setup_lines ++ &1))
      |> Log.append(:adapter_teardown, teardown_lines)
      |> Map.reject(fn {_key, lines} -> lines == [] end)

    {:ok, %{result | logs: logs}}
  end

  defp with_service_lines(result, _setup_lines, _teardown_lines), do: result

  @doc false
  # Call setup/1 on each injector with the target's config merged with the
  # run's event queue (the framework key wins). Returns the per-injector setup
  # contexts, which teardown_injectors/1 later hands back to each injector's
  # teardown/1; an injector without setup/1 gets `%{}`. The first setup that
  # answers `{:error, reason}`, anything but `{:ok, map}`, or raises, stops
  # the setup: the injectors already set up are torn down and the error is
  # returned, a raise as the exception itself.
  def setup_injectors(injectors, config, event_queue) do
    injector_config = Map.merge(config, %{event_queue: event_queue})

    Enum.reduce_while(injectors, {:ok, []}, fn module, {:ok, contexts} ->
      case setup_injector(module, injector_config) do
        {:ok, context} ->
          {:cont, {:ok, contexts ++ [{module, context}]}}

        {:error, reason} ->
          teardown_injectors(contexts)
          {:halt, {:error, reason}}
      end
    end)
  end

  defp setup_injector(module, config) do
    if exports?(module, :setup) do
      case module.setup(config) do
        {:ok, context} when is_map(context) -> {:ok, context}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_injector_setup_return, module, other}}
      end
    else
      {:ok, %{}}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  # Call teardown/1 on each injector with the context its setup/1 returned,
  # in setup order.
  def teardown_injectors(contexts) do
    for {module, context} <- contexts do
      if exports?(module, :teardown) do
        module.teardown(context)
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
