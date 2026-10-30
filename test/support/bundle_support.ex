defmodule PropertyDamage.Test.BundleSupport do
  @moduledoc false
  # Fixtures and readers for the JSON bundle that every HTML failure page
  # carries in a second script tag.
  #
  # The bundle and redaction modules are reached through `bundle/0` and
  # `redaction/0`, which fail the calling test when the module is missing
  # and hand back the module in a variable, so a test file compiles whether
  # or not the module exists.
  #
  # `parse/2` reads the ids a page declares from the terminal text the page
  # embeds, with no help from the bundle: the Failure labels, the labels of
  # "What this checks", the steps and events of each listing, and the `## `
  # headings. A test compares what it reads with the bundle's `ids`.
  #
  # `define/1` writes a small system (an event, a command, two projections, a
  # model and an adapter) to a file under a fresh tmp dir and compiles that
  # file, so each module has a real `file` that a test can read, change or
  # delete.

  import ExUnit.Assertions

  alias PropertyDamage.{Docs, Failure, FailureReport, Sequence}
  alias PropertyDamage.FailureReport.HTML
  alias PropertyDamage.Test.{ContextSection, DocsHelpers, TmpPath}
  alias PropertyDamage.Test.ReportLayout

  # ==========================================================================
  # The modules under test
  # ==========================================================================

  @doc "The bundle module; fails the test when it does not exist."
  def bundle, do: loaded!(Module.concat(["PropertyDamage", "FailureReport", "Bundle"]))

  @doc "The redaction module; fails the test when it does not exist."
  def redaction,
    do: loaded!(Module.concat(["PropertyDamage", "FailureReport", "Bundle", "Redaction"]))

  defp loaded!(module) do
    assert Code.ensure_loaded?(module), "the module #{inspect(module)} does not exist"
    module
  end

  @doc """
  The bundle of `report` as the page carries it: built with `Bundle.build/2`,
  then through JSON, so every key is a string.
  """
  def build(report, opts \\ []) do
    mod = bundle()
    assert function_exported?(mod, :build, 2), "#{inspect(mod)}.build/2 is not defined"

    report
    |> then(&mod.build(&1, opts))
    |> Jason.encode!()
    |> Jason.decode!()
  end

  @doc "`Redaction.redact/1`: the redacted text and the number of literals replaced."
  def redact(text) do
    mod = redaction()
    assert function_exported?(mod, :redact, 1), "#{inspect(mod)}.redact/1 is not defined"

    case mod.redact(text) do
      {redacted, count} when is_binary(redacted) and is_integer(count) -> {redacted, count}
      other -> flunk("redact/1 must return {text, count}, got: #{inspect(other, limit: 5)}")
    end
  end

  # ==========================================================================
  # The page
  # ==========================================================================

  @tag_pattern ~r{<script type="application/json" id="pd-bundle">(.*?)</script>}s

  @doc "The content of every bundle script tag of the page, as a list."
  def bundle_tags(html), do: for([_, content] <- Regex.scan(@tag_pattern, html), do: content)

  @doc "The number of times the page declares a script with the id `pd-bundle`."
  def bundle_id_count(html), do: length(Regex.scan(~r/id="pd-bundle"/, html))

  @doc "The bundle the page carries, decoded; fails the test unless there is exactly one."
  def page_bundle(html) do
    assert bundle_id_count(html) == 1, "the page must declare id=\"pd-bundle\" exactly once"
    assert [content] = bundle_tags(html), "the page must carry one bundle script tag"
    Jason.decode!(content)
  end

  @doc "The terminal text the page embeds."
  def page_text(report), do: ContextSection.html_text(report)

  @doc "The number of `<script` openings and `</script>` closings of a page."
  def script_counts(html) do
    {length(Regex.scan(~r/<script/, html)), length(Regex.scan(~r{</script>}, html))}
  end

  @doc "Every string in `term`, at any depth, keys excluded."
  def strings(term) when is_binary(term), do: [term]
  def strings(term) when is_map(term), do: term |> Map.values() |> Enum.flat_map(&strings/1)
  def strings(term) when is_list(term), do: Enum.flat_map(term, &strings/1)
  def strings(_other), do: []

  @doc "A count that is an integer, or a map holding the integer under `count`."
  def count_of(count) when is_integer(count), do: count
  def count_of(%{"count" => count}) when is_integer(count), do: count
  def count_of(other), do: flunk("not a count: #{inspect(other, limit: 5)}")

  # ==========================================================================
  # Reading the page text
  # ==========================================================================

  # The marker of the failing step and the arrow after its command, written
  # as escapes so that this file stays ASCII.
  @marker "\u25BA"
  @arrow "\u25C4\u2500\u2500"
  @step Regex.compile!(
          "^(?:#{@marker} |  )\\s*(\\[(?:setup |teardown |branch )?\\d+(?:\\.\\d+)*\\])(.*)$",
          "u"
        )
  @event ~r/^\s+\+[\d.]+s event (.*)$/
  @note ~r/^  (?:adapter setup\/1|adapter teardown\/1|Not tied to a command|\(.*\))$/
  @header ~r/^(Reference|Variant): target "(.*)"$/
  @struct ~r/%([A-Za-z0-9_.]+)\{/

  @doc """
  What the page text declares. `default_name` is the target a listing without
  a header belongs to. Returns `%{headings:, failure:, context:, targets:,
  lines:, events:}`:

    * `headings` - the `## ` headings in order
    * `failure` - the labels of the Failure section in order, repeats included
    * `context` - the labels of "What this checks" in order, `[]` without it
    * `targets` - `[%{name:, role:, steps: [%{label:, command:, failed:,
      events: [module name]}]}]` in page order
    * `lines` - the printed step lines and the printed first line of every
      event, trimmed
    * `events` - the module names of every event printed under a step
  """
  def parse(text, default_name) do
    lines = String.split(text, "\n")

    %{
      headings: for("## " <> heading <- lines, do: heading),
      failure: failure_labels(lines),
      context: context_labels(lines),
      targets: lines |> listing_lines() |> targets(default_name),
      lines: printed_lines(lines),
      events: for(line <- lines, [_, rest] <- [Regex.run(@event, line)], do: event_module(rest))
    }
  end

  defp section(lines, title) do
    case Enum.drop_while(lines, &(&1 != "## " <> title)) do
      [] -> nil
      [_heading | rest] -> Enum.take_while(rest, &(not String.starts_with?(&1, "## ")))
    end
  end

  defp failure_labels(lines) do
    for line <- section(lines, "Failure") || [],
        line != "",
        not String.starts_with?(line, " "),
        do: line |> String.split("  ", parts: 2) |> hd()
  end

  defp context_labels(lines) do
    case section(lines, "What this checks") do
      nil -> []
      body -> ContextSection.labels(body)
    end
  end

  defp listing_lines(lines) do
    case Enum.find_index(lines, &String.starts_with?(&1, "## Minimal Reproduction")) do
      nil ->
        []

      index ->
        lines
        |> Enum.drop(index + 1)
        |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    end
  end

  defp targets(lines, default_name) do
    {targets, _state} =
      Enum.reduce(lines, {[], %{step: nil, pending: false}}, fn line, {targets, state} ->
        cond do
          match = Regex.run(@header, line) ->
            [_, role, name] = match
            {[%{name: name, role: String.downcase(role), steps: []} | targets], reset(state)}

          match = Regex.run(@step, line) ->
            [_, label, rest] = match
            targets = ensure_target(targets, default_name)
            command = command_of(rest)

            step = %{
              label: label,
              command: command,
              failed: String.contains?(rest, @arrow),
              events: []
            }

            {add_step(targets, step), %{step: label, pending: is_nil(command)}}

          Regex.match?(@note, line) ->
            {targets, reset(state)}

          match = Regex.run(@event, line) ->
            [_, rest] = match
            {add_event(targets, state.step, event_module(rest)), state}

          state.pending and Regex.match?(~r/^\s+%[A-Za-z0-9_.]+\{/, line) ->
            {set_command(targets, command_of(line)), %{state | pending: false}}

          true ->
            {targets, state}
        end
      end)

    targets |> Enum.map(&%{&1 | steps: Enum.reverse(&1.steps)}) |> Enum.reverse()
  end

  defp reset(state), do: %{state | step: nil, pending: false}

  defp ensure_target([], default_name), do: [%{name: default_name, role: "variant", steps: []}]
  defp ensure_target(targets, _default_name), do: targets

  defp command_of(text) do
    case Regex.run(@struct, text) do
      [_, module] -> module
      nil -> nil
    end
  end

  defp event_module(text), do: command_of(text)

  defp add_step([target | rest], step), do: [%{target | steps: [step | target.steps]} | rest]

  defp set_command([%{steps: [step | steps]} = target | rest], command),
    do: [%{target | steps: [%{step | command: command} | steps]} | rest]

  defp add_event([%{steps: [_ | _]} = target | rest], label, module) when not is_nil(label) do
    steps =
      Enum.map(target.steps, fn
        %{label: ^label, events: events} = step -> %{step | events: events ++ [module]}
        step -> step
      end)

    [%{target | steps: steps} | rest]
  end

  defp add_event(targets, _label, _module), do: targets

  defp printed_lines(lines) do
    for line <- listing_lines(lines),
        Regex.match?(@step, line) or Regex.match?(@event, line),
        do: String.trim(line)
  end

  @doc """
  The hand-built branching report, given one target whose name holds a space
  (the report as built names no target).
  """
  def branching_report do
    report = ReportLayout.report(:branching)

    %{report | targets: [{PropertyDamage.Test.Compare.PayAdapter, [name: "my app", config: %{}]}]}
  end

  @doc "The name a listing without a header carries: the failing target's."
  def default_name(%FailureReport{variant: %{name: name}}), do: name

  def default_name(%FailureReport{targets: [{_adapter, entry} | _]}),
    do: Keyword.get(entry, :name)

  @doc "The label of each id: the first occurrence bare, later ones with `:2`, `:3`."
  def with_ordinals(labels) do
    {ids, _seen} =
      Enum.map_reduce(labels, %{}, fn label, seen ->
        n = Map.get(seen, label, 0) + 1
        {if(n == 1, do: label, else: "#{label}:#{n}"), Map.put(seen, label, n)}
      end)

    ids
  end

  @doc """
  The ids the page declares, read from its text: `failure:`, `context:`,
  `step:`, `entry:` and `section:` ids, in no particular order.
  """
  def expected_ids(parsed) do
    steps =
      for target <- parsed.targets,
          step <- target.steps,
          id <- ["step:#{target.name}:#{step.label}" | entry_ids(target, step)],
          do: id

    Enum.map(with_ordinals(parsed.failure), &"failure:#{&1}") ++
      Enum.map(with_ordinals(parsed.context), &"context:#{&1}") ++
      steps ++ Enum.map(parsed.headings, &"section:#{&1}")
  end

  defp entry_ids(target, step) do
    for n <- Enum.to_list(1..length(step.events)//1),
        do: "entry:#{target.name}:#{step.label}:#{n}"
  end

  # ==========================================================================
  # Reading the bundle
  # ==========================================================================

  @doc """
  Every id the bundle declares in the places that carry one: the Failure
  fields, the context items, the listing, the sections and the functions of
  the modules.
  """
  def declared_ids(bundle) do
    sections = for %{"id" => id} <- bundle["sections"], do: id

    functions =
      for module <- bundle["modules"],
          %{"id" => id} <- module["functions"],
          is_binary(id),
          do: id

    ids_in(bundle["failure"]) ++
      ids_in(bundle["context"]) ++ ids_in(bundle["listing"]) ++ sections ++ functions
  end

  defp ids_in(%{} = map) do
    Enum.flat_map(map, fn
      {"id", id} when is_binary(id) -> [id]
      {_key, value} -> ids_in(value)
    end)
  end

  defp ids_in(list) when is_list(list), do: Enum.flat_map(list, &ids_in/1)
  defp ids_in(_other), do: []

  @doc "The module entry of `module` in the bundle, or fails the test."
  def module_entry(bundle, module) do
    name = inspect(module)

    case Enum.find(bundle["modules"], &(&1["module"] == name)) do
      nil -> flunk("the bundle holds no module #{name}")
      entry -> entry
    end
  end

  @doc "The function entry `name/arity` of a module entry, or fails the test."
  def function_entry(entry, name, arity) do
    case Enum.find(entry["functions"], &(&1["name"] == to_string(name) and &1["arity"] == arity)) do
      nil -> flunk("#{entry["module"]} holds no function #{name}/#{arity}")
      function -> function
    end
  end

  @doc """
  The `source:` ids `Docs.fetch/1` implies for the module of a bundle entry.

  A function that a macro injects has no line in the file to cite, so it
  gets no id. This reads the definitions straight from the file with
  regexes: it finds the module's `defmodule` line and the `end` at the same
  indentation, and leaves out a function whose name no `def`-like line one
  level inside that block names. When the file cannot be read, every
  function keeps its id.
  """
  def source_ids(%{"module" => name} = entry) do
    module = Module.concat([name])

    case Docs.fetch(module) do
      {:ok, %{functions: functions}} ->
        defined? = defined_in(entry["file"], module)

        for {{function, arity}, _doc} <- functions,
            defined?.(function),
            do: "source:#{inspect(module)}.#{function}/#{arity}"

      :unavailable ->
        []
    end
  end

  @definition "(def|defp|defmacro|defmacrop|defdelegate|defguard|defguardp)"

  defp defined_in(file, module) do
    case is_binary(file) && File.read(file) do
      {:ok, text} ->
        {indent, body} = module_block(text, module)

        fn function ->
          name = Regex.escape(to_string(function))
          Regex.match?(~r/^#{indent}#{@definition}\s+#{name}(\(|\s|,|$)/m, body)
        end

      _unreadable ->
        fn _function -> true end
    end
  end

  # The lines of the module's `defmodule` block and the indentation of its
  # top-level definitions; the whole file at any indentation when the block
  # is not found.
  defp module_block(text, module) do
    last = module |> Module.split() |> List.last() |> Regex.escape()
    lines = String.split(text, "\n")
    opening = ~r/^(\s*)defmodule ([\w.]+\.)?#{last} do\s*$/

    case Enum.find_index(lines, &Regex.match?(opening, &1)) do
      nil ->
        {"\\s*", text}

      start ->
        [_, indent | _] = Regex.run(opening, Enum.at(lines, start))
        block = Enum.drop(lines, start + 1)
        stop = Enum.find_index(block, &(&1 == indent <> "end")) || length(block)
        {Regex.escape(indent <> "  "), block |> Enum.take(stop) |> Enum.join("\n")}
    end
  end

  @doc "The number of lines of a file, as an editor counts them."
  def line_count(path), do: path |> File.stream!() |> Enum.count()

  @doc "The 1-based number of the first line of `text` that matches `pattern`."
  def line_of(text, pattern) do
    index = text |> String.split("\n") |> Enum.find_index(&String.match?(&1, pattern))
    assert index, "no line matches #{inspect(pattern)}"
    index + 1
  end

  # ==========================================================================
  # Compiled systems
  # ==========================================================================

  @doc "A fresh tmp dir, removed when the test ends."
  def tmp_dir(prefix \\ "pd_bundle") do
    dir = TmpPath.unique(prefix)
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc """
  Writes `source` to `name` under a fresh tmp dir, compiles the file and
  removes the modules when the test ends. Returns `%{file:, dir:, source:,
  modules: [module]}`.
  """
  def compile_file(source, name \\ "source.ex") do
    dir = tmp_dir()
    file = Path.join(dir, name)
    File.write!(file, source)
    compiled = Code.compile_file(file)
    ExUnit.Callbacks.on_exit(fn -> DocsHelpers.purge(compiled) end)
    %{file: file, dir: dir, source: source, modules: Enum.map(compiled, &elem(&1, 0))}
  end

  @doc "A name part that is unique per OS process and per call."
  def suffix, do: DocsHelpers.suffix()

  @system ~S'''
  defmodule __P__.Paid do
    @moduledoc "__EVENT_DOC__"
    defstruct [:n, :amount, :by]
  end

  defmodule __P__.Pay do
    @moduledoc "Pays bob from alice."
    use PropertyDamage.Command
    defstruct [:n, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0), amount: StreamData.integer(1..9)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule __P__.Counter do
    @moduledoc "Counts the commands."
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %__P__.Pay{}), do: %{state | count: state.count + 1}
    def apply(state, _other), do: state
  end

  defmodule __P__.Ledger do
    @moduledoc "Keeps what alice paid."
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{paid: 0}

    @impl true
    def apply(state, %__P__.Paid{amount: amount}), do: %{state | paid: state.paid + amount}
    def apply(state, _other), do: state

    @check every: __P__.Paid
    @doc "A payment is never negative."
    def assert_not_negative(_state, %__P__.Paid{amount: amount}),
      do: amount >= 0 or PropertyDamage.fail!("negative payment", amount: amount)
  end

  defmodule __P__.Model do
    @moduledoc "__MODEL_DOC__"
    use PropertyDamage.Model

    @impl true
    def commands, do: [{__P__.Pay, overrides: &number/1}]

    @impl true
    def command_sequence_projection, do: __P__.Counter

    @impl true
    def check_projections, do: [__P__.Ledger]

    # __MODEL_LINE__
    __MODEL_EXTRA__
    defp number(state), do: %{n: state.count}
  end
  '''

  @adapter ~S'''
  defmodule __P__.Adapter do
    @moduledoc "The adapter of the ledger."
    require PropertyDamage
    __ADAPTER_HEAD__
    __ADAPTER_EXTRA__

    @impl true
    def setup(config) do
      if config[:log_setup], do: PropertyDamage.log("logging in alice", tags: [:setup])
      {:ok, config}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%__P__.Pay{n: n, amount: amount}, ctx, _runtime) do
      amount = if ctx[:negative], do: -amount, else: amount
      {:ok, [%__P__.Paid{n: n, amount: amount, by: ctx.name}]}
    end
  end
  '''

  @doc """
  Writes the small system to a file, and its adapter to a second file, and
  compiles both. The adapter has a file of its own so that a secret in the
  adapter's source reaches no other module's source. Options:

    * `:adapter_extra` - source lines placed at the top of the adapter
    * `:model_extra` - source lines placed in the model, before its private
      function
    * `:event_doc`, `:model_doc` - the moduledocs of the event and the model
    * `:model_line` - a comment line in the model (for a source line check)
    * `:adapter` - `:use` (default) for `use PropertyDamage.Adapter`, or
      `:bare` for `@behaviour PropertyDamage.Adapter` with the callbacks
      written out

  Returns the modules by name, the `file` and `source` of the system and the
  `adapter_file` and `adapter_source` of the adapter.
  """
  def define(opts \\ []) do
    prefix = "PropertyDamage.Test.Bundle#{suffix()}"

    head =
      case Keyword.get(opts, :adapter, :use) do
        :use ->
          "use PropertyDamage.Adapter"

        :bare ->
          "@behaviour PropertyDamage.Adapter\n  @impl true\n  def timeout(_command), do: 30"
      end

    fill = fn template ->
      template
      |> String.replace("__ADAPTER_HEAD__", head)
      |> String.replace("__ADAPTER_EXTRA__", Keyword.get(opts, :adapter_extra, ""))
      |> String.replace("__MODEL_EXTRA__", Keyword.get(opts, :model_extra, ""))
      |> String.replace("__EVENT_DOC__", Keyword.get(opts, :event_doc, "Alice paid bob."))
      |> String.replace("__MODEL_DOC__", Keyword.get(opts, :model_doc, "The ledger model."))
      |> String.replace("__MODEL_LINE__", Keyword.get(opts, :model_line, "the model"))
      |> String.replace("__P__", prefix)
    end

    source = fill.(@system)
    adapter_source = fill.(@adapter)

    compiled = compile_file(source, "system.ex")
    adapter = compile_file(adapter_source, "adapter.ex")

    Map.merge(compiled, %{
      adapter_file: adapter.file,
      adapter_source: adapter_source,
      modules: compiled.modules ++ adapter.modules,
      prefix: prefix,
      model: Module.concat([prefix, "Model"]),
      adapter: Module.concat([prefix, "Adapter"]),
      ledger: Module.concat([prefix, "Ledger"]),
      counter: Module.concat([prefix, "Counter"]),
      pay: Module.concat([prefix, "Pay"]),
      paid: Module.concat([prefix, "Paid"])
    })
  end

  @doc "A target of the system's adapter named `name`."
  def target(system, name, config \\ %{}),
    do: {system.adapter, [name: name, config: Map.merge(%{name: name}, config)]}

  @doc """
  Runs the system against `targets` (one that pays a negative amount makes
  the ledger check fail) and returns the failure report.
  """
  def run(system, targets \\ nil, extra \\ []) do
    opts =
      Keyword.merge(
        [
          model: system.model,
          targets: targets || [target(system, "alice", %{negative: true})],
          max_runs: 1,
          max_commands: 3,
          seed: 4_242,
          validate: false,
          shrink: false,
          replay_dir: false,
          compare: [converge_within: 50]
        ],
        extra
      )

    case PropertyDamage.run(opts) do
      {:error, %FailureReport{} = report} -> report
      other -> flunk("the run did not fail: #{inspect(other, limit: 5)}")
    end
  end

  @doc """
  A failure report built by hand for `model` and the adapters in `targets`
  (`[{adapter, name}]`): a poll error before the first command, which needs
  no run.
  """
  def hand_report(model, targets) do
    sequence = Sequence.linear([%PropertyDamage.Test.Compare.Pay{n: 0, amount: 3}])

    FailureReport.new(
      seed: 1,
      run_number: 0,
      original_sequence: sequence,
      shrunk_sequence: sequence,
      failed_at_index: nil,
      failure_reason: Failure.poll_error(:await_timeout),
      model: model,
      targets: for({adapter, name} <- targets, do: {adapter, [name: name, config: %{name: name}]})
    )
  end

  @doc "The page of `report`."
  def render(report), do: HTML.render(report)
end
