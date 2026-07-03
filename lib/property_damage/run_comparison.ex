defmodule PropertyDamage.RunComparison do
  @moduledoc """
  Compare N full-run `RunTrace` records of the *same plan* and localize where
  their executions diverge (DR-035).

  Two use cases: **regression localization** (a plan that passed on commit A and
  fails on commit B — where do the runs diverge?) and **flakiness localization**
  (a plan that fails one time in five — what differs between passing and failing
  executions?). Both need full, unshrunk, same-plan runs, which is exactly what
  `PropertyDamage.RunTrace.capture/1` produces and what a `FailureReport` is not.

  The comparator is pure data-in/data-out and never runs a SUT:

      traces = for _ <- 1..5, do: RunTrace.capture(model: M, adapter: A, seed: 1)
      comparison = RunComparison.compare(traces)

  This is the flakiness tool. `investigate/1` handles a single known seed:
  captures the traces for you (a fresh recorded nonce per run, so client-minted
  values never collide on a shared SUT) and ranks where the passing and failing
  runs diverge. `scan/1` is its corpus counterpart: run a whole list of seeds, N
  captures each, and get back a per-seed `Verdict`, discarding a seed's traces
  before moving to the next so memory stays bounded. `outcome_summary/1` is the
  cheap outcome-level view (pass/fail counts + distinct failure signatures) both
  are built on.

  ## What it aligns

  Commands align by branch-aware `%Sequence.Position{}` (identical across
  same-plan runs). Events within a command align by longest-common-subsequence
  on the event struct module. Entries with no command attribution (injector /
  telemetry) are excluded from comparison in this version.

  Projection **state** also enters the ranking (P8 / DR-040): each projection's
  per-step CANONICAL state (`RunTrace.canonical_state_timeline/1`) is flattened
  into leaf-path fields (`{:state, position, projection, path}`) and classified
  like any other field. Canonical state is fold-order-independent, so an
  async-timing difference between two runs can never surface as a state
  divergence — state findings are always attributable. Deeply nested / very wide
  state is bounded (max depth 5, max fan-out 64); beyond either bound a
  subtree compares as one opaque leaf. A projection whose state varies *within*
  an outcome group is reported in `state_warnings` (a likely non-pure
  projection): same plan, same outcome, different derived state.

  ## Classification

  Runs partition by outcome. For each aligned field difference: varies within a
  group → `:incidental`; stable within each group but different between groups →
  `:discriminating` (the ranking's subject); otherwise `:weak`. Provenance
  (DR-034) shades everything: `:run_scoped` differences are correlation ids and
  never suspicious; `:server_resolved` differences are the analysis subject;
  `:plan_generated` differences are comparability violations.
  """

  alias PropertyDamage.{External, Mint, Placeholder, Provenance, RunTrace, Sequence}
  alias PropertyDamage.RunComparison.{Align, Html}

  defmodule Field do
    @moduledoc "One aligned field compared across all traces (DR-035)."
    @type location ::
            {:command, Sequence.Position.t(), [term()]}
            | {:event, Sequence.Position.t(), term(), non_neg_integer(), [term()]}
            | {:state, Sequence.Position.t(), module(), [term()]}

    @type classification ::
            :uniform | :incidental | :discriminating | :weak | :comparability_violation

    defstruct [
      :location,
      :provenance,
      :values,
      :differs?,
      :classification,
      incidental_override: false
    ]

    @type t :: %__MODULE__{
            location: location(),
            provenance: Provenance.class(),
            values: %{non_neg_integer() => term()},
            differs?: boolean(),
            classification: classification(),
            # Set when the difference is a same-module repetition-count artifact
            # (settle/probe polling): timing-dependent noise, forced incidental.
            incidental_override: boolean()
          }
  end

  defmodule Verdict do
    @moduledoc """
    One seed's flakiness verdict from a corpus `scan/1` (DR-035).

    Carries the cheap, always-retained outcome view (`flaky?`, `partition`,
    `failure_signatures`) plus, for flaky seeds only, the full `%RunComparison{}`
    so the field-by-field divergence is one hop away. `comparison` is `nil` for a
    consistent seed, which is what keeps a scan's memory bounded: only the
    interesting minority retains its traces.
    """
    @type partition :: %{passing: non_neg_integer(), failing: non_neg_integer()}

    defstruct [:seed, :runs, :flaky?, :partition, :failure_signatures, :comparison]

    @type t :: %__MODULE__{
            seed: integer(),
            runs: non_neg_integer(),
            flaky?: boolean(),
            partition: partition(),
            failure_signatures: [term()],
            comparison: PropertyDamage.RunComparison.t() | nil
          }
  end

  @type t :: %__MODULE__{
          traces: [RunTrace.t()],
          comparable?: boolean(),
          guard_violations: [String.t()],
          groups: %{passing: [non_neg_integer()], failing: [non_neg_integer()]},
          mixed_failure_signatures: [term()],
          fields: [Field.t()],
          ranking: [Field.t()],
          state_warnings: [module()],
          header: map()
        }

  defstruct traces: [],
            comparable?: false,
            guard_violations: [],
            groups: %{passing: [], failing: []},
            mixed_failure_signatures: [],
            fields: [],
            ranking: [],
            state_warnings: [],
            header: %{}

  @doc """
  Compare a list of same-plan `RunTrace` records.

  Returns a pure `%RunComparison{}`. When the comparability guard fails (unequal
  `plan_fingerprint` or model), `comparable?` is `false`, `guard_violations`
  explains, and no rows are produced (it refuses rather than emit a misleading
  diff).

  ## Options

  - `:event_identity` - `(event -> term())` overriding the default struct-module
    event alignment key (for models emitting many same-module events per
    command).
  """
  @spec compare([RunTrace.t()], keyword()) :: t()
  def compare(traces, opts \\ [])

  def compare([], _opts), do: %__MODULE__{comparable?: false, guard_violations: ["no traces"]}

  def compare(traces, opts) do
    opts = PropertyDamage.Options.validate_run_comparison_compare!(opts)
    header = build_header(traces)

    case guard(traces) do
      [] ->
        groups = partition(traces)

        minted =
          traces |> Enum.map(&Provenance.minted_value_set/1) |> Enum.reduce(&MapSet.union/2)

        fields = build_fields(traces, opts, minted)
        classified = Enum.map(fields, &classify(&1, groups))

        %__MODULE__{
          traces: traces,
          comparable?: true,
          groups: groups,
          mixed_failure_signatures: mixed_failure_signatures(traces, groups),
          fields: classified,
          ranking: rank(classified),
          state_warnings: state_warnings(classified, groups),
          header: header
        }

      violations ->
        %__MODULE__{
          traces: traces,
          comparable?: false,
          guard_violations: violations,
          groups: partition(traces),
          header: header
        }
    end
  end

  @doc """
  Render a comparison as a single self-contained HTML document (DR-035).

  Inline CSS/JS, no external hosts (repo self-sufficiency); readable with
  JavaScript disabled (the table is pre-rendered); JS adds only accordion
  collapse. Carries an embedded, versioned JSON blob
  (`<script type="application/json" id="run-comparison-data">`) as the
  machine-readable source of truth. No sibling `.json` file is written.
  """
  @spec to_html(t()) :: String.t()
  def to_html(%__MODULE__{} = comparison) do
    Html.render(comparison)
  end

  @doc """
  Capture N traces of one plan and compare them (flakiness sugar, DR-035).

  Each capture draws a fresh recorded `run_nonce`, so client-minted values are
  collision-free on a shared SUT. Returns `{traces, comparison}`.

  ## Options

  - `:capture` (required) - options forwarded to `RunTrace.capture/1` (must
    include `:model`, `:adapter`, `:seed`; may include `:run_number`, etc.). A
    fresh `:run_nonce` is injected per capture.
  - `:runs` - number of captures (default 5).
  - `:event_identity` - forwarded to `compare/2`.

  ## Example

      RunComparison.investigate(
        runs: 5,
        capture: [model: MyModel, adapter: MyAdapter, seed: 3]
      )
  """
  @spec investigate(keyword()) :: {[RunTrace.t()], t()}
  def investigate(opts) do
    opts = PropertyDamage.Options.validate_run_comparison_investigate!(opts)
    runs = Keyword.fetch!(opts, :runs)
    capture_opts = Keyword.fetch!(opts, :capture)

    traces =
      for _ <- 1..runs do
        # Fresh recorded nonce per run: identical plan, distinct minted values.
        nonce = :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()
        RunTrace.capture(Keyword.put(capture_opts, :run_nonce, nonce))
      end

    {traces, compare(traces, Keyword.take(opts, [:event_identity]))}
  end

  @doc """
  Scan a corpus of seeds for flakiness (DR-035).

  For each seed, captures `:runs` traces of that seed's plan (a fresh
  `run_nonce` per capture) and returns a `%{seed => Verdict.t()}` map. Memory is
  bounded: a seed's traces are reduced to a `Verdict` before the next seed is
  captured, and only flaky seeds retain their `%RunComparison{}` (a consistent
  seed keeps just the outcome counts, so its traces are freed).

  This is the corpus counterpart to `investigate/1`, which deep-localizes a
  single already-suspect seed.

  ## Options

  - `:seeds` (required) - the list of seeds to scan.
  - `:runs` - captures per seed (default 5).
  - `:capture` (required) - options forwarded to `RunTrace.capture/1` (must
    include `:model` and `:adapter`; the `:seed` is supplied per scanned seed,
    so any `:seed` here is ignored). A fresh `:run_nonce` is injected per
    capture.
  - `:event_identity` - forwarded to `compare/2`.

  ## Example

      RunComparison.scan(
        seeds: Enum.to_list(1..100),
        runs: 5,
        capture: [model: MyModel, adapter: MyAdapter]
      )
  """
  @spec scan(keyword()) :: %{integer() => Verdict.t()}
  def scan(opts) do
    opts = PropertyDamage.Options.validate_run_comparison_scan!(opts)
    seeds = Keyword.fetch!(opts, :seeds)
    runs = Keyword.fetch!(opts, :runs)
    capture_opts = opts |> Keyword.fetch!(:capture) |> Keyword.delete(:seed)
    compare_opts = Keyword.take(opts, [:event_identity])

    Map.new(seeds, fn seed -> {seed, scan_seed(seed, runs, capture_opts, compare_opts)} end)
  end

  # One seed: capture N traces, reduce to a verdict, keep the comparison only
  # when flaky so consistent seeds' traces are released before the next seed.
  defp scan_seed(seed, runs, capture_opts, compare_opts) do
    traces =
      for _ <- 1..runs do
        nonce = :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()

        RunTrace.capture(
          capture_opts
          |> Keyword.put(:seed, seed)
          |> Keyword.put(:run_nonce, nonce)
        )
      end

    comparison = compare(traces, compare_opts)
    summary = outcome_summary(comparison)
    flaky? = flaky_summary?(summary)

    %Verdict{
      seed: seed,
      runs: runs,
      flaky?: flaky?,
      partition: %{passing: summary.passing, failing: summary.failing},
      failure_signatures: summary.failure_signatures,
      comparison: if(flaky?, do: comparison, else: nil)
    }
  end

  # Flaky iff the runs disagree on pass/fail, or the failing runs disagree on
  # why they failed (same-signature repeated failures are consistent, not flaky).
  defp flaky_summary?(%{passing: passing, failing: failing, failure_signatures: sigs}) do
    (passing > 0 and failing > 0) or length(sigs) > 1
  end

  @doc """
  Summarize a comparison's runs by outcome (DR-035).

  The cheap outcome-level view — passing/failing run counts and the distinct
  failure signatures observed — that flakiness detection is built on, so callers
  read a summary instead of digging into `groups` and re-deriving signatures.
  """
  @spec outcome_summary(t()) :: %{
          passing: non_neg_integer(),
          failing: non_neg_integer(),
          failure_signatures: [term()]
        }
  def outcome_summary(%__MODULE__{groups: groups} = comparison) do
    %{
      passing: length(groups.passing),
      failing: length(groups.failing),
      failure_signatures: distinct_failure_signatures(comparison)
    }
  end

  defp distinct_failure_signatures(%__MODULE__{traces: traces, groups: %{failing: failing}}) do
    failing
    |> Enum.map(fn i -> failure_signature(Enum.at(traces, i).outcome) end)
    |> Enum.uniq()
  end

  # ---- Guard ----------------------------------------------------------------

  defp guard(traces) do
    fingerprints = traces |> Enum.map(& &1.plan_fingerprint) |> Enum.uniq()
    models = traces |> Enum.map(& &1.model) |> Enum.uniq()

    []
    |> add_if(
      length(fingerprints) > 1,
      "traces span #{length(fingerprints)} distinct plans (fingerprints differ)"
    )
    |> add_if(length(models) > 1, "traces span distinct models: #{inspect(models)}")
  end

  defp add_if(list, true, msg), do: list ++ [msg]
  defp add_if(list, false, _msg), do: list

  # ---- Grouping -------------------------------------------------------------

  defp partition(traces) do
    traces
    |> Enum.with_index()
    |> Enum.reduce(%{passing: [], failing: []}, fn {trace, i}, acc ->
      case trace.outcome do
        :pass -> %{acc | passing: acc.passing ++ [i]}
        {:fail, _} -> %{acc | failing: acc.failing ++ [i]}
        _ -> acc
      end
    end)
  end

  defp mixed_failure_signatures(traces, %{failing: failing}) do
    sigs =
      failing
      |> Enum.map(fn i -> failure_signature(Enum.at(traces, i).outcome) end)
      |> Enum.uniq()

    if length(sigs) > 1, do: sigs, else: []
  end

  defp failure_signature({:fail, reason}), do: PropertyDamage.Shrinker.failure_signature(reason)
  defp failure_signature(_), do: nil

  # ---- Field extraction -----------------------------------------------------

  defp build_fields(traces, opts, minted) do
    identity = Keyword.get(opts, :event_identity, & &1.__struct__)
    [reference | _] = traces

    # Canonical (attribution-order) per-step state per trace, indexed by trace
    # position (P8 / DR-040). Canonical is timing-immune, so an async fold-order
    # difference between two runs can never manifest as a state divergence here:
    # state divergence in the ranking is always attributable, never timing skew.
    canonical_states =
      traces
      |> Enum.with_index()
      |> Map.new(fn {trace, i} -> {i, Map.new(RunTrace.canonical_state_timeline(trace))} end)

    reference.plan
    |> indexed_positions()
    |> Enum.flat_map(fn {position, plan_command} ->
      command_fields(traces, position, plan_command) ++
        event_fields(traces, position, identity, minted) ++
        state_fields(traces, position, canonical_states)
    end)
  end

  defp indexed_positions(%Sequence{} = plan) do
    plan |> Sequence.indexed() |> Enum.map(fn {pos, _idx, cmd} -> {pos, cmd} end)
  end

  defp indexed_positions(_), do: []

  # One field per LEAF path of the command struct, valued by each trace's
  # resolved (executed) command, classified by the plan's value at that leaf
  # (mint marker -> run-scoped, placeholder -> server-resolved, else
  # plan-generated). Leaf granularity means a mint nested inside a map is
  # classified run-scoped at its own path rather than the whole container being
  # lumped as a differing plan-generated field.
  defp command_fields(traces, position, plan_command) when is_struct(plan_command) do
    plan_command
    |> command_leaves([])
    |> Enum.map(fn {path, plan_value} ->
      values =
        traces
        |> Enum.with_index()
        |> Map.new(fn {trace, i} ->
          command = Map.get(trace.executed, position, plan_command)
          {i, External.get_at_path(command, path)}
        end)

      %Field{
        location: {:command, position, path},
        provenance: Provenance.command_field(plan_value),
        values: values,
        differs?: differs?(values)
      }
    end)
  end

  defp command_fields(_traces, _position, _plan_command), do: []

  # Leaf paths of a command's plan value. Markers are terminal (their provenance
  # is what matters); containers are recursed. Path built in reading order.
  defp command_leaves(%Mint{} = m, path), do: [{Enum.reverse(path), m}]
  defp command_leaves(%Placeholder{} = p, path), do: [{Enum.reverse(path), p}]

  defp command_leaves(%{__struct__: _} = struct, path) do
    struct |> Map.from_struct() |> Enum.flat_map(fn {k, v} -> command_leaves(v, [k | path]) end)
  end

  defp command_leaves(map, path) when is_map(map) do
    Enum.flat_map(map, fn {k, v} -> command_leaves(v, [k | path]) end)
  end

  defp command_leaves(list, path) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> command_leaves(v, [i | path]) end)
  end

  defp command_leaves(scalar, path), do: [{Enum.reverse(path), scalar}]

  defp event_fields(traces, position, identity, minted) do
    event_lists = Enum.map(traces, &events_at(&1, position))
    rows = Align.align_events(event_lists, identity)

    # Modules whose per-trace event count varies are repetition-count noise
    # (settle/probe polling); insertion rows of such modules are down-ranked.
    varying = varying_count_modules(event_lists)

    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, row_index} ->
      event_row_fields(row, row_index, position, minted, varying)
    end)
  end

  defp varying_count_modules(event_lists) do
    counts =
      Enum.map(event_lists, fn events ->
        Enum.frequencies_by(events, & &1.__struct__)
      end)

    modules = counts |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

    for mod <- modules,
        counts |> Enum.map(&Map.get(&1, mod, 0)) |> Enum.uniq() |> length() > 1,
        into: MapSet.new(),
        do: mod
  end

  defp events_at(trace, position) do
    trace
    |> RunTrace.event_entries_at(position)
    |> Enum.map(& &1.event)
  end

  defp event_row_fields(row, row_index, position, minted, varying) do
    module = row_module(row)
    row_absent? = Enum.any?(Map.values(row.events), &(&1 == :absent))
    repetition? = row_absent? and module != nil and MapSet.member?(varying, module)

    keys =
      row.events
      |> Map.values()
      |> Enum.reject(&(&1 == :absent))
      |> Enum.flat_map(&struct_keys/1)
      |> Enum.uniq()

    Enum.map(keys, fn key ->
      values =
        Map.new(row.events, fn {i, ev} ->
          {i, if(ev == :absent, do: :absent, else: Map.get(ev, key, :absent))}
        end)

      provenance =
        if module,
          do: event_field_provenance(module, [key], values, minted),
          else: :server_resolved

      %Field{
        location: {:event, position, row.key, row_index, [key]},
        provenance: provenance,
        values: values,
        differs?: differs?(values),
        incidental_override: repetition?
      }
    end)
  end

  defp row_module(row) do
    row.events |> Map.values() |> Enum.find_value(fn ev -> ev != :absent and ev.__struct__ end)
  end

  defp struct_keys(%{__struct__: _} = s), do: s |> Map.from_struct() |> Map.keys()
  defp struct_keys(_), do: []

  defp event_field_provenance(module, path, values, minted) do
    cond do
      path in external_paths(module) ->
        :server_resolved

      Enum.any?(Map.values(values), &(&1 != :absent and MapSet.member?(minted, &1))) ->
        :run_scoped

      true ->
        :server_resolved
    end
  end

  defp external_paths(module) do
    External.external_paths(module)
  rescue
    _ -> []
  end

  # ---- State fields (P8 / DR-040) -------------------------------------------

  # Max nesting depth we flatten projection state into distinct leaf paths;
  # deeper subtrees compare as a single opaque leaf. Bounds field count on deeply
  # nested state.
  @state_max_depth 5
  # Max children of a single map/list we expand into per-key/index leaves; a
  # wider container compares as one opaque leaf (a large collection is a poor
  # per-element diff subject and would explode the field set).
  @state_max_fanout 64

  # One field per LEAF path of each projection's canonical state, valued by each
  # trace's canonical state at this position. Provenance is always
  # `:server_resolved`: derived state is the analysis subject, never a run-scoped
  # correlation id or a plan-generated comparability violation.
  defp state_fields(traces, position, canonical_states) do
    reference_state = state_at(canonical_states, 0, position)

    reference_state
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn projection ->
      reference_state
      |> Map.fetch!(projection)
      |> state_leaves([], @state_max_depth)
      |> Enum.map(fn {path, _reference_value} ->
        values =
          traces
          |> Enum.with_index()
          |> Map.new(fn {_trace, i} ->
            module_state = canonical_states |> state_at(i, position) |> Map.get(projection)
            {i, state_value_at(module_state, path)}
          end)

        %Field{
          location: {:state, position, projection, path},
          provenance: :server_resolved,
          values: values,
          differs?: differs?(values)
        }
      end)
    end)
  end

  defp state_at(canonical_states, trace_index, position) do
    canonical_states |> Map.get(trace_index, %{}) |> Map.get(position, %{})
  end

  # Flatten a projection state value into {leaf_path, value} pairs, bounded by
  # depth and fan-out; beyond either bound the subtree is one opaque leaf.
  defp state_leaves(value, path, depth) when depth <= 0, do: [{Enum.reverse(path), value}]

  defp state_leaves(%_{} = struct, path, depth),
    do: struct |> Map.from_struct() |> state_leaves(path, depth)

  defp state_leaves(map, path, depth) when is_map(map) do
    if map_size(map) > @state_max_fanout do
      [{Enum.reverse(path), map}]
    else
      map
      |> Enum.sort_by(fn {k, _} -> inspect(k) end)
      |> Enum.flat_map(fn {k, v} -> state_leaves(v, [k | path], depth - 1) end)
    end
  end

  defp state_leaves(list, path, depth) when is_list(list) do
    if length(list) > @state_max_fanout do
      [{Enum.reverse(path), list}]
    else
      list
      |> Enum.with_index()
      |> Enum.flat_map(fn {v, i} -> state_leaves(v, [i | path], depth - 1) end)
    end
  end

  defp state_leaves(scalar, path, _depth), do: [{Enum.reverse(path), scalar}]

  # Read a value at a flattened state path; `:absent` when the path is missing
  # (state shapes can differ across runs). Mirrors `state_leaves` descent.
  defp state_value_at(value, []), do: value
  defp state_value_at(nil, _path), do: :absent

  defp state_value_at(%_{} = struct, path),
    do: struct |> Map.from_struct() |> state_value_at(path)

  defp state_value_at(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> state_value_at(v, rest)
      :error -> :absent
    end
  end

  defp state_value_at(list, [index | rest]) when is_list(list) and is_integer(index) do
    case Enum.fetch(list, index) do
      {:ok, v} -> state_value_at(v, rest)
      :error -> :absent
    end
  end

  defp state_value_at(_value, _path), do: :absent

  # Advisory (not a comparability violation): a projection whose canonical state
  # varies WITHIN an outcome group is a likely non-pure projection — same plan,
  # same outcome, different derived state. `investigate/1` / `scan/1` surface it
  # so a flaky "state divergence" is not mistaken for a real behavioral one.
  defp state_warnings(fields, groups) do
    group_index_lists = [groups.passing, groups.failing]

    fields
    |> Enum.filter(fn field ->
      match?({:state, _, _, _}, field.location) and
        Enum.any?(group_index_lists, fn indices -> varies?(present_at(field.values, indices)) end)
    end)
    |> Enum.map(fn %Field{location: {:state, _pos, projection, _path}} -> projection end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ---- Classification -------------------------------------------------------

  defp differs?(values) do
    present = values |> Map.values() |> Enum.reject(&(&1 == :absent))
    absent? = Enum.any?(Map.values(values), &(&1 == :absent))
    length(Enum.uniq(present)) > 1 or (absent? and present != [])
  end

  defp classify(%Field{differs?: false} = field, _groups),
    do: %{field | classification: :uniform}

  defp classify(%Field{incidental_override: true} = field, _groups),
    do: %{field | classification: :incidental}

  defp classify(%Field{provenance: :run_scoped} = field, _groups),
    do: %{field | classification: :incidental}

  defp classify(%Field{provenance: :plan_generated} = field, _groups),
    do: %{field | classification: :comparability_violation}

  defp classify(%Field{} = field, %{passing: passing, failing: failing}) do
    pass_vals = present_at(field.values, passing)
    fail_vals = present_at(field.values, failing)

    classification =
      cond do
        varies?(pass_vals) or varies?(fail_vals) -> :incidental
        discriminates?(pass_vals, fail_vals) -> :discriminating
        true -> :weak
      end

    %{field | classification: classification}
  end

  defp present_at(values, indices) do
    indices |> Enum.map(&Map.get(values, &1, :absent)) |> Enum.reject(&(&1 == :absent))
  end

  defp varies?(vals), do: length(Enum.uniq(vals)) > 1

  # Stable within each (non-empty) group, but the groups disagree.
  defp discriminates?(pass_vals, fail_vals) do
    pass_vals != [] and fail_vals != [] and
      Enum.uniq(pass_vals) != Enum.uniq(fail_vals)
  end

  defp rank(fields) do
    fields
    |> Enum.filter(&(&1.classification == :discriminating))
    |> Enum.sort_by(&location_sort_key(&1.location))
  end

  # Stable ranking: by section, then offset, commands before events.
  defp location_sort_key({:command, %Sequence.Position{} = p, path}),
    do: {section_rank(p.section), p.offset, 0, inspect(path)}

  defp location_sort_key({:event, %Sequence.Position{} = p, _key, row_index, path}),
    do: {section_rank(p.section), p.offset, 1 + row_index, inspect(path)}

  # State findings sort after this step's commands and events (they are the
  # consequence of them). The `:state` atom in the third slot sorts after any
  # integer command/event rank (Erlang term order: number < atom), regardless of
  # how many event rows a position has.
  defp location_sort_key({:state, %Sequence.Position{} = p, projection, path}),
    do: {section_rank(p.section), p.offset, :state, inspect({projection, path})}

  defp section_rank(:prefix), do: {0, 0}
  defp section_rank({:branch, b}), do: {1, b}
  defp section_rank(:suffix), do: {2, 0}

  # ---- Header ---------------------------------------------------------------

  defp build_header([reference | _] = traces) do
    %{
      model: reference.model,
      adapter: reference.adapter,
      plan_fingerprint: reference.plan_fingerprint,
      source_revision: reference.source_revision,
      timestamp: reference.timestamp,
      runs:
        Enum.map(traces, fn t ->
          %{
            seed: t.seed,
            run_number: t.run_number,
            run_nonce: t.run_nonce,
            mint_epoch: t.mint_epoch,
            plan_source: t.plan_source,
            outcome: outcome_tag(t.outcome)
          }
        end)
    }
  end

  defp outcome_tag(:pass), do: :pass
  defp outcome_tag({:fail, _}), do: :fail
  defp outcome_tag(_), do: :unknown
end
