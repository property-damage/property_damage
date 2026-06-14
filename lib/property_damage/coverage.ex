defmodule PropertyDamage.Coverage do
  @moduledoc """
  Track and report coverage metrics for property-based tests.

  Coverage helps you understand how thoroughly your model is being exercised:

  - **Command coverage**: Which commands have been tested?
  - **Transition coverage**: Which command sequences have been tested?
  - **State coverage**: Which projection states have been reached?

  ## Usage

      # Enable coverage tracking
      {:ok, result} = PropertyDamage.run(model: M, adapter: A, coverage: true)

      # Get coverage report
      coverage = PropertyDamage.Coverage.from_result(result)
      IO.puts(PropertyDamage.Coverage.format(coverage))

      # Or track across multiple runs
      tracker = Coverage.new(M)
      tracker = Coverage.record(tracker, result1)
      tracker = Coverage.record(tracker, result2)
      IO.puts(Coverage.format(tracker))

  ## Coverage Metrics

  - **Command coverage**: Percentage of commands that were executed at least once
  - **Command frequency**: How often each command was executed
  - **Transition coverage**: Which command pairs (A → B) have been tested
  - **State coverage**: Unique projection states reached (by hash)
  - **Check coverage**: Which checks have been exercised

  ## CI Integration

  Use `Coverage.meets_threshold?/2` to fail CI if coverage is too low:

      coverage = Coverage.from_result(result)
      unless Coverage.meets_threshold?(coverage, command: 80, transition: 50) do
        raise "Coverage threshold not met"
      end
  """

  alias PropertyDamage.{Sequence, EventLog.Entry}

  defstruct [
    :model,
    :command_modules,
    :command_counts,
    :transition_counts,
    :state_hashes,
    :check_hits,
    :total_commands,
    :total_runs,
    :failures_found,
    # State class tracking
    :state_classifier,
    :state_class_counts,
    :state_class_transitions,
    :last_state_class
  ]

  @type state_classifier :: (map() -> atom() | String.t()) | nil

  @type t :: %__MODULE__{
          model: module(),
          command_modules: MapSet.t(module()),
          command_counts: %{module() => non_neg_integer()},
          transition_counts: %{{module(), module()} => non_neg_integer()},
          state_hashes: MapSet.t(integer()),
          check_hits: %{module() => non_neg_integer()},
          total_commands: non_neg_integer(),
          total_runs: non_neg_integer(),
          failures_found: non_neg_integer(),
          # State class tracking
          state_classifier: state_classifier(),
          state_class_counts: %{atom() => non_neg_integer()},
          state_class_transitions: %{{atom(), atom()} => non_neg_integer()},
          last_state_class: atom() | nil
        }

  @doc """
  Create a new coverage tracker for a model.

  ## Options

  - `:state_classifier` - Function to classify states into abstract classes.
    The function receives the projection state map and returns an atom or string
    identifying the state class.

  ## Example

      # Track coverage with state classes
      classifier = fn state ->
        cond do
          state.balance == 0 -> :zero_balance
          state.balance > 0 -> :positive_balance
          state.balance < 0 -> :negative_balance
        end
      end

      tracker = Coverage.new(MyModel, state_classifier: classifier)
  """
  @spec new(module(), keyword()) :: t()
  def new(model, opts \\ []) do
    command_modules =
      model.commands()
      |> Enum.map(fn {_weight, cmd} -> cmd end)
      |> MapSet.new()

    %__MODULE__{
      model: model,
      command_modules: command_modules,
      command_counts: %{},
      transition_counts: %{},
      state_hashes: MapSet.new(),
      check_hits: %{},
      total_commands: 0,
      total_runs: 0,
      failures_found: 0,
      state_classifier: Keyword.get(opts, :state_classifier),
      state_class_counts: %{},
      state_class_transitions: %{},
      last_state_class: nil
    }
  end

  @doc """
  Record coverage from a test run result.

  Works with both success and failure results.
  """
  @spec record(t(), {:ok, map()} | {:error, PropertyDamage.FailureReport.t()}) :: t()
  def record(tracker, {:ok, result}) do
    record_from_data(tracker, result.sequence, result.event_log, result.projections, false)
  end

  def record(tracker, {:error, failure}) do
    record_from_data(
      tracker,
      failure.shrunk_sequence,
      failure.event_log,
      failure.state_at_failure || %{},
      true
    )
  end

  @doc """
  Build coverage from a single result (convenience function).
  """
  @spec from_result({:ok, map()} | {:error, PropertyDamage.FailureReport.t()}, module()) :: t()
  def from_result(result, model) do
    model
    |> new()
    |> record(result)
  end

  @doc """
  Merge two coverage trackers.

  Useful for combining coverage from parallel test runs.
  """
  @spec merge(t(), t()) :: t()
  def merge(tracker1, tracker2) do
    %__MODULE__{
      model: tracker1.model,
      command_modules: MapSet.union(tracker1.command_modules, tracker2.command_modules),
      command_counts: merge_counts(tracker1.command_counts, tracker2.command_counts),
      transition_counts: merge_counts(tracker1.transition_counts, tracker2.transition_counts),
      state_hashes: MapSet.union(tracker1.state_hashes, tracker2.state_hashes),
      check_hits: merge_counts(tracker1.check_hits, tracker2.check_hits),
      total_commands: tracker1.total_commands + tracker2.total_commands,
      total_runs: tracker1.total_runs + tracker2.total_runs,
      failures_found: tracker1.failures_found + tracker2.failures_found,
      state_classifier: tracker1.state_classifier || tracker2.state_classifier,
      state_class_counts:
        merge_counts(tracker1.state_class_counts || %{}, tracker2.state_class_counts || %{}),
      state_class_transitions:
        merge_counts(
          tracker1.state_class_transitions || %{},
          tracker2.state_class_transitions || %{}
        ),
      last_state_class: nil
    }
  end

  @doc """
  Get command coverage percentage.

  Returns the percentage of defined commands that were executed at least once.
  """
  @spec command_coverage(t()) :: float()
  def command_coverage(%__MODULE__{command_modules: all, command_counts: counts}) do
    total = MapSet.size(all)
    if total == 0, do: 100.0, else: map_size(counts) / total * 100
  end

  @doc """
  Get transition coverage percentage.

  Returns the percentage of possible command pairs that were tested.
  """
  @spec transition_coverage(t()) :: float()
  def transition_coverage(%__MODULE__{command_modules: all, transition_counts: counts}) do
    total_possible = MapSet.size(all) * MapSet.size(all)
    if total_possible == 0, do: 100.0, else: map_size(counts) / total_possible * 100
  end

  @doc """
  Get the number of unique states observed.
  """
  @spec unique_states(t()) :: non_neg_integer()
  def unique_states(%__MODULE__{state_hashes: hashes}), do: MapSet.size(hashes)

  @doc """
  Check if coverage meets specified thresholds.

  ## Options

  - `:command` - Minimum command coverage percentage (default: 0)
  - `:transition` - Minimum transition coverage percentage (default: 0)
  - `:min_commands` - Minimum total commands executed (default: 0)

  ## Example

      Coverage.meets_threshold?(coverage, command: 80, transition: 50)
  """
  @spec meets_threshold?(t(), keyword()) :: boolean()
  def meets_threshold?(tracker, opts \\ []) do
    command_threshold = Keyword.get(opts, :command, 0)
    transition_threshold = Keyword.get(opts, :transition, 0)
    min_commands = Keyword.get(opts, :min_commands, 0)

    command_coverage(tracker) >= command_threshold and
      transition_coverage(tracker) >= transition_threshold and
      tracker.total_commands >= min_commands
  end

  @doc """
  Get commands that haven't been tested yet.
  """
  @spec untested_commands(t()) :: [module()]
  def untested_commands(%__MODULE__{command_modules: all, command_counts: counts}) do
    tested = MapSet.new(Map.keys(counts))
    MapSet.difference(all, tested) |> MapSet.to_list()
  end

  @doc """
  Get the most frequently executed commands.
  """
  @spec top_commands(t(), non_neg_integer()) :: [{module(), non_neg_integer()}]
  def top_commands(%__MODULE__{command_counts: counts}, n \\ 10) do
    counts
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.take(n)
  end

  @doc """
  Get the least frequently executed commands (excluding untested).
  """
  @spec bottom_commands(t(), non_neg_integer()) :: [{module(), non_neg_integer()}]
  def bottom_commands(%__MODULE__{command_counts: counts}, n \\ 10) do
    counts
    |> Enum.sort_by(fn {_, count} -> count end, :asc)
    |> Enum.take(n)
  end

  # ============================================================================
  # State Class Functions
  # ============================================================================

  @doc """
  Get state class counts (requires state_classifier to be set).

  Returns a map of `%{state_class => count}`.
  """
  @spec state_class_counts(t()) :: %{atom() => non_neg_integer()}
  def state_class_counts(%__MODULE__{state_class_counts: counts}) do
    counts || %{}
  end

  @doc """
  Get state class transition counts (requires state_classifier to be set).

  Returns a map of `%{{from_class, to_class} => count}`.
  """
  @spec state_class_transitions(t()) :: %{{atom(), atom()} => non_neg_integer()}
  def state_class_transitions(%__MODULE__{state_class_transitions: transitions}) do
    transitions || %{}
  end

  @doc """
  Get the state class transition matrix.

  Returns `%{from_class => %{to_class => count}}`.
  """
  @spec state_class_matrix(t()) :: %{atom() => %{atom() => non_neg_integer()}}
  def state_class_matrix(%__MODULE__{state_class_counts: counts, state_class_transitions: trans}) do
    counts = counts || %{}
    trans = trans || %{}

    classes = Map.keys(counts) |> Enum.sort()

    # Initialize matrix with zeros
    initial =
      for from <- classes, into: %{} do
        row = for to <- classes, into: %{}, do: {to, 0}
        {from, row}
      end

    # Fill in actual counts
    Enum.reduce(trans, initial, fn {{from, to}, count}, matrix ->
      if Map.has_key?(matrix, from) and Map.has_key?(matrix[from], to) do
        put_in(matrix, [from, to], count)
      else
        matrix
      end
    end)
  end

  @doc """
  Format state class coverage as ASCII art.

  Shows which state class transitions have been tested.
  """
  @spec format_state_class_matrix(t()) :: String.t()
  def format_state_class_matrix(%__MODULE__{state_class_counts: counts} = tracker) do
    counts = counts || %{}

    if map_size(counts) == 0 do
      "  (no state classifier set or no states observed)"
    else
      matrix = state_class_matrix(tracker)
      classes = Map.keys(counts) |> Enum.sort()
      names = Enum.map(classes, &to_string/1)

      max_name_len = names |> Enum.map(&String.length/1) |> Enum.max(fn -> 6 end)
      col_width = max(max_name_len, 6)

      header_padding = String.duplicate(" ", col_width + 2)

      header =
        header_padding <>
          "→ " <>
          (names |> Enum.map_join("  ", &String.pad_trailing(&1, col_width)))

      separator = String.duplicate("─", String.length(header))

      rows =
        Enum.map(classes, fn from ->
          from_name = to_string(from) |> String.pad_trailing(col_width)

          cells =
            Enum.map(classes, fn to ->
              count = get_in(matrix, [from, to]) || 0
              format_cell(count, from == to, col_width)
            end)

          "#{from_name}  #{Enum.join(cells, "  ")}"
        end)

      # Also show counts per state class
      class_counts =
        classes
        |> Enum.map_join("\n", fn c -> "  #{c}: #{Map.get(counts, c, 0)}x" end)

      """
      State Class Transition Matrix
      #{separator}
      #{header}
      #{Enum.join(rows, "\n")}

      State class counts:
      #{class_counts}
      """
    end
  end

  @doc """
  Get detailed statistics.
  """
  @spec stats(t()) :: map()
  def stats(tracker) do
    %{
      command_coverage: command_coverage(tracker),
      transition_coverage: transition_coverage(tracker),
      unique_states: unique_states(tracker),
      total_commands: tracker.total_commands,
      total_runs: tracker.total_runs,
      failures_found: tracker.failures_found,
      state_classes_observed: map_size(tracker.state_class_counts || %{}),
      state_class_transitions_tested: map_size(tracker.state_class_transitions || %{}),
      commands_tested: map_size(tracker.command_counts),
      commands_total: MapSet.size(tracker.command_modules),
      transitions_tested: map_size(tracker.transition_counts),
      untested_commands: untested_commands(tracker)
    }
  end

  @doc """
  Format coverage report for display.

  ## Format Options

  - `:summary` - Brief summary (default)
  - `:matrix` - Transition matrix showing command pairs
  - `:full` - Complete report with matrix and untested transitions
  - `:state_classes` - State class transition matrix (requires state_classifier)

  ## Examples

      Coverage.format(tracker)                # summary
      Coverage.format(tracker, :matrix)       # transition matrix only
      Coverage.format(tracker, :full)         # everything
      Coverage.format(tracker, :state_classes) # state class matrix only
  """
  @spec format(t(), atom()) :: String.t()
  def format(tracker, format \\ :summary)

  def format(tracker, :summary) do
    stats = stats(tracker)

    untested_str =
      case stats.untested_commands do
        [] -> "  (all commands tested)"
        cmds -> cmds |> Enum.map_join("\n", &("  - " <> short_name(&1)))
      end

    top_cmds =
      tracker
      |> top_commands(5)
      |> Enum.map_join("\n", fn {cmd, count} -> "  #{short_name(cmd)}: #{count}x" end)

    """
    ═══════════════════════════════════════════════════════════════
    COVERAGE REPORT
    ═══════════════════════════════════════════════════════════════

    Summary:
      Total runs: #{stats.total_runs}
      Total commands executed: #{stats.total_commands}
      Failures found: #{stats.failures_found}

    Coverage:
      Command coverage: #{Float.round(stats.command_coverage, 1)}% (#{stats.commands_tested}/#{stats.commands_total})
      Transition coverage: #{Float.round(stats.transition_coverage, 1)}% (#{stats.transitions_tested} pairs)
      Unique states observed: #{stats.unique_states}

    Top commands:
    #{top_cmds}

    Untested commands:
    #{untested_str}
    """
  end

  def format(tracker, :matrix) do
    format_transition_matrix(tracker)
  end

  def format(tracker, :full) do
    summary = format(tracker, :summary)
    matrix = format_transition_matrix(tracker)

    untested = untested_transitions(tracker)

    untested_str =
      if untested == [] do
        "  (all transitions tested)"
      else
        untested
        |> Enum.take(10)
        |> Enum.map_join("\n", fn {from, to} -> "  #{short_name(from)} → #{short_name(to)}" end)
      end

    suffix =
      if length(untested) > 10 do
        "\n  ... and #{length(untested) - 10} more"
      else
        ""
      end

    # Include state class matrix if classifier was set
    state_class_section =
      if tracker.state_classifier && map_size(tracker.state_class_counts || %{}) > 0 do
        "\n#{format_state_class_matrix(tracker)}"
      else
        ""
      end

    """
    #{summary}
    Transition Matrix:
    #{matrix}

    Untested Transitions:
    #{untested_str}#{suffix}
    #{state_class_section}
    """
  end

  def format(tracker, :state_classes) do
    format_state_class_matrix(tracker)
  end

  @doc """
  Get transitions (command pairs) that haven't been tested yet.

  Returns list of `{from_command, to_command}` tuples.
  """
  @spec untested_transitions(t()) :: [{module(), module()}]
  def untested_transitions(%__MODULE__{command_modules: all, transition_counts: counts}) do
    tested = MapSet.new(Map.keys(counts))

    for from <- all,
        to <- all,
        pair = {from, to},
        not MapSet.member?(tested, pair) do
      pair
    end
    |> Enum.sort_by(fn {from, to} -> {short_name(from), short_name(to)} end)
  end

  @doc """
  Get most frequently tested transitions.
  """
  @spec top_transitions(t(), non_neg_integer()) :: [{{module(), module()}, non_neg_integer()}]
  def top_transitions(%__MODULE__{transition_counts: counts}, n \\ 10) do
    counts
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.take(n)
  end

  @doc """
  Get the transition matrix as a map.

  Returns `%{from_command => %{to_command => count}}`.
  """
  @spec transition_matrix(t()) :: %{module() => %{module() => non_neg_integer()}}
  def transition_matrix(%__MODULE__{command_modules: all, transition_counts: counts}) do
    # Initialize matrix with zeros
    commands = MapSet.to_list(all) |> Enum.sort_by(&short_name/1)

    initial =
      for from <- commands, into: %{} do
        row = for to <- commands, into: %{}, do: {to, 0}
        {from, row}
      end

    # Fill in actual counts
    Enum.reduce(counts, initial, fn {{from, to}, count}, matrix ->
      if Map.has_key?(matrix, from) and Map.has_key?(matrix[from], to) do
        put_in(matrix, [from, to], count)
      else
        matrix
      end
    end)
  end

  @doc """
  Format the transition matrix as ASCII art.

  Shows which command pairs have been tested:
  - `████` = well-tested (>10 occurrences)
  - `▓▓▓▓` = tested (>5 occurrences)
  - `░░░░` = lightly tested (1-5 occurrences)
  - `    ` = untested

  ## Example

      Transition Matrix
      ───────────────────────────────────────
                    → Create  Credit  Debit
      Create           ·      ████    ████
      Credit         ████       ·     ▓▓▓▓
      Debit          ░░░░    ████       ·
  """
  @spec format_transition_matrix(t()) :: String.t()
  def format_transition_matrix(%__MODULE__{command_modules: all} = tracker) do
    commands = MapSet.to_list(all) |> Enum.sort_by(&short_name/1)

    if commands == [] do
      "  (no commands to display)"
    else
      matrix = transition_matrix(tracker)
      names = Enum.map(commands, &short_name/1)

      # Calculate column width (minimum 6 for the bars)
      max_name_len = names |> Enum.map(&String.length/1) |> Enum.max(fn -> 6 end)
      col_width = max(max_name_len, 6)

      # Header row
      header_padding = String.duplicate(" ", col_width + 2)

      header =
        header_padding <>
          "→ " <>
          (names |> Enum.map_join("  ", &String.pad_trailing(&1, col_width)))

      separator = String.duplicate("─", String.length(header))

      # Data rows
      rows =
        Enum.map(commands, fn from ->
          from_name = short_name(from) |> String.pad_trailing(col_width)

          cells =
            Enum.map(commands, fn to ->
              count = get_in(matrix, [from, to]) || 0
              format_cell(count, from == to, col_width)
            end)

          "#{from_name}  #{Enum.join(cells, "  ")}"
        end)

      """
      Transition Matrix
      #{separator}
      #{header}
      #{Enum.join(rows, "\n")}
      """
    end
  end

  defp format_cell(_count, true, width) do
    # Diagonal (same command twice) - show dot
    String.pad_trailing("·", width)
  end

  defp format_cell(0, false, width) do
    # Untested
    String.pad_trailing("", width)
  end

  defp format_cell(count, false, width) when count >= 10 do
    # Well tested
    String.pad_trailing("████", width)
  end

  defp format_cell(count, false, width) when count >= 5 do
    # Tested
    String.pad_trailing("▓▓▓▓", width)
  end

  defp format_cell(_count, false, width) do
    # Lightly tested
    String.pad_trailing("░░░░", width)
  end

  @doc """
  Export coverage data to JSON for CI integration.
  """
  @spec to_json(t()) :: String.t()
  def to_json(tracker) do
    stats = stats(tracker)

    %{
      command_coverage: stats.command_coverage,
      transition_coverage: stats.transition_coverage,
      unique_states: stats.unique_states,
      total_commands: stats.total_commands,
      total_runs: stats.total_runs,
      failures_found: stats.failures_found,
      untested_commands: Enum.map(stats.untested_commands, &inspect/1),
      command_counts:
        for({cmd, count} <- tracker.command_counts, into: %{}, do: {inspect(cmd), count})
    }
    |> Jason.encode!(pretty: true)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp record_from_data(tracker, sequence, event_log, projections, is_failure) do
    commands = Sequence.to_list(sequence)

    # Count commands
    command_counts =
      Enum.reduce(commands, tracker.command_counts, fn cmd, acc ->
        mod = cmd.__struct__
        Map.update(acc, mod, 1, &(&1 + 1))
      end)

    # Count transitions (consecutive command pairs)
    transition_counts =
      commands
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(tracker.transition_counts, fn [cmd1, cmd2], acc ->
        pair = {cmd1.__struct__, cmd2.__struct__}
        Map.update(acc, pair, 1, &(&1 + 1))
      end)

    # Hash projection states
    state_hashes =
      projections
      |> Enum.map(fn {_proj, state} -> :erlang.phash2(state) end)
      |> Enum.reduce(tracker.state_hashes, &MapSet.put(&2, &1))

    # Count check hits from event log
    check_hits = count_check_hits(event_log, tracker.check_hits)

    # Track state class transitions if classifier is provided
    {state_class_counts, state_class_transitions, last_class} =
      if tracker.state_classifier do
        track_state_classes(
          tracker.state_classifier,
          projections,
          tracker.state_class_counts || %{},
          tracker.state_class_transitions || %{},
          tracker.last_state_class
        )
      else
        {tracker.state_class_counts || %{}, tracker.state_class_transitions || %{},
         tracker.last_state_class}
      end

    %{
      tracker
      | command_counts: command_counts,
        transition_counts: transition_counts,
        state_hashes: state_hashes,
        check_hits: check_hits,
        total_commands: tracker.total_commands + length(commands),
        total_runs: tracker.total_runs + 1,
        failures_found: tracker.failures_found + if(is_failure, do: 1, else: 0),
        state_class_counts: state_class_counts,
        state_class_transitions: state_class_transitions,
        last_state_class: last_class
    }
  end

  defp track_state_classes(classifier, projections, counts, transitions, last_class) do
    # Get the combined state from all projections
    state =
      projections
      |> Enum.reduce(%{}, fn {_proj, proj_state}, acc ->
        Map.merge(acc, proj_state)
      end)

    # Classify the current state
    current_class =
      try do
        classifier.(state)
      rescue
        _ -> :unknown
      end

    # Update counts
    new_counts = Map.update(counts, current_class, 1, &(&1 + 1))

    # Update transitions if we have a previous class
    new_transitions =
      if last_class do
        Map.update(transitions, {last_class, current_class}, 1, &(&1 + 1))
      else
        transitions
      end

    {new_counts, new_transitions, current_class}
  end

  defp count_check_hits(event_log, check_hits) when is_list(event_log) do
    # Extract checks that were run from event log entries
    event_log
    |> Enum.filter(fn
      %Entry{event: %{__struct__: _}} -> true
      _ -> false
    end)
    |> Enum.reduce(check_hits, fn _entry, acc ->
      # This is a simplified version - ideally we'd track which checks ran
      acc
    end)
  end

  defp count_check_hits(_, check_hits), do: check_hits

  defp merge_counts(counts1, counts2) do
    Map.merge(counts1, counts2, fn _k, v1, v2 -> v1 + v2 end)
  end

  defp short_name(module) do
    module |> Module.split() |> List.last()
  end
end
