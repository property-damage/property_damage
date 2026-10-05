defmodule PropertyDamage.Test.VariantSupport do
  @moduledoc false
  # Helpers for the variant, scheduler and multi-target run tests.
  #
  # `PropertyDamage.Variant` and `PropertyDamage.Scheduler` are called on a
  # module name built at runtime, so this file compiles whether or not those
  # modules exist; a missing module surfaces as an `UndefinedFunctionError` in
  # the test that calls it.

  alias PropertyDamage.{Executor, Options, PlaceholderRegistry, Sequence}

  # ==========================================================================
  # Variant and Scheduler entry points
  # ==========================================================================

  def variant_module, do: Module.concat(PropertyDamage, Variant)
  def scheduler_module, do: Module.concat(PropertyDamage, Scheduler)
  def stepping_module, do: Module.concat([PropertyDamage, "Executor", "Stepping"])

  def start_variant(opts), do: variant_module().start_link(opts)
  def setup_variant(pid), do: variant_module().setup(pid)
  def advance_to(pid, boundary), do: variant_module().advance_to(pid, boundary)
  def snapshot(pid), do: variant_module().snapshot(pid)
  def finish(pid), do: variant_module().finish(pid)
  def stop_variant(pid), do: variant_module().stop(pid)

  def run_scheduler(opts), do: scheduler_module().run(opts)

  def stepping(fun, args), do: apply(stepping_module(), fun, args)

  @doc false
  # Options for one variant of a run over `commands`, with its own copy of the
  # placeholder registry built from the shared sequence.
  def variant_opts(target, model, commands, extra \\ []) do
    Keyword.merge(
      [
        target: target,
        model: model,
        commands: commands,
        placeholder_registry: PlaceholderRegistry.build(commands),
        seed: 1,
        run_number: 0,
        run_nonce: 42
      ],
      extra
    )
  end

  @doc false
  # Start a variant and run its setup; returns the variant pid.
  def start_ready_variant(target, model, commands, extra \\ []) do
    {:ok, pid} = start_variant(variant_opts(target, model, commands, extra))
    :ok = setup_variant(pid)
    pid
  end

  @doc false
  # Normalized `%PropertyDamage.Target{}` list for `targets:` entries.
  def targets!(entries) do
    {:ok, targets} = Options.validate_targets(entries)
    targets
  end

  @doc false
  # Run `commands` through the linear engine with the per-run options a
  # one-variant run uses.
  def executor_run(commands, model, adapter, opts) do
    {:ok, result} = Executor.run(Sequence.linear(commands), model, adapter, opts)
    result
  end

  @doc false
  # The comparable content of an event log: where each entry came from, which
  # command it belongs to, and the event itself (timestamps differ per run).
  def entries(event_log), do: Enum.map(event_log, &{&1.source, &1.command_index, &1.event})

  @doc false
  # Events of one source, in log order.
  def events_from(event_log, source) do
    for %{source: ^source, event: event} <- event_log, do: event
  end

  # ==========================================================================
  # Recorder: an append-only log shared by adapters and the test
  # ==========================================================================

  def start_recorder do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    agent
  end

  def record(nil, _entry), do: :ok
  def record(agent, entry), do: Agent.update(agent, &[entry | &1])

  def recorded(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  @doc false
  # Take every message already in the mailbox that is a tuple tagged `tag`, in
  # arrival order, leaving other messages in place.
  def take_messages(tag) do
    receive do
      message when is_tuple(message) and tuple_size(message) > 0 and elem(message, 0) == tag ->
        [message | take_messages(tag)]
    after
      0 -> []
    end
  end

  # ==========================================================================
  # Barrier: proves two variants are inside the same command at once
  # ==========================================================================

  defmodule Barrier do
    @moduledoc false
    # `arrive/3` blocks until `parties` callers arrived with the same key, then
    # returns `:all` to each of them; a caller that waits longer than
    # `timeout_ms` gets `:alone` instead.
    use GenServer

    def start_link(parties), do: GenServer.start_link(__MODULE__, parties)

    def arrive(barrier, key, timeout_ms),
      do: GenServer.call(barrier, {:arrive, key, timeout_ms}, timeout_ms + 5_000)

    @impl true
    def init(parties), do: {:ok, %{parties: parties, waiting: %{}}}

    @impl true
    def handle_call({:arrive, key, timeout_ms}, from, state) do
      waiting = [from | Map.get(state.waiting, key, [])]

      if length(waiting) >= state.parties do
        Enum.each(waiting, &GenServer.reply(&1, :all))
        {:noreply, %{state | waiting: Map.delete(state.waiting, key)}}
      else
        Process.send_after(self(), {:expire, key, from}, timeout_ms)
        {:noreply, %{state | waiting: Map.put(state.waiting, key, waiting)}}
      end
    end

    @impl true
    def handle_info({:expire, key, from}, state) do
      waiting = Map.get(state.waiting, key, [])

      if from in waiting do
        GenServer.reply(from, :alone)
        {:noreply, %{state | waiting: Map.put(state.waiting, key, List.delete(waiting, from))}}
      else
        {:noreply, state}
      end
    end
  end
end
