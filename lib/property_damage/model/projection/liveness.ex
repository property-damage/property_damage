defmodule PropertyDamage.Model.Projection.Liveness do
  @moduledoc """
  Projection that tracks pending operations and asserts progress (liveness).

  Traditional SPBT focuses on **safety properties** - invariants that must never
  be violated. Liveness properties are different: they guarantee that something
  good **eventually** happens.

  ## Safety vs Liveness

  | Property Type | Example | Detection |
  |---------------|---------|-----------|
  | Safety | "Balance never goes negative" | State assertion |
  | Liveness | "Every request eventually completes" | Timeout on pending |

  ## What This Projection Detects

  - **Deadlock** - System hangs forever, no invariant violated
  - **Livelock** - System is busy but makes no useful progress
  - **Starvation** - One client always succeeds, another never does
  - **Infinite retry loops** - System keeps retrying without bound

  ## How It Works

  1. Track commands that start operations (e.g., CreateTransfer)
  2. Track events that complete operations (e.g., TransferCompleted, TransferFailed)
  3. Periodically check for operations pending "too long"
  4. Report stuck operations as liveness violations

  ## Configuration

      defmodule MyModel do
        def assertion_projections do
          [
            {PropertyDamage.Model.Projection.Liveness, [
              max_pending_duration_ms: 10_000,
              required_completions: %{
                CreateTransfer => [TransferCompleted, TransferFailed],
                CreateOrder => [OrderConfirmed, OrderRejected]
              }
            ]}
          ]
        end
      end

  ## Options

  - `:max_pending_duration_ms` - How long before an operation is "stuck" (default: 10_000)
  - `:required_completions` - Map of command module => list of completion event modules
  - `:check_interval` - How often to check (in step count, default: 10)

  ## Limitations

  - Requires wall-clock time, complicating deterministic replay
  - Timeout thresholds are arbitrary
  - Can't detect "infinite but slow progress" (livelock with occasional success)
  """

  @behaviour PropertyDamage.Model.Projection

  defstruct [
    :pending_operations,
    :max_pending_duration_ms,
    :required_completions,
    :check_interval,
    :current_step
  ]

  @type t :: %__MODULE__{
          pending_operations: %{reference() => pending_operation()},
          max_pending_duration_ms: pos_integer(),
          required_completions: %{module() => [module()]},
          check_interval: pos_integer(),
          current_step: non_neg_integer()
        }

  @type pending_operation :: %{
          command_module: module(),
          started_at: integer(),
          command_index: non_neg_integer(),
          expected_completions: [module()]
        }

  @default_max_duration_ms 10_000
  @default_check_interval 10

  @impl PropertyDamage.Model.Projection
  @spec init(keyword()) :: t()
  def init(opts \\ []) do
    %__MODULE__{
      pending_operations: %{},
      max_pending_duration_ms:
        Keyword.get(opts, :max_pending_duration_ms, @default_max_duration_ms),
      required_completions: Keyword.get(opts, :required_completions, %{}),
      check_interval: Keyword.get(opts, :check_interval, @default_check_interval),
      current_step: 0
    }
  end

  @impl PropertyDamage.Model.Projection
  def apply(state, item) do
    case item do
      %{__struct__: module} = cmd when is_map_key(state.required_completions, module) ->
        # Command starts an operation we track
        apply_command(state, cmd)

      %{__struct__: _} = event ->
        # Check if this event completes any pending operation
        apply_event(state, event)

      _ ->
        state
    end
  end

  defp apply_command(state, command) do
    command_module = command.__struct__
    expected = Map.get(state.required_completions, command_module, [])

    # Create a reference for this operation
    op_ref = make_ref()

    pending_op = %{
      command_module: command_module,
      started_at: System.monotonic_time(:millisecond),
      command_index: state.current_step,
      expected_completions: expected
    }

    %{
      state
      | pending_operations: Map.put(state.pending_operations, op_ref, pending_op),
        current_step: state.current_step + 1
    }
  end

  defp apply_event(state, event) do
    event_module = event.__struct__

    # Find and remove operations completed by this event
    completed_refs =
      state.pending_operations
      |> Enum.filter(fn {_ref, op} ->
        event_module in op.expected_completions
      end)
      |> Enum.map(&elem(&1, 0))

    # Remove one completed operation (first match)
    case completed_refs do
      [ref | _] ->
        %{
          state
          | pending_operations: Map.delete(state.pending_operations, ref),
            current_step: state.current_step + 1
        }

      [] ->
        %{state | current_step: state.current_step + 1}
    end
  end

  @doc """
  Check for stuck operations.

  Returns `:ok` if no operations have been pending too long.
  Returns `{:error, reason}` if operations appear stuck.
  """
  @spec check_liveness(t(), map()) :: :ok | {:error, String.t()}
  def check_liveness(state, _ctx \\ %{}) do
    now = System.monotonic_time(:millisecond)

    stuck_operations =
      state.pending_operations
      |> Enum.filter(fn {_ref, op} ->
        elapsed = now - op.started_at
        elapsed > state.max_pending_duration_ms
      end)
      |> Enum.map(fn {_ref, op} ->
        elapsed = now - op.started_at

        %{
          command_module: op.command_module,
          command_index: op.command_index,
          elapsed_ms: elapsed,
          expected_completions: op.expected_completions
        }
      end)

    if Enum.empty?(stuck_operations) do
      :ok
    else
      {:error, format_stuck_operations(stuck_operations)}
    end
  end

  defp format_stuck_operations(stuck) do
    details =
      stuck
      |> Enum.map_join("; ", fn op ->
        "#{inspect(op.command_module)} at index #{op.command_index} " <>
          "(pending #{op.elapsed_ms}ms, expecting one of #{inspect(op.expected_completions)})"
      end)

    "Stuck operations detected: #{details}"
  end

  # ============================================================================
  # Check Registration (for use as assertion projection)
  # ============================================================================

  @doc false
  def __checks__ do
    [
      %{
        name: :no_stuck_operations,
        trigger: :always,
        sample: 1
      }
    ]
  end

  @doc false
  @spec check(:no_stuck_operations, t(), map()) :: :ok | {:error, String.t()}
  def check(:no_stuck_operations, state, ctx) do
    # Only check every check_interval steps to avoid performance overhead
    if rem(ctx.step_count, state.check_interval) == 0 do
      check_liveness(state, ctx)
    else
      :ok
    end
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Get count of currently pending operations.
  """
  @spec pending_count(t()) :: non_neg_integer()
  def pending_count(state) do
    map_size(state.pending_operations)
  end

  @doc """
  Get list of pending operation details.
  """
  @spec pending_operations(t()) :: [pending_operation()]
  def pending_operations(state) do
    Map.values(state.pending_operations)
  end

  @doc """
  Get operations that have been pending longer than the specified milliseconds.
  """
  @spec operations_pending_longer_than(t(), pos_integer()) :: [pending_operation()]
  def operations_pending_longer_than(state, threshold_ms) do
    now = System.monotonic_time(:millisecond)

    state.pending_operations
    |> Map.values()
    |> Enum.filter(fn op ->
      now - op.started_at > threshold_ms
    end)
  end
end
