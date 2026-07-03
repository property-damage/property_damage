defmodule PropertyDamage.RunTrace do
  @moduledoc """
  The full, outcome-neutral record of a single run (DR-033).

  A `RunTrace` is the first-class "what one run did" value: the plan it
  executed, the concrete commands actually sent, the complete event log, and
  the outcome. It is the unit `PropertyDamage.RunComparison` (DR-035) consumes,
  and the record a `PropertyDamage.FailureReport` composes (report = trace +
  failure overlay).

  ## Fields

  Identity / reproduction:

  - `seed`, `run_number` — the base seed and exploration run number; the plan is
    a pure function of `Generator.run_seed(seed, run_number)`.
  - `run_nonce`, `mint_epoch` — the client-minted-value axes (DR-034). Hold
    `(seed, run_number)` and vary `run_nonce` for identical plan / fresh minted
    values; pin all four on a pristine SUT for byte-exact reproduction.
  - `model`, `adapter`, `timestamp` — locator metadata.
  - `source_revision` — best-effort `{sha, dirty?}` of the working tree at
    capture, or `nil` outside a git checkout.

  Plan (DR-036):

  - `plan` — the `%Sequence{}` this run executed. Named `plan` (not
    `original_sequence`) deliberately: a report-embedded trace's plan is the
    shrunk sequence, while `FailureReport.original_sequence` keeps meaning the
    generated plan.
  - `plan_source` — `:generated` (a pure function of the effective seed) or
    `:shrunk` (a shrinker product, not regenerable from the seed).
  - `plan_fingerprint` — the DR-036 canonical identity of `plan`.

  Execution record:

  - `executed` — the concrete commands actually sent, post placeholder/mint
    resolution, keyed branch-aware by `%Sequence.Position{}`.
  - `event_log` — the complete `EventLog.Entry` list with per-entry provenance.
    Each entry's `fold_index` records the run's real fold order (P8 / DR-040).
  - `command_labels` — flattened index → label (as the report computes it).
  - `command_fold_ordinals` — `%{Sequence.Position => fold ordinal}`: the ordinal
    at which each command was itself folded into projections (P8 / DR-040). With
    the entries' `fold_index` this is enough to replay the run's true fold order,
    which is what the faithful per-step state timeline (`state_at/2`,
    `state_timeline/1`) does.
  - `linearization` — the verified branch linearization (a tagged
    `[{branch_id, offset, command}]` list) when one was found, else `nil`
    (linear runs, or a branching run with no verified order). Recorded so the
    per-step timeline can fold merged-branch state in the same order the executor
    did (P8 / DR-040).
  - `outcome` — `:pass` or `{:fail, reason}`.
  """

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.{EventQueue, Executor, Generator}
  alias PropertyDamage.RunTrace.Step
  alias PropertyDamage.Sequence

  @type outcome :: :pass | {:fail, term()}
  @type plan_source :: :generated | :shrunk
  @type source_revision :: {String.t(), boolean()} | nil

  @type t :: %__MODULE__{
          seed: integer() | nil,
          run_number: non_neg_integer() | nil,
          run_nonce: non_neg_integer() | nil,
          mint_epoch: non_neg_integer() | nil,
          model: module() | nil,
          adapter: module() | nil,
          timestamp: DateTime.t() | nil,
          source_revision: source_revision(),
          plan: Sequence.t() | nil,
          plan_source: plan_source() | nil,
          plan_fingerprint: String.t() | nil,
          executed: %{Sequence.Position.t() => struct()},
          event_log: [Entry.t()],
          command_labels: %{non_neg_integer() => String.t()},
          command_fold_ordinals: %{Sequence.Position.t() => non_neg_integer()},
          linearization: [{non_neg_integer(), non_neg_integer(), struct()}] | nil,
          outcome: outcome() | nil
        }

  defstruct seed: nil,
            run_number: nil,
            run_nonce: nil,
            mint_epoch: nil,
            model: nil,
            adapter: nil,
            timestamp: nil,
            source_revision: nil,
            plan: nil,
            plan_source: nil,
            plan_fingerprint: nil,
            executed: %{},
            event_log: [],
            command_labels: %{},
            command_fold_ordinals: %{},
            linearization: nil,
            outcome: nil

  @doc """
  Build a `RunTrace` from its constituent pieces.

  Computes `plan_fingerprint` from `plan` (DR-036) and, unless given, stamps a
  UTC `timestamp`. `source_revision` is NOT auto-detected here (that would shell
  out to git on every report build): callers who want it pass
  `source_revision: source_revision()` explicitly (the failure path and
  `capture/1` do).

  ## Options

  All fields are accepted as options. `:plan` (a `%Sequence{}`) drives the
  fingerprint; pass `:plan_fingerprint` explicitly only to override.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    plan = Keyword.get(opts, :plan)

    plan_fingerprint =
      case Keyword.fetch(opts, :plan_fingerprint) do
        {:ok, fp} -> fp
        :error -> if match?(%Sequence{}, plan), do: Sequence.fingerprint(plan)
      end

    %__MODULE__{
      seed: Keyword.get(opts, :seed),
      run_number: Keyword.get(opts, :run_number),
      run_nonce: Keyword.get(opts, :run_nonce),
      mint_epoch: Keyword.get(opts, :mint_epoch),
      model: Keyword.get(opts, :model),
      adapter: Keyword.get(opts, :adapter),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      source_revision: Keyword.get(opts, :source_revision),
      plan: plan,
      plan_source: Keyword.get(opts, :plan_source),
      plan_fingerprint: plan_fingerprint,
      executed: Keyword.get(opts, :executed, %{}),
      event_log: Keyword.get(opts, :event_log, []),
      command_labels: Keyword.get(opts, :command_labels, %{}),
      command_fold_ordinals: Keyword.get(opts, :command_fold_ordinals, %{}),
      linearization: Keyword.get(opts, :linearization),
      outcome: Keyword.get(opts, :outcome)
    }
  end

  @doc """
  The DR-036 canonical fingerprint of a plan.

  Re-exports `Sequence.fingerprint/1` so trace/comparison code has a single
  vocabulary. Two plans are "the same plan" for run comparison iff their
  fingerprints are equal.
  """
  @spec plan_fingerprint(Sequence.t()) :: String.t()
  def plan_fingerprint(%Sequence{} = plan), do: Sequence.fingerprint(plan)

  @doc """
  Run ONE full, unshrunk plan and return its trace, pass or fail (DR-035).

  This is the input to `PropertyDamage.RunComparison`. Unlike the exploration
  loop it never shrinks and never stops early on failure: it captures the whole
  execution record of a single run. `plan_source` is always `:generated` (the
  plan is a pure function of the effective seed).

  ## Options

  Required: `:model`, `:adapter`, `:seed`.

  Optional: `:run_number` (default 0), `:run_nonce` (default fresh crypto
  entropy, DR-034), `:mint_epoch` (default 0), `:adapter_config`,
  `:max_commands` (default 50), `:branching`, `:injector_adapters` (fault/async
  injectors, set up around the run so their events land in the trace),
  `:source_revision` (default detected).
  """
  @spec capture(keyword()) :: t()
  def capture(opts) do
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    seed = Keyword.fetch!(opts, :seed)
    run_number = Keyword.get(opts, :run_number, 0)

    run_nonce =
      Keyword.get(opts, :run_nonce) ||
        :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()

    mint_epoch = Keyword.get(opts, :mint_epoch, 0)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    max_commands = Keyword.get(opts, :max_commands, 50)
    branching = Keyword.get(opts, :branching)
    injector_adapters = Keyword.get(opts, :injector_adapters, [])

    gen_opts =
      [max_commands: max_commands] ++ if(branching, do: [branching: branching], else: [])

    run_seed = Generator.run_seed(seed, run_number)
    plan = model |> Generator.generate_sequence(gen_opts) |> Generator.generate_value(run_seed)

    if function_exported?(model, :setup_each, 1) do
      model.setup_each(%{adapter_config: adapter_config, run_number: run_number, capture: true})
    end

    {:ok, event_queue} = EventQueue.start_link()
    setup_injectors(injector_adapters, event_queue)

    try do
      {:ok, result} =
        Executor.run(plan, model, adapter,
          adapter_config: adapter_config,
          event_queue: event_queue,
          rng_seed: run_seed,
          run_nonce: run_nonce,
          mint_epoch: mint_epoch
        )

      new(
        seed: seed,
        run_number: run_number,
        run_nonce: run_nonce,
        mint_epoch: mint_epoch,
        model: model,
        adapter: adapter,
        source_revision: Keyword.get_lazy(opts, :source_revision, &source_revision/0),
        plan: plan,
        plan_source: :generated,
        executed: Map.get(result, :executed, %{}),
        event_log: result.event_log,
        command_labels: %{},
        command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
        linearization: linearization_of(result),
        outcome: outcome_of(result)
      )
    after
      teardown_injectors(injector_adapters)
      EventQueue.stop(event_queue)

      if function_exported?(model, :teardown_each, 1) do
        model.teardown_each(%{adapter_config: adapter_config, run_number: run_number})
      end
    end
  end

  # Injector-adapter lifecycle for capture (mirrors the exploration run loop):
  # setup receives the event queue so injected events land in the run's log.
  defp setup_injectors(injector_adapters, event_queue) do
    for adapter <- injector_adapters, function_exported?(adapter, :setup, 1) do
      adapter.setup(%{event_queue: event_queue})
    end
  end

  defp teardown_injectors(injector_adapters) do
    for adapter <- injector_adapters, function_exported?(adapter, :teardown, 1) do
      adapter.teardown(%{})
    end
  end

  defp outcome_of(%{success: true}), do: :pass
  defp outcome_of(%{failure_reason: reason}), do: {:fail, reason}

  # Keep only a verified linearization (a tagged list) on the trace; the
  # `:indeterminate` / `:no_linearization` executor tags are not a fold order.
  defp linearization_of(%{linearization: [_ | _] = tagged}), do: tagged
  defp linearization_of(_), do: nil

  @doc """
  The run as a timeline of `Step` structs, in flattened (reading) order.

  Each step pairs a command with its `Sequence.Position`, flattened index,
  concrete `executed_command` (when captured), observed log entries, label, and
  a `failed?` flag. A bare trace does not localize failures (that is a
  `FailureReport` overlay), so `failed?` is `false` for every step here;
  `event_entries_at/2` is sugar over this.

  Returns `[]` for a trace with no plan.
  """
  @spec steps(t()) :: [Step.t()]
  def steps(%__MODULE__{plan: nil}), do: []

  def steps(%__MODULE__{plan: %Sequence{} = plan} = trace) do
    build_steps(plan, trace.event_log, trace.command_labels, nil, executed: trace.executed)
  end

  @doc """
  Builds the `Step` timeline from raw pieces, without a full `RunTrace`.

  This is the grouping core shared by `steps/1`, `FailureReport.steps/1` (which
  supplies its failure-localization overlay), and consumers that hold a
  sequence and event log but no trace (e.g. `PropertyDamage.Diagram`'s
  report-less entry point). `command_labels` may be `%{}` and `failed_at_index`
  may be `nil` when those facts are unavailable.

  ## Options

    * `:branch_id` - the failing branch, used with `failed_at_index` to resolve
      the failing command's position (defaults to `nil`).
    * `:executed` - a `%{Position => command}` map of concrete resolved commands
      (defaults to `%{}`, i.e. `executed_command` is `nil` on every step).
  """
  @spec build_steps(
          Sequence.t(),
          [Entry.t()],
          %{non_neg_integer() => String.t()},
          non_neg_integer() | nil,
          keyword()
        ) :: [Step.t()]
  def build_steps(%Sequence{} = sequence, event_log, command_labels, failed_at_index, opts \\ []) do
    branch_id = Keyword.get(opts, :branch_id)
    executed = Keyword.get(opts, :executed, %{})

    # Group the command-attributed log entries by the position of the command
    # that produced them. Injector/telemetry entries carry no command_index and
    # so belong to no step. `(command_index, branch_id)` resolves uniquely to a
    # position, so this is the branch-aware equivalent of grouping by
    # command_index alone. Full entries (not bare events) are kept so each step
    # preserves per-event provenance (source, branch_id) for the event timeline.
    entries_by_position =
      event_log
      |> List.wrap()
      |> Enum.filter(&(&1.command_index != nil))
      |> Enum.group_by(fn entry ->
        Sequence.position_at(sequence, entry.command_index, entry.branch_id)
      end)

    # The failing command's position (nil for a non-localized failure). Resolved
    # via position_at, NOT by comparing flattened_index to failed_at_index: the
    # latter is an executor index and diverges from the flattened ordinal for
    # branch failures.
    failed_position =
      if failed_at_index != nil do
        Sequence.position_at(sequence, failed_at_index, branch_id)
      end

    sequence
    |> Sequence.indexed()
    |> Enum.map(fn {position, flattened_index, command} ->
      %Step{
        position: position,
        flattened_index: flattened_index,
        command: command,
        executed_command: Map.get(executed, position),
        entries: Map.get(entries_by_position, position, []),
        label: Map.get(command_labels, flattened_index),
        failed?: failed_position != nil and position == failed_position
      }
    end)
  end

  @doc """
  The `EventLog.Entry` structs observed for a single command, addressed by
  flattened index or `Sequence.Position`.

  Sugar over `steps/1`. Each entry carries its per-event provenance (`source`,
  `branch_id`); the bare event struct is `entry.event`. Returns `[]` when
  nothing matches.
  """
  @spec event_entries_at(t(), non_neg_integer() | Sequence.Position.t()) :: [Entry.t()]
  def event_entries_at(%__MODULE__{} = trace, %Sequence.Position{} = position) do
    trace
    |> steps()
    |> Enum.find(&(&1.position == position))
    |> step_entries()
  end

  def event_entries_at(%__MODULE__{} = trace, flattened_index)
      when is_integer(flattened_index) do
    trace
    |> steps()
    |> Enum.find(&(&1.flattened_index == flattened_index))
    |> step_entries()
  end

  defp step_entries(nil), do: []
  defp step_entries(%Step{entries: entries}), do: entries

  @doc """
  The event-log entries with no command attribution (`command_index: nil`).

  These are the injector / telemetry / other async-source events observed
  between commands: the complement of what `steps/1` serves per step. Renderers
  reach them through this accessor so they still appear rather than vanish; the
  comparator (DR-035) excludes unattributed entries from alignment on its own.
  """
  @spec async_entries(t()) :: [Entry.t()]
  def async_entries(%__MODULE__{event_log: event_log}) do
    event_log |> List.wrap() |> Enum.filter(&(&1.command_index == nil))
  end

  # ============================================================================
  # Per-step state timeline (P8 / DR-040)
  # ============================================================================
  #
  # Projection state per step is DERIVED from the recorded fold order, never
  # captured. Two modes:
  #
  #   * FAITHFUL (`state_at/2`, `state_before/2`, `state_timeline/1`) — the
  #     human surface. Folds in the run's *real* fold order (entry `fold_index`
  #     + `command_fold_ordinals`), so async / injected events land exactly where
  #     they folded. This is the mode whose failure-step value must equal the
  #     runtime `state_at_failure` snapshot (the projection-purity check).
  #
  #   * CANONICAL (`canonical_state_timeline/1`) — a timing-immune mode used by
  #     `PropertyDamage.RunComparison` for cross-run state alignment. Folds each
  #     step's executed command then its attributed events, in flattened order,
  #     ignoring when async events actually folded. Two runs of the same plan
  #     that differ only in async timing therefore derive identical canonical
  #     states, so state divergence in a comparison never reduces to timing skew.

  @doc """
  Faithful projection state immediately AFTER the step at `position` (P8).

  Folds every recorded item (command folds + folded event-log entries) up to and
  including this step's own folds, in true fold order. `position` may be a
  `%Sequence.Position{}` or a flattened (reading-order) index. Returns a
  `%{projection_module => state}` map, or `%{}` for a trace with no plan/model.
  """
  @spec state_at(t(), Sequence.Position.t() | non_neg_integer()) :: %{module() => term()}
  def state_at(%__MODULE__{} = trace, position),
    do: faithful_state(trace, resolve_position(trace, position), :at)

  @doc """
  Faithful projection state immediately BEFORE the step at `position` (P8).

  The pre-step state: folds every recorded item with a fold ordinal strictly
  below this step's first fold. Equal to the runtime `state_before_failure`
  snapshot when `position` is the failing step.
  """
  @spec state_before(t(), Sequence.Position.t() | non_neg_integer()) :: %{module() => term()}
  def state_before(%__MODULE__{} = trace, position),
    do: faithful_state(trace, resolve_position(trace, position), :before)

  @doc """
  The faithful post-step state for every command, in flattened (reading) order.

  Returns `[{position, state}]`. Sugar over `state_at/2` computed in one pass.
  """
  @spec state_timeline(t()) :: [{Sequence.Position.t(), %{module() => term()}}]
  def state_timeline(%__MODULE__{plan: nil}), do: []

  def state_timeline(%__MODULE__{plan: %Sequence{} = plan} = trace) do
    plan
    |> Sequence.indexed()
    |> Enum.map(fn {position, _idx, _cmd} -> {position, state_at(trace, position)} end)
  end

  @doc """
  The canonical (timing-immune) post-step state for every command (P8).

  Folds each step's executed command then its attributed, folded events, in
  flattened order — never using async fold timing. This is the mode
  `PropertyDamage.RunComparison` aligns on so state divergence is attributable,
  not a timing artifact. Returns `[{position, state}]`.
  """
  @spec canonical_state_timeline(t()) :: [{Sequence.Position.t(), %{module() => term()}}]
  def canonical_state_timeline(%__MODULE__{plan: nil}), do: []
  def canonical_state_timeline(%__MODULE__{model: nil}), do: []

  def canonical_state_timeline(%__MODULE__{plan: %Sequence{} = plan} = trace) do
    init = init_projections(trace.model)

    {timeline, _} =
      plan
      |> Sequence.indexed()
      |> Enum.map_reduce(init, fn {position, _idx, plan_cmd}, projs ->
        projs = fold_one(projs, executed_or_plan(trace, position, plan_cmd))

        projs =
          trace
          |> folded_entries_at(position)
          |> Enum.reduce(projs, fn entry, acc -> fold_one(acc, entry.event) end)

        {{position, projs}, projs}
      end)

    timeline
  end

  @doc """
  Verify the faithful-derived state at a step equals an authoritative snapshot
  (the projection-purity check, P8 / DR-040).

  Pure projections re-derive to the same state, so a mismatch means a projection
  read something outside its `(state, event)` inputs (a clock, a counter, the
  environment) in `apply/2`. Because faithful derivation replays the *real* fold
  order, a pure-but-async projection re-derives correctly and does NOT
  false-positive.

  `boundary` is `:at` (compare `state_at/2`) or `:before` (compare
  `state_before/2`). Returns `:ok`, or `{:non_pure_projections, [module()]}`
  naming the projection modules whose derived state diverged. Returns `:ok` when
  the snapshot is empty (nothing to check).
  """
  @spec verify_projections(
          t(),
          Sequence.Position.t() | non_neg_integer(),
          %{module() => term()},
          :at | :before
        ) ::
          :ok | {:non_pure_projections, [module()]}
  def verify_projections(trace, position, snapshot, boundary \\ :at)

  def verify_projections(_trace, _position, snapshot, _boundary) when snapshot == %{}, do: :ok

  def verify_projections(%__MODULE__{} = trace, position, snapshot, boundary)
      when is_map(snapshot) do
    derived =
      case boundary do
        :before -> state_before(trace, position)
        _ -> state_at(trace, position)
      end

    mismatched =
      snapshot
      |> Map.keys()
      |> Enum.filter(fn module -> Map.get(derived, module) != Map.fetch!(snapshot, module) end)
      |> Enum.sort()

    if mismatched == [], do: :ok, else: {:non_pure_projections, mismatched}
  end

  # ---- Faithful derivation internals ----------------------------------------

  defp faithful_state(%__MODULE__{model: nil}, _position, _boundary), do: %{}
  defp faithful_state(%__MODULE__{plan: nil}, _position, _boundary), do: %{}
  defp faithful_state(_trace, nil, _boundary), do: %{}

  defp faithful_state(%__MODULE__{plan: plan} = trace, position, boundary) do
    init = init_projections(trace.model)
    items = fold_items(trace)
    section = position.section

    cond do
      not branched?(plan) or section == :prefix ->
        cutoff = boundary_ordinal(items, position, boundary)

        items
        |> Enum.filter(&section_in?(&1.position, sections_for(section, plan)))
        |> keep_below(cutoff, boundary)
        |> fold_in_order(init)

      match?({:branch, _}, section) ->
        cutoff = boundary_ordinal(items, position, boundary)

        items
        |> Enum.filter(&section_in?(&1.position, [:prefix, section]))
        |> keep_below(cutoff, boundary)
        |> fold_in_order(init)

      section == :suffix ->
        merged = merged_state(trace, init, items)
        cutoff = boundary_ordinal(items, position, boundary)

        items
        |> Enum.filter(&(section_of(&1.position) == :suffix))
        |> keep_below(cutoff, boundary)
        |> fold_in_order(merged)
    end
  end

  # For a linear plan, every position is in the prefix section, so we fold the
  # whole item stream by ordinal; branched-plan prefix positions likewise only
  # ever see prefix items (branch/suffix ordinals are strictly higher).
  defp sections_for(:prefix, plan) do
    if branched?(plan), do: [:prefix], else: [:prefix, :suffix, nil]
  end

  # Merge branch state exactly as `Executor.Branching.merge_branch_states` does:
  # fold the prefix, then replay each branch's (command, observed events) in the
  # verified linearization order when one exists, else branch order. Command
  # first, then that command's folded events (attribution order within a branch).
  defp merged_state(trace, init, items) do
    prefix_state =
      items
      |> Enum.filter(&(section_of(&1.position) == :prefix))
      |> fold_in_order(init)

    trace
    |> linearization_order()
    |> Enum.reduce(prefix_state, fn position, projs ->
      projs = fold_one(projs, executed_or_plan(trace, position, nil))

      trace
      |> folded_entries_at(position)
      |> Enum.reduce(projs, fn entry, acc -> fold_one(acc, entry.event) end)
    end)
  end

  # The branch replay order as `%Sequence.Position{}` values: the verified
  # linearization when the trace recorded one (P8), otherwise plain branch order
  # (branch 0 then branch 1 ..., each in offset order), which is itself a valid
  # interleaving for independent branches.
  defp linearization_order(%__MODULE__{linearization: [_ | _] = tagged}) do
    Enum.map(tagged, fn {branch_id, offset, _cmd} ->
      Sequence.Position.branch(branch_id, offset)
    end)
  end

  defp linearization_order(%__MODULE__{plan: %Sequence{branches: branches}})
       when is_list(branches) do
    branches
    |> Enum.with_index()
    |> Enum.flat_map(fn {commands, branch_id} ->
      Enum.map(0..(length(commands) - 1)//1, &Sequence.Position.branch(branch_id, &1))
    end)
  end

  defp linearization_order(_), do: []

  # All folded items (commands + folded entries) tagged with their fold ordinal
  # and structured position. Non-folded entries (stutter / telemetry, fold_index
  # nil) are excluded: they never advanced projection state.
  defp fold_items(%__MODULE__{plan: plan} = trace) do
    command_items =
      Enum.map(trace.command_fold_ordinals, fn {position, ordinal} ->
        %{ordinal: ordinal, position: position, item: executed_or_plan(trace, position, nil)}
      end)

    entry_items =
      trace.event_log
      |> List.wrap()
      |> Enum.filter(&(&1.fold_index != nil))
      |> Enum.map(fn entry ->
        position =
          if entry.command_index != nil,
            do: Sequence.position_at(plan, entry.command_index, entry.branch_id)

        %{ordinal: entry.fold_index, position: position, item: entry.event}
      end)

    command_items ++ entry_items
  end

  defp boundary_ordinal(items, position, boundary) do
    ordinals =
      items
      |> Enum.filter(&(&1.position == position))
      |> Enum.map(& &1.ordinal)

    case {boundary, ordinals} do
      {_, []} -> nil
      {:before, _} -> Enum.min(ordinals)
      {:at, _} -> Enum.max(ordinals)
    end
  end

  defp keep_below(_items, nil, _boundary), do: []

  defp keep_below(items, cutoff, :before),
    do: items |> Enum.filter(&(&1.ordinal < cutoff)) |> Enum.sort_by(& &1.ordinal)

  defp keep_below(items, cutoff, :at),
    do: items |> Enum.filter(&(&1.ordinal <= cutoff)) |> Enum.sort_by(& &1.ordinal)

  defp fold_in_order(items, init) do
    Enum.reduce_while(items, init, fn %{item: item}, projs ->
      try do
        {:cont, fold_one(projs, item)}
      rescue
        # A raising apply/2 is a transition-invariant signal; in the real run it
        # halted the fold with the pre-raise state, so we stop here too.
        _ -> {:halt, projs}
      end
    end)
  end

  defp fold_one(projections, item) do
    Map.new(projections, fn {projection, state} -> {projection, projection.apply(state, item)} end)
  end

  defp folded_entries_at(%__MODULE__{plan: plan, event_log: event_log}, position) do
    event_log
    |> List.wrap()
    |> Enum.filter(fn entry ->
      entry.fold_index != nil and entry.command_index != nil and
        Sequence.position_at(plan, entry.command_index, entry.branch_id) == position
    end)
    |> Enum.sort_by(& &1.fold_index)
  end

  defp executed_or_plan(%__MODULE__{executed: executed} = trace, position, fallback) do
    case Map.get(executed, position) do
      nil -> fallback || plan_command_at(trace, position)
      command -> command
    end
  end

  defp plan_command_at(%__MODULE__{plan: %Sequence{} = plan}, position) do
    plan
    |> Sequence.indexed()
    |> Enum.find_value(fn {pos, _idx, cmd} -> if pos == position, do: cmd end)
  end

  defp plan_command_at(_trace, _position), do: nil

  # Rebuild the run's projection set from the model, exactly as the executor
  # does. Degrades to `%{}` for a model that declares no
  # `command_sequence_projection/0` (e.g. a hand-built or synthetic trace), so
  # derivation on such a trace is a no-op rather than a crash.
  defp init_projections(model) do
    if is_atom(model) and model != nil and Code.ensure_loaded?(model) and
         function_exported?(model, :command_sequence_projection, 0) do
      command_projection = model.command_sequence_projection()

      assertion_projections =
        if function_exported?(model, :assertion_projections, 0),
          do: model.assertion_projections(),
          else: []

      Map.new([command_projection | assertion_projections], &{&1, &1.init()})
    else
      %{}
    end
  end

  defp resolve_position(%__MODULE__{}, %Sequence.Position{} = position), do: position

  defp resolve_position(%__MODULE__{plan: %Sequence{} = plan}, index) when is_integer(index) do
    plan
    |> Sequence.indexed()
    |> Enum.find_value(fn {position, idx, _cmd} -> if idx == index, do: position end)
  end

  defp resolve_position(_trace, _position), do: nil

  defp branched?(%Sequence{branches: branches}) when is_list(branches), do: true
  defp branched?(_), do: false

  defp section_of(nil), do: nil
  defp section_of(%Sequence.Position{section: section}), do: section

  defp section_in?(position, sections), do: section_of(position) in sections

  @doc """
  Best-effort working-tree revision at the moment of the call.

  Reuses the `mix pd.bisect` git idiom: `{sha, dirty?}` where `dirty?` reflects
  `git status --porcelain`, or `nil` when not in a git checkout (or git is
  unavailable). Never raises. Callers pass the result as `new(source_revision:
  ...)`; it is deliberately not called from `new/1` so ordinary report builds
  (and unit tests) do not shell out to git.
  """
  @spec source_revision() :: source_revision()
  def source_revision do
    with {sha, 0} <- git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]),
         {status, 0} <- git(["status", "--porcelain"]) do
      {String.trim(sha), status != ""}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)
end
