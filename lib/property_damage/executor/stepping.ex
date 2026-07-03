defmodule PropertyDamage.Executor.Stepping do
  @moduledoc """
  The supported interface for executing a command sequence *one command at a
  time* against a live System Under Test.

  A full run (`PropertyDamage.run/1`) drives the whole sequence internally. Some
  callers instead need to advance a sequence step by step while inspecting state
  between commands: `PropertyDamage.Replay` walks a shrunk failure command by
  command so a human can watch it reproduce. This module is that seam.

  ## Lifecycle

  The caller owns setup and teardown; stepping only advances execution:

      # 1. caller sets up the adapter and (if needed) an event queue
      {:ok, adapter_context} = MyAdapter.setup(config)
      {:ok, event_queue} = PropertyDamage.EventQueue.start_link()

      # 2. build a fresh executor state and a per-run context
      state = Stepping.init_state(MyModel, event_queue: event_queue)
      ctx = %Stepping.Context{
        model: MyModel,
        adapter: MyAdapter,
        adapter_context: adapter_context,
        event_queue: event_queue
      }

      # 3. step each command, threading the returned state forward
      {:ok, state} = Stepping.step(command_0, 0, state, ctx)
      {:ok, state} = Stepping.step(command_1, 1, state, ctx)

      # 4. caller tears everything down
      Stepping.stop_pollers(state)
      PropertyDamage.EventQueue.stop(event_queue)
      MyAdapter.teardown(adapter_context)

  ## Guarantees

  `step/4` runs **the single per-command engine path**: ref/placeholder
  resolution, settle, nemesis, injector/mock events, projections, assertions,
  stutter, and pollers all run exactly as they do inside a full run. It is the
  same engine primitive the full-run loop uses, so stepping cannot diverge from
  running.

  Stepping assumes a **linear** sequence: each command's position is
  `Position.prefix(index)` (DR-021), where `index` is its 0-based offset. Do not
  use this API for branching/parallel sequences.
  """

  alias PropertyDamage.Executor
  alias PropertyDamage.ResourcePoller
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.StatePoller

  defmodule Context do
    @moduledoc """
    The per-run inputs shared by every `step/4` of one sequence.

    These do not change from one command to the next, so they are bundled once
    rather than passed on every call: the `model` orchestrating the run, the
    `adapter` bridging to the SUT and the `adapter_context` its `setup/1`
    returned, and the `event_queue` async/injected events flow through (`nil`
    when the run has no injector adapters).
    """

    @enforce_keys [:model, :adapter, :adapter_context]
    defstruct [:model, :adapter, :adapter_context, :event_queue]

    @type t :: %__MODULE__{
            model: module(),
            adapter: module(),
            adapter_context: term(),
            event_queue: pid() | nil
          }
  end

  @doc """
  Build a fresh executor state for stepping a sequence.

  Options:

    * `:event_queue` - the async/injected event queue (default `nil`)
    * `:stutter_config` - stutter/idempotency configuration (default `nil`)
    * `:mock_registry` - mock service registry (default `nil`)
    * `:assertion_mode` - `:halt` | `:record` | `:log` | `:disabled` (default `:halt`)
    * `:external_markers` - external value markers (default `[]`)
    * `:placeholder_registry` - registry seeded from the generated sequence (DR-021)
    * `:rng_seed` - explicit stutter RNG base (DR-029)
    * `:run_nonce` - run nonce seeding `mint_per_run` resolution (DR-034)
    * `:mint_epoch` - SUT-execution epoch for minted values (DR-034, default 0)
  """
  @spec init_state(module(), keyword()) :: map()
  def init_state(model, opts \\ []) do
    Executor.build_initial_state(
      model,
      Keyword.get(opts, :event_queue),
      Keyword.get(opts, :stutter_config),
      Keyword.get(opts, :mock_registry),
      Keyword.get(opts, :assertion_mode, :halt),
      Keyword.get(opts, :external_markers, []),
      Keyword.get(opts, :placeholder_registry),
      Keyword.get(opts, :rng_seed),
      {Keyword.get(opts, :run_nonce), Keyword.get(opts, :mint_epoch, 0)}
    )
  end

  @doc """
  Execute exactly one command against an existing stepping state.

  Captures the pre-command projections first (as the linear run loop does) and
  positions the command at `Position.prefix(index)`. Returns `{:ok, new_state}` or
  `{:error, reason, failed_state}`.
  """
  @spec step(struct() | map(), non_neg_integer(), map(), Context.t()) ::
          {:ok, map()} | {:error, term(), map()}
  def step(command, index, state, %Context{} = ctx) do
    # Linear stepping: positions are prefix positions (DR-021).
    state_with_before = %{
      state
      | projections_before: state.projections,
        current_position: Position.prefix(index)
    }

    Executor.execute_command(
      command,
      index,
      state_with_before,
      ctx.model,
      ctx.adapter,
      ctx.adapter_context,
      ctx.event_queue
    )
  end

  @doc """
  Stop any pollers spawned during stepping.

  Best-effort cleanup for the stepping shell; a full run finalizes pollers
  through its own finalization path.
  """
  @spec stop_pollers(map()) :: :ok
  def stop_pollers(state) do
    Enum.each(Map.get(state, :active_pollers, []), &StatePoller.stop/1)
    Enum.each(Map.get(state, :active_resource_pollers, []), &ResourcePoller.stop/1)
    :ok
  end
end
