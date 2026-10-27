defmodule PropertyDamage.Test.ReportLayout do
  @moduledoc false
  # Fixtures and checks for the layout of the terminal and markdown failure
  # report (DR-055): one report per failure kind, built once per VM, and the
  # parsing helpers and checks the layout tests share.
  #
  # `report/1` builds the report of a kind on first use and caches it in
  # `:persistent_term`, so every test file reads the same report. `facts/1`
  # derives, from the report's own fields, what its layout must show: the
  # failing step's label, the outcome word, the number of roots, the compared
  # sides, whether Projections prints, and where `targets` holds a value no
  # source can rebuild. The `assert_*` checks take the rendered text and those
  # facts, so a hand-written text can be checked with a hand-written map.

  import ExUnit.Assertions

  alias PropertyDamage.{EventLog.Entry, Failure, FailureReport, RunTrace, Sequence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.RunTrace.Step
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.{Compare, ExpansionRun, SetupCommands, VariantSupport}
  alias PropertyDamage.Test.Compare.{Paid, Pay, Settled}
  alias PropertyDamage.Test.ReferenceReport, as: R

  # ==========================================================================
  # Projections, commands and adapters
  # ==========================================================================

  defmodule CrashingCheck do
    @moduledoc false
    # A check whose own code raises (a test code error, not a bug in the SUT).
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.Compare.Settled
    def settled_has_currency(_state, %PropertyDamage.Test.Compare.Settled{} = settled) do
      # The key is not a literal, so the compiler does not see it is missing.
      Map.fetch!(Map.from_struct(settled), Enum.random([:currency])) != nil
    end
  end

  defmodule Observations do
    @moduledoc false
    # Three observations of a Pay run compared at every root: the settled
    # total, the fees and the payer. A variant with another fee, another name
    # and a settlement delta differs in all three at once.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{settled: 0, fees: 0, payer: nil}

    @impl true
    def apply(s, %PropertyDamage.Test.Compare.Paid{fee: fee, by: by}),
      do: %{s | fees: s.fees + fee, payer: by}

    def apply(s, %PropertyDamage.Test.Compare.Settled{amount: a}),
      do: %{s | settled: s.settled + a}

    def apply(s, _other), do: s

    @compare every: 1
    def settled(s, _root), do: s.settled

    @compare every: 1
    def fees(s, _root), do: s.fees

    @compare every: 1
    def payer(s, _root), do: s.payer
  end

  defmodule FailingRelation do
    @moduledoc false
    # The settled total, compared by a relation that gives its own reason.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{settled: 0}

    @impl true
    def apply(s, %PropertyDamage.Test.Compare.Settled{amount: a}),
      do: %{s | settled: s.settled + a}

    def apply(s, _other), do: s

    @compare every: 1, using: :same_total
    def total(s, _root), do: s.settled

    defp same_total(reference, variant),
      do: reference == variant or {:fail, "the totals of alice and bob disagree"}
  end

  defmodule WideTotals do
    @moduledoc false
    # A compared value too wide for one line, so it prints over several.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{settled: 0}

    @impl true
    def apply(s, %PropertyDamage.Test.Compare.Settled{amount: a}),
      do: %{s | settled: s.settled + a}

    def apply(s, _other), do: s

    @compare every: 1
    def accounts(s, _root) do
      %{
        settled: s.settled,
        alice_account: "account-of-alice-with-a-long-identifier",
        bob_account: "account-of-bob-with-a-long-identifier"
      }
    end
  end

  defmodule SecondActFails do
    @moduledoc false
    # Fails on the event of the Act whose `n` is 1 (the second Act root).
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.SetupCommands.Acted
    def assert_not_second_act(_state, %{n: n}) do
      n != 1 or PropertyDamage.fail!("the second act")
    end
  end

  defmodule Inventory do
    @moduledoc false
    # The projection of the hand-built report: a list of ten items and a long
    # note, which the report prints in full.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{items: [], note: nil, n: 0}

    @impl true
    def apply(state, _event), do: %{state | n: state.n + 1}
  end

  defmodule Eventual do
    @moduledoc false
    # A payment that must be confirmed within 300 ms after it starts; the
    # silent adapter never confirms it, so the poll times out.

    defmodule Started do
      @moduledoc false
      defstruct [:id]
    end

    defmodule Confirmed do
      @moduledoc false
      defstruct [:id]
    end

    defmodule Start do
      @moduledoc false
      @behaviour PropertyDamage.Command
      defstruct [:id]

      @impl true
      def generator(_overrides \\ %{}), do: StreamData.constant(%{id: "pay_alice"})
    end

    defmodule Status do
      @moduledoc false
      use PropertyDamage.Model.Projection

      alias PropertyDamage.Test.ReportLayout.Eventual.{Confirmed, Started}

      @impl true
      def init, do: %{status: %{}}

      @impl true
      def apply(state, %Started{id: id}), do: put_in(state.status[id], :pending)
      def apply(state, %Confirmed{id: id}), do: put_in(state.status[id], :confirmed)
      def apply(state, _), do: state

      @eventually after: PropertyDamage.Test.ReportLayout.Eventual.Started,
                  timeout: {300, :milliseconds},
                  interval: {10, :milliseconds}
      def payment_eventually_confirmed(_state, %Started{id: id}) do
        fn s -> s.status[id] == :confirmed end
      end
    end

    defmodule Simulator do
      @moduledoc false
      @behaviour PropertyDamage.Model.Simulator

      @impl true
      def simulate(%PropertyDamage.Test.ReportLayout.Eventual.Start{id: id}, _state),
        do: [%PropertyDamage.Test.ReportLayout.Eventual.Started{id: id}]

      def simulate(_, _), do: []
    end

    defmodule Model do
      @moduledoc false
      @behaviour PropertyDamage.Model

      alias PropertyDamage.Test.ReportLayout.Eventual

      @impl true
      def commands, do: [Eventual.Start]

      @impl true
      def command_sequence_projection, do: Eventual.Status

      @impl true
      def check_projections, do: [Eventual.Status]

      @impl true
      def simulator, do: Eventual.Simulator
    end

    defmodule SilentAdapter do
      @moduledoc false
      use PropertyDamage.Adapter

      @impl true
      def setup(config), do: {:ok, config}

      @impl true
      def teardown(_ctx), do: :ok

      @impl true
      def execute(%PropertyDamage.Test.ReportLayout.Eventual.Start{id: id}, _ctx, _runtime),
        do: {:ok, [%PropertyDamage.Test.ReportLayout.Eventual.Started{id: id}]}
    end
  end

  defmodule Branch do
    @moduledoc false
    # A hand-built report of a branching run whose failure is localized to a
    # branch command: the `branching:` run path judges branch commands by
    # linearization, so such a report is built directly.

    defmodule Tick do
      @moduledoc false
      use PropertyDamage.Command
      defstruct [:n]

      @impl true
      def generator(_overrides \\ %{}), do: StreamData.constant(%{n: 0})
    end

    defmodule Count do
      @moduledoc false
      @behaviour PropertyDamage.Model.Projection

      @impl true
      def init, do: %{count: 0}

      @impl true
      def apply(%{count: c} = s, _), do: %{s | count: c + 1}
    end

    defmodule Model do
      @moduledoc false
      @behaviour PropertyDamage.Model

      @impl true
      def commands, do: [PropertyDamage.Test.ReportLayout.Branch.Tick]

      @impl true
      def command_sequence_projection, do: PropertyDamage.Test.ReportLayout.Branch.Count
    end

    @doc false
    def report do
      seq =
        Sequence.branching(
          [%Tick{n: 0}],
          [[%Tick{n: 1}, %Tick{n: 2}], [%Tick{n: 3}]],
          [%Tick{n: 4}]
        )

      FailureReport.new(
        seed: 77,
        run_number: 0,
        original_sequence: seq,
        shrunk_sequence: seq,
        # The executor index 2 in branch 0 is the branch's second command.
        failed_at_index: 2,
        failure_reason: %{Failure.check_failed(:CountIsOdd, "count went even") | branch_id: 0},
        model: Model,
        projections_before: %{Count => %{count: 2}},
        projections: %{Count => %{count: 3}}
      )
    end
  end

  # ==========================================================================
  # Reports
  # ==========================================================================

  # Every failure kind of the generic coverage list, in a fixed order.
  @kinds [
    :check_failed,
    :diverged,
    :diverged_expanded,
    :did_not_converge,
    :setup_failed_adapter,
    :setup_failed_command,
    :execution_failed_timeout,
    :test_code_error,
    :branching,
    :unshrunk,
    :shrunk_not_reproduced,
    :latency_exceeded
  ]

  @doc false
  def kinds, do: @kinds

  @doc false
  # The items and the note of the hand-built report's projection.
  def items, do: for(i <- 1..10, do: "item-alice-#{String.pad_leading("#{i}", 2, "0")}")
  def long_note, do: "a note about bob that is longer than forty characters, kept whole"

  @doc false
  # The report of `kind`, built on first use and cached for the VM.
  def report(kind) do
    key = {__MODULE__, :report, kind}

    case :persistent_term.get(key, nil) do
      nil ->
        :global.trans({{__MODULE__, :build}, self()}, fn ->
          case :persistent_term.get(key, nil) do
            nil ->
              report = build!(kind)
              :persistent_term.put(key, report)
              report

            report ->
              report
          end
        end)

      report ->
        report
    end
  end

  defp build!(kind) do
    case build(kind) do
      {:error, %FailureReport{} = report} -> report
      other -> raise "#{inspect(kind)} built no failure report: #{inspect(other, limit: 8)}"
    end
  end

  defp ledger, do: R.pay_model(__MODULE__.LedgerModel, R.Ledger)
  defp model(name, projection), do: R.pay_model(Module.concat(__MODULE__, name), projection)

  defp build(:check_failed),
    do: R.run(Compare.PlainModel, [R.pay_target("a", %{at: %{1 => {:sync, -100}}})], shrink: true)

  defp build(:diverged),
    do: R.run(ledger(), [R.pay_target("a"), R.pay_target("b", %{at: %{1 => {:sync, 1}}})])

  defp build(:diverged_expanded) do
    # The reference runs every root as written; the variant runs each Refund
    # as two Credit leaves and credits one too many. The seed is one whose
    # failing root's index in the shrunk sequence differs from its index as
    # generated, which the leaves' positions keep.
    model = R.leaf_model(__MODULE__.LeafModel)

    Enum.find_value(1..40, fn seed ->
      recorder = VariantSupport.start_recorder()

      targets = [
        ExpansionRun.target("a", recorder, %{}, expansion: :identity),
        ExpansionRun.target("b", recorder, %{bug: :credit})
      ]

      case R.run(model, targets, seed: seed, max_commands: 6, shrink: true) do
        {:error, %FailureReport{kind: :diverged} = report} = found ->
          if generated_root(report) not in [nil, report.failed_at_index], do: found

        _other ->
          nil
      end
    end)
  end

  defp build(:did_not_converge),
    do: R.run(ledger(), [R.pay_target("a"), R.pay_target("b", %{at: %{1 => :never}})])

  defp build(:setup_failed_adapter),
    do: R.run(Compare.PlainModel, [{R.NoBackendAdapter, name: "a"}])

  defp build(:setup_failed_command) do
    model =
      setup_model(SetupFailureModel,
        commands: [SetupCommands.Tick],
        checks: [],
        setup: SetupCommands.standard_setup(),
        teardown: [SetupCommands.Cleanup]
      )

    target =
      {SetupCommands.FixtureAdapter,
       name: "a", config: %{name: "a", fail: %{SetupCommands.Login => :error}}}

    R.run(model, [target], seed: 3, max_commands: 6)
  end

  defp build(:execution_failed_timeout),
    do: R.run(Compare.PlainModel, [{R.TimeoutAdapter, name: "a"}])

  defp build(:test_code_error),
    do: R.run(model(CrashModel, CrashingCheck), [R.pay_target("a")])

  defp build(:branching), do: {:error, Branch.report()}

  defp build(:unshrunk),
    do:
      R.run(Compare.PlainModel, [R.pay_target("a", %{at: %{2 => {:sync, -100}}})], shrink: false)

  defp build(:shrunk_not_reproduced),
    do:
      R.run(ledger(), [R.pay_target("a"), R.first_execution_target("b", %{1 => {:sync, 1}})],
        shrink: true
      )

  defp build(:latency_exceeded) do
    # Every Step sleeps 5 ms against a bound of 1 ms.
    target =
      {PropertyDamage.Test.LatencyFixtures.TimedStepAdapter, name: "solo", config: %{sleep_ms: 5}}

    R.run(PropertyDamage.Test.Lockstep.StepModel, [target],
      max_runs: 2,
      latency: [p99: [max: {1, :milliseconds}]]
    )
  end

  defp build(:three_targets) do
    # Only the third target diverges.
    R.run(ledger(), [
      R.pay_target("a"),
      R.pay_target("b"),
      R.pay_target("c", %{at: %{1 => {:sync, 1}}})
    ])
  end

  defp build(:also_differed) do
    # Three observations differ at root 0: the settled total names the
    # failure and the fees and the payer also differ.
    R.run(model(ObservationsModel, Observations), [
      R.pay_target("a"),
      R.pay_target("b", %{fee: 2, at: %{0 => {:sync, 1}}})
    ])
  end

  defp build(:failing_relation),
    do:
      R.run(model(FailingRelationModel, FailingRelation), [
        R.pay_target("a"),
        R.pay_target("b", %{at: %{1 => {:sync, 1}}})
      ])

  defp build(:wide_value),
    do:
      R.run(model(WideTotalsModel, WideTotals), [
        R.pay_target("a"),
        R.pay_target("b", %{at: %{1 => {:sync, 1}}})
      ])

  defp build(:late_fold) do
    # Both targets settle Pay number 0 after 800 ms, long after the divergence
    # at root 1 ends the run; finalization awaits that poller and folds it.
    R.run(model(SettlesModel, R.Settles), [
      R.pay_target("a", %{at: %{0 => {:after_ms, 800}}}),
      R.pay_target("b", %{at: %{0 => {:after_ms, 800}, 1 => {:sync, 1}}})
    ])
  end

  defp build(:setup_check) do
    # A check failure in a run with setup and teardown commands.
    model =
      setup_model(SetupCheckModel,
        commands: SetupCommands.act_roots(),
        checks: [SecondActFails],
        setup: SetupCommands.standard_setup(),
        teardown: [SetupCommands.Cleanup]
      )

    R.run(model, [{SetupCommands.FixtureAdapter, name: "a", config: %{name: "a"}}],
      seed: 1,
      max_commands: 6
    )
  end

  defp build(:leaf_check) do
    # A one-target check failure on the second leaf of an expanded Refund.
    model =
      if Code.ensure_loaded?(__MODULE__.LeafCheckModel) do
        __MODULE__.LeafCheckModel
      else
        ExpansionRun.define_model!(__MODULE__.LeafCheckModel,
          commands: [ExpansionRun.Noise, ExpansionRun.Refund],
          expansions: [{ExpansionRun.Refund, &ExpansionRun.refund_rewrite/2}],
          checks: [ExpansionRun.Totals, ExpansionRun.SecondCreditFails]
        )
      end

    Enum.find_value(1..40, fn seed ->
      targets = [ExpansionRun.target("a", VariantSupport.start_recorder())]

      case R.run(model, targets, seed: seed, max_commands: 6, shrink: true) do
        {:error, %FailureReport{kind: :check_failed}} = found -> found
        _other -> nil
      end
    end)
  end

  defp build(:idempotency) do
    target = {Compare.StutterAdapter, name: "s", config: %{retry: :different}}

    R.run(Compare.PayModel, [target],
      max_commands: 1,
      stutter: [probability: 1.0, max_repeats: 1, delay_ms: 0]
    )
  end

  defp build(:poll_timeout),
    do: R.run(Eventual.Model, [{Eventual.SilentAdapter, name: "a"}], max_commands: 1)

  defp build(:hand_built), do: {:error, hand_built()}

  defp setup_model(name, opts) do
    module = Module.concat(__MODULE__, name)
    if Code.ensure_loaded?(module), do: module, else: SetupCommands.define_model!(module, opts)
  end

  @doc false
  # A one-target check failure at root 1 of two Pays, built by hand: each Pay
  # answers Paid and Settled, root 1's Settled is logged before its Paid with
  # an earlier timestamp, an injector event belongs to no command, and the
  # projection holds a list of ten items and a long note.
  def hand_built do
    seq = Sequence.linear([%Pay{n: 0, amount: 3}, %Pay{n: 1, amount: 4}])

    log = [
      Entry.from_command(%Paid{n: 0, amount: 3, fee: 1, by: "alice"}, 0, timestamp: 1_000),
      Entry.from_command(%Settled{n: 0, amount: 3}, 0, timestamp: 1_000),
      Entry.from_injector(
        %Compare.Balance{n: 9, value: 77, fresh: true},
        PropertyDamage.Test.RecordingInjector,
        timestamp: 1_120
      ),
      Entry.from_command(%Paid{n: 1, amount: 4, fee: 1, by: "alice"}, 1, timestamp: 1_400),
      Entry.from_command(%Settled{n: 1, amount: -4}, 1, timestamp: 1_380)
    ]

    before = %{items: items(), note: long_note(), n: 1}

    FailureReport.new(
      seed: 99,
      run_number: 0,
      original_sequence: seq,
      shrunk_sequence: seq,
      failed_at_index: 1,
      failure_reason: Failure.check_failed(:settled_amount, "negative settlement"),
      event_log: log,
      projections_before: %{Inventory => before},
      projections: %{Inventory => %{before | n: 2}},
      targets: [{Compare.PayAdapter, [name: "a", config: %{name: "a"}]}]
    )
  end

  @doc false
  # The root id a leaf position of the report's failing step names (its
  # index as generated), or nil when the failing step is not a leaf.
  def generated_root(%FailureReport{} = report) do
    case FailureReport.failure_step(report) do
      %Step{position: %Position{section: {:leaf, root}}} -> root
      _other -> nil
    end
  end

  @doc false
  # The last fold a trace attributes to root `root`: the root's own fold and
  # the folds of its events.
  def last_fold_of_root(%RunTrace{} = trace, root) do
    own = Map.fetch!(trace.command_fold_ordinals, Position.prefix(root))

    events =
      for %{command_index: ^root, phase: :root, fold_index: fold} <- trace.event_log,
          fold != nil,
          do: fold

    Enum.max([own | events])
  end

  # ==========================================================================
  # Rendering
  # ==========================================================================

  @doc false
  def plain(report), do: Formatter.format(report, :terminal, color: false)

  @doc false
  def colored(report), do: Formatter.format(report, :terminal, color: true)

  @doc false
  def markdown(report), do: Formatter.format(report, :markdown)

  # ==========================================================================
  # Facts: what a report's layout must show, from its own fields
  # ==========================================================================

  @doc false
  def facts(%FailureReport{} = report) do
    label = expected_label(report)
    comparison? = report.kind in [:diverged, :did_not_converge]

    %{
      seed: report.seed,
      banner:
        if(report.error_origin == :test_code_error, do: "TEST CODE ERROR", else: "BUG DETECTED!"),
      label: label,
      outcome: outcome(report.kind),
      marks: marks(label, comparison?),
      roots: roots(report),
      sides: if(comparison?, do: {reference_name(report), report.variant.name}),
      projections?: projections?(report, comparison?),
      targets?: report.targets != [],
      opaque: opaque_paths(report.targets)
    }
  end

  defp outcome(:diverged), do: "diverged"
  defp outcome(:did_not_converge), do: "did not converge"
  defp outcome(_kind), do: "failed"

  defp marks(nil, _comparison?), do: 0
  defp marks(_label, true), do: 2
  defp marks(_label, false), do: 1

  defp roots(report) do
    case FailureReport.shrunk_sequence(report) do
      %Sequence{} = sequence -> Sequence.command_count(sequence)
      nil -> 0
    end
  end

  defp reference_name(%FailureReport{targets: [{_adapter, entry} | _]}),
    do: Keyword.fetch!(entry, :name)

  @doc false
  # The label of the failing step (DR-055 decision 5), `:any` for a suffix command of a
  # branching run (its offset rule is the renderer's), or nil when the
  # failure is not localized to a step.
  def expected_label(%FailureReport{kind: kind, failed_at_index: i})
      when kind in [:diverged, :did_not_converge] and is_integer(i),
      do: "[#{i}]"

  def expected_label(%FailureReport{
        failure_reason: %Failure{type: %Failure.Setup{cause: cause, setup_index: i}}
      })
      when cause != :adapter_setup and is_integer(i),
      do: "[setup #{i}]"

  def expected_label(%FailureReport{} = report) do
    case FailureReport.failure_step(report) do
      nil -> nil
      %Step{position: position} -> step_label(position, report.failed_at_index)
    end
  end

  defp step_label(%Position{section: :prefix, offset: i}, _root), do: "[#{i}]"
  defp step_label(%Position{section: {:branch, b}, offset: i}, _root), do: "[branch #{b}.#{i}]"
  defp step_label(%Position{section: {:leaf, _id}, offset: j}, root), do: "[#{root}.#{j}]"
  defp step_label(%Position{section: :suffix}, _root), do: :any

  # Projections prints unless neither compared side has state.
  defp projections?(report, true) do
    state?(report.reference_state_at_failure) or state?(variant_cut(report))
  end

  defp projections?(report, false),
    do: state?(report.state_before_failure) or state?(report.state_at_failure)

  defp variant_cut(%FailureReport{trace: %RunTrace{} = trace, failed_at_index: i})
       when is_integer(i),
       do: RunTrace.state_at(trace, Position.prefix(i))

  defp variant_cut(_report), do: nil

  defp state?(state), do: is_map(state) and map_size(state) > 0

  # The places in `targets` that hold a pid, a reference, a port or a
  # function, each as a path such as "config.recorder".
  defp opaque_paths(targets) do
    targets
    |> Enum.flat_map(fn {_adapter, entry} ->
      Enum.flat_map(entry, &opaque(elem(&1, 1), [elem(&1, 0)]))
    end)
    |> Enum.uniq()
  end

  defp opaque(value, path)
       when is_pid(value) or is_reference(value) or is_port(value) or is_function(value),
       do: [path |> Enum.reverse() |> Enum.map_join(".", &to_string/1)]

  defp opaque(%{__struct__: _}, _path), do: []

  defp opaque(map, path) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> opaque(value, [key | path]) end)

  defp opaque(_value, _path), do: []

  # ==========================================================================
  # Parsing
  # ==========================================================================

  @label ~S"\[(?:setup \d+|teardown \d+|branch \d+\.\d+|\d+(?:\.\d+)?)\]"

  @doc false
  # The regex source of a step label: [i], [i.j], [setup i], [teardown i],
  # [branch b.i].
  def label_source, do: @label

  @doc false
  def strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  @doc false
  def lines(text), do: String.split(text, "\n")

  @doc false
  # The `## ` headings, without the marker, in order.
  def headings(text) do
    for "## " <> heading <- lines(text), do: String.trim_trailing(heading)
  end

  @doc false
  # `[{heading, body_lines}]`: each `## ` heading with the lines up to the
  # next one.
  def sections(text) do
    text
    |> lines()
    |> Enum.chunk_while(
      nil,
      fn
        "## " <> heading, nil ->
          {:cont, {String.trim_trailing(heading), []}}

        "## " <> heading, {h, body} ->
          {:cont, {h, Enum.reverse(body)}, {String.trim_trailing(heading), []}}

        _line, nil ->
          {:cont, nil}

        line, {h, body} ->
          {:cont, {h, [line | body]}}
      end,
      fn
        nil -> {:cont, nil}
        {h, body} -> {:cont, {h, Enum.reverse(body)}, nil}
      end
    )
  end

  @doc false
  # The body lines of the first section whose heading starts with `prefix`.
  def section(text, name) do
    case Enum.find(sections(text), fn {heading, _} -> named?(heading, name) end) do
      {_heading, body} -> body
      nil -> flunk("no section #{inspect(name)} in:\n#{text}")
    end
  end

  @doc false
  # The heading that starts with `prefix`, or nil.
  def heading(text, name), do: Enum.find(headings(text), &named?(&1, name))

  # A heading is named by itself, by its words before a parenthesis
  # ("Minimal Reproduction" names "Minimal Reproduction (2 roots)"), or by a
  # prefix that ends with a space ("Projections at ").
  defp named?(heading, name) do
    heading == name or String.starts_with?(heading, name <> " (") or
      (String.ends_with?(name, " ") and String.starts_with?(heading, name))
  end

  @doc false
  # The value of the one Failure field labeled `label`, its continuation
  # lines joined to it with single spaces.
  def field_value(text, label) do
    fields = fields_labeled(text, label)
    assert length(fields) == 1, "one #{label} field expected, got #{length(fields)}"
    [field] = fields
    Enum.join([field.value | Enum.map(field.continuation, &String.trim/1)], " ")
  end

  @doc false
  # Lines without the blank lines at either end, joined.
  def trimmed(lines) do
    lines
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp blank?(line), do: String.trim(line) == ""

  @doc false
  # The labeled fields of a Failure section, in order:
  # `%{label:, value:, column:, continuation: [line]}`. A field line is a
  # label, two or more spaces, and the value; a line that starts with a space
  # continues the field above it. Markdown fence lines are skipped.
  def fields(body) do
    body
    |> Enum.reject(&(blank?(&1) or String.starts_with?(&1, "```")))
    |> Enum.reduce([], fn line, acc ->
      case {String.starts_with?(line, " "), acc} do
        {true, [field | rest]} -> [%{field | continuation: field.continuation ++ [line]} | rest]
        {true, []} -> flunk("a continuation line before any field: #{inspect(line)}")
        {false, _} -> [field(line) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp field(line) do
    case Regex.run(~r/^(\S(?:.*?\S)?) {2,}(\S.*)$/u, line) do
      [_, label, value] ->
        %{
          label: label,
          value: value,
          column: String.length(line) - String.length(value),
          continuation: []
        }

      nil ->
        flunk("a Failure line is not a label and a value: #{inspect(line)}")
    end
  end

  @doc false
  # The fields labeled `label`.
  def fields_labeled(text, label) do
    text |> section("Failure") |> fields() |> Enum.filter(&(&1.label == label))
  end

  @doc false
  # The step lines of a listing: `%{label:, marked?:, line:, at:}` where
  # `at` is the line's index in `body`.
  def steps(body) do
    for {line, at} <- Enum.with_index(body),
        [_, mark, label] <- [Regex.run(~r/^(►)?\s*(#{@label})(?:\s|$)/u, line)],
        do: %{label: label, marked?: mark == "►", line: line, at: at}
  end

  @doc false
  # The listings of a Minimal Reproduction body: `[{header, lines}]`, with
  # header nil for a listing without one.
  def listings(body) do
    header? = &Regex.match?(~r/^(Reference|Variant): target "/, &1)

    case Enum.filter(body, header?) do
      [] ->
        [{nil, body}]

      _headers ->
        body
        |> Enum.drop_while(&(not header?.(&1)))
        |> Enum.chunk_while(
          nil,
          fn line, acc ->
            cond do
              header?.(line) and acc == nil -> {:cont, {line, []}}
              header?.(line) -> {:cont, finish(acc), {line, []}}
              true -> {:cont, put_line(acc, line)}
            end
          end,
          fn acc -> {:cont, finish(acc), nil} end
        )
    end
  end

  defp put_line({header, lines}, line), do: {header, [line | lines]}
  defp finish({header, lines}), do: {header, Enum.reverse(lines)}

  @doc false
  # The lines under each step of a listing, up to the next step or the
  # "Not tied to a command" line: `[{step, lines}]`.
  def step_blocks(lines) do
    steps = steps(lines)
    stop = Enum.find_index(lines, &untied?/1) || length(lines)
    starts = Enum.map(steps, & &1.at)
    ends = Enum.drop(starts, 1) ++ [stop]

    for {step, finish} <- Enum.zip(steps, ends),
        do: {step, Enum.slice(lines, (step.at + 1)..(finish - 1)//1)}
  end

  @doc false
  def untied?(line), do: Regex.match?(~r/^\s*Not tied to a command/, line)

  @doc false
  # The event lines of a block: lines that start, after spaces, with a
  # `+S.SSs` offset.
  def event_lines(lines), do: Enum.filter(lines, &Regex.match?(~r/^\s+\+\d+\.\d{2}s\s/, &1))

  @doc false
  # The offset of an event line, in hundredths of a second.
  def offset(line) do
    [_, s, cs] = Regex.run(~r/^\s+\+(\d+)\.(\d{2})s/, line)
    String.to_integer(s) * 100 + String.to_integer(cs)
  end

  @doc false
  # The step label at the start of a value, or nil.
  def leading_label(value) do
    case Regex.run(~r/^(#{@label})/u, value) do
      [_, label] -> label
      nil -> nil
    end
  end

  # ==========================================================================
  # Checks
  # ==========================================================================

  @removed [
    "Run Number",
    "Command Index",
    "Timestamp",
    "State Transition",
    "Projection States at Failure",
    "Event Log",
    "Boundary Comparisons",
    "Shrinking Statistics",
    "Original Sequence",
    "What Failed",
    "Failure Location",
    "Failure Details",
    "Why it failed",
    "◄── FAILURE"
  ]

  @doc false
  def removed, do: @removed

  @doc false
  # The `## ` headings in DR-055's order, Projections exactly when the
  # facts say, and none of the removed headings or labels.
  def assert_sections(text, facts) do
    headings = text |> headings() |> Enum.reject(&(&1 == "Setup"))

    assert match?(["Failure", "Minimal Reproduction" <> _ | _], headings),
           "Failure then Minimal Reproduction first, got #{inspect(headings)}"

    assert List.last(headings) == "Reproduction", "Reproduction last, got #{inspect(headings)}"

    projections = Enum.filter(headings, &String.starts_with?(&1, "Projections at "))
    expected = if facts.projections?, do: 4, else: 3

    assert length(headings) == expected and length(projections) == expected - 3,
           "headings #{inspect(headings)}, Projections expected: #{facts.projections?}"

    for removed <- @removed do
      refute text =~ removed, "the removed #{inspect(removed)} is printed:\n#{text}"
    end

    :ok
  end

  @doc false
  # The Failure `At` label, every `►` line and the Projections heading
  # carry the failing step's label; every `►` line ends with `◄── <outcome>`.
  def assert_labels(text, facts) do
    body = section(text, "Minimal Reproduction")
    marked = body |> steps() |> Enum.filter(& &1.marked?)
    arrows = Enum.filter(lines(text), &String.contains?(&1, "◄──"))
    at = text |> fields_labeled("At") |> Enum.map(&leading_label(&1.value))

    if facts.label do
      assert length(at) == 1, "one At field with a step label, got #{inspect(at)}"
      [at_label] = at

      if facts.label != :any,
        do: assert(at_label == facts.label, "At #{at_label}, expected #{facts.label}")

      assert length(marked) == facts.marks,
             "#{facts.marks} ► lines expected, got:\n#{Enum.map_join(marked, "\n", & &1.line)}"

      for step <- marked do
        assert step.label == at_label, "► on #{step.label}, At is #{at_label}"

        assert step.line =~ ~r/◄── #{facts.outcome}\s*$/u,
               "► line without ◄── #{facts.outcome}: #{inspect(step.line)}"
      end

      assert length(arrows) == length(marked), "a ◄── line without ►"

      case heading(text, "Projections at ") do
        nil ->
          :ok

        heading ->
          assert leading_label(String.replace_prefix(heading, "Projections at ", "")) == at_label
      end
    else
      assert marked == [] and arrows == [], "a non-localized failure marks no step"
      assert Enum.all?(at, &is_nil/1), "a non-localized failure has no At step"
    end

    :ok
  end

  @doc false
  # Two listings under Reference and Variant headers for a comparison
  # kind, one listing without headers otherwise.
  def assert_sides(text, facts) do
    headers = text |> section("Minimal Reproduction") |> listings() |> Enum.map(&elem(&1, 0))

    case facts.sides do
      {reference, variant} ->
        assert headers == [~s(Reference: target "#{reference}"), ~s(Variant: target "#{variant}")]

      nil ->
        assert headers == [nil]
    end

    :ok
  end

  @doc false
  # The Minimal Reproduction heading counts the roots.
  def assert_roots_heading(text, facts) do
    expected =
      if facts.roots == 1,
        do: "Minimal Reproduction (1 root)",
        else: "Minimal Reproduction (#{facts.roots} roots)"

    assert heading(text, "Minimal Reproduction") == expected
    :ok
  end

  @doc false
  # Every Failure value starts at one column and every continuation
  # line is indented at least that far. Returns the fields.
  def assert_aligned(text) do
    fields = text |> section("Failure") |> fields()
    assert fields != [], "an empty Failure section"
    columns = fields |> Enum.map(& &1.column) |> Enum.uniq()
    assert length(columns) == 1, "values start at columns #{inspect(columns)}:\n#{text}"
    [column] = columns

    for field <- fields, line <- field.continuation do
      indent = String.length(line) - String.length(String.trim_leading(line))

      assert indent >= column,
             "#{inspect(line)} is indented #{indent}, the value column is #{column}"
    end

    fields
  end

  @doc false
  # Every box line has one width, the colored box with ANSI stripped
  # has the plain box's widths, and `Seed: <seed>` is the only line between
  # the box and the first section.
  def assert_banner(plain, colored, facts) do
    box = box_lines(plain)
    assert box != [], "no banner box"

    assert box |> Enum.map(&String.length/1) |> Enum.uniq() |> length() == 1,
           "box lines of unequal width"

    assert Enum.any?(box, &String.contains?(&1, facts.banner)),
           "the banner does not say #{facts.banner}"

    colored_box = colored |> strip_ansi() |> box_lines()
    assert Enum.map(colored_box, &String.length/1) == Enum.map(box, &String.length/1)

    for text <- [plain, strip_ansi(colored)] do
      between =
        text
        |> lines()
        |> Enum.drop_while(&(not box_line?(&1)))
        |> Enum.drop_while(&box_line?/1)
        |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
        |> Enum.reject(&blank?/1)

      assert between == ["Seed: #{facts.seed}"],
             "between the box and Failure: #{inspect(between)}"
    end

    :ok
  end

  defp box_lines(text), do: text |> lines() |> Enum.filter(&box_line?/1)
  defp box_line?(line), do: String.starts_with?(line, ["╔", "║", "╚"])

  @doc false
  # `targets = ` once, before the first call; every call names
  # `targets: targets`; a line under the binding names each place holding a
  # value no source can rebuild, which prints on the binding only; the report
  # ends with the replay call or the line saying why there is none.
  def assert_reproduction(text, facts) do
    all = lines(text)
    body = section(text, "Reproduction")
    bindings = Enum.filter(all, &String.starts_with?(&1, "targets = "))
    first_call = Enum.find_index(body, &call?/1)
    calls = Enum.filter(body, &call?/1)
    assert first_call, "no call in Reproduction"

    if facts.targets? do
      assert length(bindings) == 1, "targets = printed #{length(bindings)} times"
      binding = Enum.find_index(body, &String.starts_with?(&1, "targets = "))
      assert binding && binding < first_call, "the binding is not before the first call"
      assert hd(calls) =~ "targets: targets", "the seed call does not name targets: targets"
      assert_opaque(body, binding, first_call, facts.opaque)
    else
      assert bindings == []
    end

    for call <- calls do
      refute call =~ "targets: [", "a call repeats the targets list: #{call}"
      if call =~ "targets:", do: assert(call =~ "targets: targets", "#{call}")
    end

    last = all |> Enum.reject(&blank?/1) |> List.last()

    assert last =~ ~r/^PropertyDamage\.run\(.*only: \[replay: / or last =~ ~r/^\(no artifact/,
           "the report ends with #{inspect(last)}"

    :ok
  end

  defp call?(line), do: String.starts_with?(line, "PropertyDamage.")

  @unrebuildable ~r/#(PID|Reference|Port|Function)</

  defp assert_opaque(body, binding, first_call, paths) do
    notes = Enum.slice(body, (binding + 1)..(first_call - 1)//1)
    opaque_lines = Enum.filter(body, &(&1 =~ @unrebuildable))

    if paths == [] do
      assert opaque_lines == []
      refute Enum.any?(notes, &(&1 =~ "rebuild")), "a rebuild note with nothing to rebuild"
    else
      assert Enum.all?(opaque_lines, &String.starts_with?(&1, "targets = ")),
             "an opaque value outside the binding:\n#{Enum.join(opaque_lines, "\n")}"

      for path <- paths do
        assert Enum.any?(notes, &String.contains?(&1, path)),
               "no line under the binding names #{path}"
      end
    end
  end

  @doc false
  # The markdown has the banner heading, the seed, the plain terminal's
  # headings in order, each section's body in one fenced block equal to the
  # plain terminal's, and no ANSI escape.
  def assert_markdown_mirrors(markdown, plain, facts) do
    refute markdown =~ "\e[", "an ANSI escape in markdown"
    md_lines = lines(markdown)
    first = Enum.find(md_lines, &(not blank?(&1)))

    assert String.starts_with?(first, "# " <> facts.banner),
           "markdown opens with #{inspect(first)}"

    preamble = Enum.take_while(md_lines, &(not String.starts_with?(&1, "## ")))

    assert "Seed: #{facts.seed}" in Enum.map(preamble, &String.trim/1),
           "no Seed line before the sections"

    assert headings(markdown) == headings(plain)

    for {{heading, md_body}, {_, plain_body}} <- Enum.zip(sections(markdown), sections(plain)) do
      blocks = fenced(md_body)
      assert length(blocks) == 1, "#{heading}: one fenced block expected, got #{length(blocks)}"
      [{lang, block}] = blocks

      assert block == trimmed(plain_body),
             "#{heading}: the fenced block differs from the terminal"

      if String.starts_with?(heading, "Projections"), do: assert(lang == "diff")
      if heading == "Reproduction", do: assert(lang == "elixir")
    end

    :ok
  end

  @doc false
  # The fenced blocks of markdown lines: `[{lang, text}]`.
  def fenced(md_lines) do
    md_lines
    |> Enum.chunk_while(
      nil,
      fn
        "```" <> lang, nil -> {:cont, {String.trim(lang), []}}
        "```" <> _, {lang, acc} -> {:cont, {lang, acc |> Enum.reverse() |> trimmed()}, nil}
        _line, nil -> {:cont, nil}
        line, {lang, acc} -> {:cont, {lang, [line | acc]}}
      end,
      fn
        nil -> {:cont, nil}
        {lang, acc} -> {:cont, {lang, acc |> Enum.reverse() |> trimmed()}, nil}
      end
    )
  end

  @doc false
  # Every check that holds for every kind, over the three renderings.
  def assert_layout(plain, colored, markdown, facts) do
    for text <- [plain, strip_ansi(colored), markdown] do
      assert_sections(text, facts)
      assert_labels(text, facts)
      assert_sides(text, facts)
      assert_roots_heading(text, facts)
    end

    # The markdown's last line closes a fence; the terminal ends with the call.
    for text <- [plain, strip_ansi(colored)], do: assert_reproduction(text, facts)
    assert_aligned(plain)
    assert_aligned(strip_ansi(colored))
    assert_banner(plain, colored, facts)
    assert_markdown_mirrors(markdown, plain, facts)
    :ok
  end

  @doc false
  # The skeleton of DR-055's Example, as headings and label names.
  def example_skeleton do
    %{
      headings: ["Failure", "Minimal Reproduction", "Projections at", "Reproduction"],
      failure_labels: ["Failure", "Observation", "At", "Reference", "Variant", "Compared"],
      listings: ["Reference: target", "Variant: target"],
      calls: ["PropertyDamage.run(", "PropertyDamage.Expansion.for(", "PropertyDamage.run("]
    }
  end

  @doc false
  # `text` has the shape of DR-055's Example (not its bytes).
  def assert_example_shape(text, facts) do
    skeleton = example_skeleton()
    headings = headings(text)
    assert length(headings) == length(skeleton.headings)

    for {heading, prefix} <- Enum.zip(headings, skeleton.headings),
        do: assert(String.starts_with?(heading, prefix), "#{heading} is not #{prefix}")

    labels = text |> section("Failure") |> fields() |> Enum.map(& &1.label)
    assert labels == skeleton.failure_labels

    {reference, variant} = facts.sides
    listings = text |> section("Minimal Reproduction") |> listings()

    assert Enum.map(listings, &elem(&1, 0)) == [
             ~s(Reference: target "#{reference}"),
             ~s(Variant: target "#{variant}")
           ]

    for {_header, lines} <- listings do
      assert [%{label: label}] = lines |> steps() |> Enum.filter(& &1.marked?)
      assert label == facts.label
    end

    projections = heading(text, "Projections at ")
    assert projections, "no Projections heading"
    assert projections =~ ~s(reference "#{reference}") and projections =~ ~s(variant "#{variant}")
    diff = section(text, "Projections at ")
    assert Enum.any?(diff, &(&1 =~ ~r/^\s*- \S/)) and Enum.any?(diff, &(&1 =~ ~r/^\s*\+ \S/))

    body = section(text, "Reproduction") |> Enum.reject(&blank?/1)
    assert body != [] and String.starts_with?(hd(body), "targets = ")
    calls = Enum.filter(body, &call?/1)
    assert length(calls) == 3

    for {call, prefix} <- Enum.zip(calls, skeleton.calls),
        do: assert(String.starts_with?(call, prefix), "#{call} is not #{prefix}")

    assert List.last(calls) =~ "only: [replay: "
    :ok
  end

  @doc false
  # The event names of each step of the report, in timestamp order (stable),
  # in the order the steps are listed.
  def event_names(%FailureReport{} = report) do
    for step <- FailureReport.steps(report) do
      step.entries
      |> Enum.sort_by(& &1.timestamp)
      |> Enum.map(&(&1.event.__struct__ |> Module.split() |> List.last()))
    end
  end

  @doc false
  # The lines of the one listing of a report with one target.
  def one_listing(text) do
    listings = text |> section("Minimal Reproduction") |> listings()
    assert length(listings) == 1, "one listing expected, got #{length(listings)}"
    [{nil, listing}] = listings
    listing
  end

  @doc false
  # Under each step of the one listing, every event line starts with a
  # `+S.SSs` offset, the offsets do not decrease, and the lines name the
  # step's events in order. `expected` holds each step's event names, steps
  # in listing order. Returns the step blocks.
  def assert_events_under_steps(text, expected) do
    blocks = text |> one_listing() |> step_blocks()

    assert length(blocks) == length(expected),
           "#{length(expected)} steps expected, got #{length(blocks)}"

    for {{step, lines}, names} <- Enum.zip(blocks, expected) do
      events = event_lines(lines)

      assert length(events) == length(names),
             "#{step.label}: #{length(names)} events expected under the step, got:\n#{Enum.join(lines, "\n")}"

      for {line, name} <- Enum.zip(events, names),
          do: assert(line =~ name, "#{step.label}: #{name} expected on #{inspect(line)}")

      offsets = Enum.map(events, &offset/1)

      assert offsets == Enum.sort(offsets),
             "#{step.label}: offsets out of order #{inspect(offsets)}"
    end

    refute text =~ "Event Log"
    blocks
  end

  @doc false
  # The one event tied to no command prints after the listing under
  # "Not tied to a command", and under no step.
  def assert_untied(text, name) do
    listing = one_listing(text)
    untied = Enum.find_index(listing, &untied?/1)
    assert untied, "no Not tied to a command line"
    last = listing |> steps() |> List.last()
    assert last && untied > last.at, "Not tied to a command is not after the listing"

    events = listing |> Enum.drop(untied + 1) |> event_lines()
    assert length(events) == 1 and hd(events) =~ name, "one #{name} event expected after it"

    refute Enum.any?(step_blocks(listing), fn {_step, lines} ->
             Enum.any?(lines, &(&1 =~ name))
           end),
           "#{name} printed under a step"
  end

  @doc false
  # A `-` line for attribute `key` holding `minus`, then a `+` line for
  # it holding `plus`.
  def assert_diff(body, key, minus, plus) do
    at = fn marker, value ->
      Enum.find_index(body, &(&1 =~ ~r/^\s*#{marker} #{key}\b/ and String.contains?(&1, value)))
    end

    {m, p} = {at.("-", minus), at.("\\+", plus)}

    assert m && p && m < p,
           "#{key}: - #{minus} then + #{plus} expected in:\n#{Enum.join(body, "\n")}"
  end

  @doc false
  # An attribute equal on both sides prints on one line, with no marker.
  def assert_unmarked_once(body, key) do
    lines = Enum.filter(body, &(&1 =~ ~r/^\s*([-+] )?#{key}\b/))
    assert length(lines) == 1, "#{key} once expected, got:\n#{Enum.join(lines, "\n")}"
    refute hd(lines) =~ ~r/^\s*[-+] /, "#{key} is equal on both sides but carries a marker"
  end

  @doc false
  # The failing expanded root is [root] and marked in both listings; in
  # the variant's, its `leaves` leaves follow it as [root.j], unmarked, and
  # its line names `entry`; no label carries the generated root id.
  def assert_expanded_root(text, root, leaves, entry, generated) do
    listings = text |> section("Minimal Reproduction") |> listings()
    assert length(listings) == 2, "two listings expected"
    [{_, reference}, {_, variant}] = listings

    assert reference |> steps() |> Enum.filter(& &1.marked?) |> Enum.map(& &1.label) == [
             "[#{root}]"
           ]

    variant_steps = steps(variant)
    i = Enum.find_index(variant_steps, &(&1.label == "[#{root}]"))
    assert i, "the variant does not list [#{root}]"
    following = variant_steps |> Enum.drop(i) |> Enum.take(leaves + 1)
    labels = ["[#{root}]" | for(j <- 0..(leaves - 1)//1, do: "[#{root}.#{j}]")]
    assert Enum.map(following, & &1.label) == labels
    assert Enum.map(following, & &1.marked?) == [true | List.duplicate(false, leaves)]
    assert Enum.count(variant_steps, & &1.marked?) == 1
    assert hd(following).line =~ entry, "the root line does not name its entry #{entry}"

    refute text =~ "[#{generated}.", "a label carries the generated root id #{generated}"
    assert field_value(text, "At") =~ ~r/^\[#{root}\] /
  end
end
