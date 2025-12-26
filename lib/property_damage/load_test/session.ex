defmodule PropertyDamage.LoadTest.Session do
  @moduledoc """
  A single load test session (simulated user).

  Each session:
  1. Generates a command sequence using the model
  2. Executes commands against the SUT via the adapter
  3. Reports metrics after each command
  4. Optionally waits (think time) between commands
  5. Loops: generates new sequences until stopped

  ## Architecture

  Sessions are lightweight GenServers that run independently.
  They report metrics to a shared Metrics collector and can be
  started/stopped by the Runner.

  ## Usage

      {:ok, session} = Session.start_link(
        model: MyModel,
        adapter: HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        metrics: metrics_pid,
        session_id: 1,
        commands_range: {10, 50},
        think_time_range: {100, 500}
      )

      Session.stop(session)
  """

  use GenServer

  require Logger

  alias PropertyDamage.LoadTest.Metrics
  alias PropertyDamage.{Generator, Sequence}

  defstruct [
    :model,
    :adapter,
    :adapter_config,
    :metrics,
    :session_id,
    :commands_range,
    :think_time_range,
    :rate_limiter,
    :running,
    :commands_executed,
    :sequences_completed,
    :errors
  ]

  @type t :: %__MODULE__{}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a new session.

  ## Options

  - `:model` - Model module (required)
  - `:adapter` - Adapter module (required)
  - `:adapter_config` - Adapter configuration (default: %{})
  - `:metrics` - Metrics collector pid (required)
  - `:session_id` - Unique session ID (required)
  - `:commands_range` - {min, max} commands per sequence (default: {10, 50})
  - `:think_time_range` - {min, max} ms between commands (default: {0, 0})
  - `:rate_limiter` - Optional rate limiter pid
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stop a session gracefully.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @doc """
  Get session statistics.
  """
  @spec stats(pid()) :: map()
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    metrics = Keyword.fetch!(opts, :metrics)
    session_id = Keyword.fetch!(opts, :session_id)
    commands_range = Keyword.get(opts, :commands_range, {10, 50})
    think_time_range = Keyword.get(opts, :think_time_range, {0, 0})
    rate_limiter = Keyword.get(opts, :rate_limiter)

    state = %__MODULE__{
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      metrics: metrics,
      session_id: session_id,
      commands_range: commands_range,
      think_time_range: think_time_range,
      rate_limiter: rate_limiter,
      running: true,
      commands_executed: 0,
      sequences_completed: 0,
      errors: 0
    }

    # Notify metrics that session started
    Metrics.session_started(metrics)

    # Start the execution loop
    send(self(), :run_sequence)

    {:ok, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Metrics.session_completed(state.metrics)
    {:stop, :normal, :ok, %{state | running: false}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      session_id: state.session_id,
      commands_executed: state.commands_executed,
      sequences_completed: state.sequences_completed,
      errors: state.errors,
      running: state.running
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:run_sequence, %{running: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_sequence, state) do
    case run_one_sequence(state) do
      {:ok, new_state} ->
        # Schedule next sequence immediately
        send(self(), :run_sequence)
        {:noreply, new_state}

      {:error, reason, new_state} ->
        Logger.warning("Session #{state.session_id} sequence error: #{inspect(reason)}")
        # Continue despite errors
        send(self(), :run_sequence)
        {:noreply, new_state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.running do
      Metrics.session_completed(state.metrics)
    end

    :ok
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp run_one_sequence(state) do
    {min_commands, max_commands} = state.commands_range
    num_commands = :rand.uniform(max_commands - min_commands + 1) + min_commands - 1

    # Generate sequence
    generator = Generator.generate_sequence(state.model, max_commands: num_commands)

    sequence =
      case Enumerable.reduce(generator, {:cont, nil}, fn val, _ -> {:halt, val} end) do
        {:halted, value} -> value
        {:done, _} -> Sequence.linear([])
      end

    # Execute sequence with metrics collection
    case execute_sequence_with_metrics(sequence, state) do
      {:ok, commands_run, errors} ->
        new_state = %{
          state
          | commands_executed: state.commands_executed + commands_run,
            sequences_completed: state.sequences_completed + 1,
            errors: state.errors + errors
        }

        {:ok, new_state}

      {:error, reason} ->
        new_state = %{state | errors: state.errors + 1}
        {:error, reason, new_state}
    end
  end

  defp execute_sequence_with_metrics(sequence, state) do
    commands = Sequence.to_list(sequence)

    # Setup adapter once for the sequence
    case state.adapter.setup(state.adapter_config) do
      {:ok, adapter_context} ->
        try do
          execute_commands(commands, adapter_context, state, 0, 0)
        after
          state.adapter.teardown(adapter_context)
        end

      {:error, reason} ->
        {:error, {:adapter_setup_failed, reason}}
    end
  end

  defp execute_commands([], _adapter_context, _state, commands_run, errors) do
    {:ok, commands_run, errors}
  end

  defp execute_commands([command | rest], adapter_context, state, commands_run, errors) do
    # Apply think time
    maybe_think(state.think_time_range)

    # Apply rate limiting
    maybe_rate_limit(state.rate_limiter)

    # Execute command and measure latency
    command_module = command.__struct__
    start_time = System.monotonic_time(:microsecond)

    {result, error_delta} =
      case execute_single_command(command, state.adapter, adapter_context) do
        {:ok, _events} ->
          {:ok, 0}

        {:error, reason} ->
          {{:error, categorize_error(reason)}, 1}
      end

    end_time = System.monotonic_time(:microsecond)
    latency_ms = (end_time - start_time) / 1000.0

    # Report metrics
    Metrics.record_request(state.metrics, command_module, latency_ms, result)

    # Continue with remaining commands
    execute_commands(rest, adapter_context, state, commands_run + 1, errors + error_delta)
  end

  defp execute_single_command(command, adapter, adapter_context) do
    # Resolve refs - for load testing we use simple placeholder resolution
    resolved_command = resolve_refs_for_load_test(command)

    adapter.execute(resolved_command, adapter_context)
  end

  defp resolve_refs_for_load_test(command) do
    # For load testing, we generate fresh values for refs
    # This is a simplification - each sequence is independent
    command
    |> Map.from_struct()
    |> Enum.map(fn {k, v} ->
      case v do
        %PropertyDamage.Ref{} ->
          # Generate a placeholder value
          {k, generate_placeholder_value(k)}

        other ->
          {k, other}
      end
    end)
    |> Map.new()
    |> then(&struct(command.__struct__, &1))
  end

  defp generate_placeholder_value(field_name) do
    # Generate appropriate placeholder based on field name conventions
    case to_string(field_name) do
      name when name in ["id", "account_id", "user_id", "booking_id"] ->
        "load_test_#{:rand.uniform(1_000_000)}"

      _ ->
        "placeholder_#{:rand.uniform(1_000_000)}"
    end
  end

  defp maybe_think({0, 0}), do: :ok

  defp maybe_think({min_ms, max_ms}) do
    think_time = :rand.uniform(max_ms - min_ms + 1) + min_ms - 1
    Process.sleep(think_time)
  end

  defp maybe_rate_limit(nil), do: :ok

  defp maybe_rate_limit(rate_limiter) do
    # Simple token bucket rate limiting
    GenServer.call(rate_limiter, :acquire)
  end

  defp categorize_error({:adapter_error, _}), do: :adapter_error
  defp categorize_error({:timeout, _}), do: :timeout
  defp categorize_error({:connection_refused, _}), do: :connection_error
  defp categorize_error(_), do: :unknown_error
end
