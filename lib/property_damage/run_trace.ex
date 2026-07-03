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
  - `command_labels` — flattened index → label (as the report computes it).
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
