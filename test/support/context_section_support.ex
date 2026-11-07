defmodule PropertyDamage.Test.ContextSection do
  @moduledoc false
  # Fixtures and readers for the "What this checks" section of the failure
  # report.
  #
  # `define/1` compiles one small system in the test (events, commands, a
  # ledger projection, a model and an adapter) from source text, so the docs
  # of every module are under the test's control: a doc, `false` for a hidden
  # doc, or `:omit` for none. The `run_*` functions run it for real and return
  # the failure report of the run.
  #
  # The readers take the report and return the section as lines (terminal,
  # markdown, the HTML page's embedded text) or as parsed items.

  import ExUnit.Assertions

  alias PropertyDamage.Docs
  alias PropertyDamage.FailureReport
  alias PropertyDamage.FailureReport.{Formatter, HTML}
  alias PropertyDamage.Test.{DocsHelpers, TmpPath}

  @heading "What this checks"

  # The docs of the documented system. Each doc that a supporting item prints
  # has a first paragraph of several lines and a second paragraph, so a cut
  # at the first line shows up as well as no cut at all.
  @docs %{
    model:
      "The MyApp ledger model.\nIt runs payments for alice and bob.\n\nSecond model paragraph.",
    projection:
      "Keeps the settled total of every payment alice makes.\nIt reads Paid and Settled events.\n\nSecond projection paragraph.",
    check:
      "A settlement is never negative.\n\n## When it fails\n\nThe check fails when the sum for alice drops below zero:\n\n```elixir\nassert_settled_not_negative(state, %Settled{amount: -1})\n```\n\nLook at the adapter first.",
    command: "Pays bob from alice.\nThe amount is in cents.\n\nSecond command paragraph.",
    compare_total: "The settled total across all payments.\n\nSecond total paragraph.",
    compare_fees: "The fees alice paid.\nCounted per payment.\n\nSecond fees paragraph.",
    compare_credited: "The credits bob received.\n\nSecond credited paragraph.",
    relation:
      "Accepts equal totals only.\nIt compares alice with bob.\n\nSecond relation paragraph.",
    eventual: "Every payment of alice settles in time.\n\nSecond eventual paragraph.",
    eventual_projection:
      "Waits for the settlement of alice.\nIt reads Settled events.\n\nSecond waiting paragraph.",
    relation_module:
      "Relations between the totals of alice and bob.\n\nSecond relations paragraph.",
    login: "Logs alice in.\nIt runs before every payment.\n\nSecond login paragraph.",
    refund: "Refunds alice.\nThe amount is in cents.\n\nSecond refund paragraph.",
    invariant: "A settlement of alice is never below zero."
  }

  @doc "The docs the documented system carries."
  def docs, do: @docs

  @doc "The doc of `key` in the documented system."
  def doc(key), do: Map.fetch!(@docs, key)

  # ==========================================================================
  # The system under test
  # ==========================================================================

  @template ~S"""
  defmodule __P__.Paid do
    defstruct [:n, :amount, :fee, :by]
  end

  defmodule __P__.Settled do
    defstruct [:n, :amount]
  end

  defmodule __P__.Boom do
    defstruct [:n]
  end

  defmodule __P__.Credited do
    defstruct [:n, :amount, :part]
  end

  __PAY__

  defmodule __P__.Login do
    __LOGIN_DOC__
    use PropertyDamage.Command
    defstruct [:user]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{user: "alice"})
  end

  defmodule __P__.Refund do
    __REFUND_DOC__
    use PropertyDamage.Command
    defstruct [:n, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0), amount: StreamData.constant(4)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule __P__.Credit do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n, :amount, :part]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0), amount: StreamData.constant(0), part: StreamData.constant(0)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule __P__.Blocked do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule __P__.Counter do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %__P__.Pay{}), do: %{state | count: state.count + 1}
    def apply(state, %__P__.Refund{}), do: %{state | count: state.count + 1}
    def apply(state, _other), do: state
  end

  __LEDGER__

  defmodule __P__.Eventual do
    __EVENTUAL_PROJECTION_DOC__
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{settled: 0}

    @impl true
    def apply(state, %__P__.Settled{}), do: %{state | settled: state.settled + 1}
    def apply(state, _other), do: state

    @eventually after: __P__.Paid, timeout: {150, :milliseconds}, interval: {10, :milliseconds}
    __EVENTUAL_DOC__
    def assert_settles_in_time(_state, %__P__.Paid{}) do
      fn state -> state.settled > 0 end
    end
  end

  __MODEL__

  defmodule __P__.Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias __P__.{Boom, Credit, Credited, Login, Paid, Pay, Refund, Settled}

    @impl true
    def setup(config) do
      if config[:fail_setup], do: {:error, :no_backend}, else: {:ok, config}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Login{}, ctx, _runtime),
      do: if(ctx[:fail_login], do: {:error, :locked}, else: {:ok, []})

    def execute(%Pay{n: n, amount: amount}, ctx, _runtime) do
      if ctx[:sleep_ms], do: Process.sleep(ctx.sleep_ms)
      paid = %Paid{n: n, amount: amount, fee: Map.get(ctx, :fee, 1), by: ctx.name}

      case Map.get(Map.get(ctx, :at, %{}), n, :sync) do
        :sync -> {:ok, [paid, %Settled{n: n, amount: amount}]}
        {:sync, delta} -> {:ok, [paid, %Settled{n: n, amount: amount + delta}]}
        :never -> {:ok, [paid]}
        :boom -> {:ok, [paid, %Boom{n: n}]}
        :error -> {:error, :refused}
      end
    end

    def execute(%Refund{n: n, amount: amount}, ctx, _runtime),
      do: {:ok, [%Credited{n: n, amount: amount + Map.get(ctx, :credit_bonus, 0), part: nil}]}

    def execute(%Credit{n: n, amount: amount, part: part}, ctx, _runtime),
      do: {:ok, [%Credited{n: n, amount: amount + Map.get(ctx, :credit_bonus, 0), part: part}]}
  end
  """

  @pay_documented ~S"""
  defmodule __P__.Pay do
    __COMMAND_DOC__
    use PropertyDamage.Command
    defstruct [:n, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0), amount: StreamData.integer(1..9)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end
  """

  # A command declared with the behaviour alone: its docs cannot be read.
  @pay_bare ~S"""
  defmodule __P__.Pay do
    @moduledoc "Pays bob from alice."
    @behaviour PropertyDamage.Command
    defstruct [:n, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0), amount: StreamData.integer(1..9)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end
  """

  @ledger_documented ~S"""
  defmodule __P__.Ledger do
    __PROJECTION_DOC__
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{settled: 0, fees: 0, credited: 0, unsettled: %{}}

    @impl true
    def apply(s, %__P__.Paid{n: n, amount: a, fee: fee}),
      do: %{s | fees: s.fees + fee, unsettled: Map.put(s.unsettled, n, a)}

    def apply(s, %__P__.Settled{n: n, amount: a}),
      do: %{s | settled: s.settled + a, unsettled: Map.delete(s.unsettled, n)}

    def apply(s, %__P__.Credited{amount: a}), do: %{s | credited: s.credited + a}
    def apply(_s, %__P__.Boom{}), do: raise("the ledger of alice cannot apply Boom")
    def apply(s, _other), do: s

    @invariant id: :no_negative_settlement, description: __INVARIANT__
    @check every: __P__.Settled, validates: :no_negative_settlement
    __CHECK_DOC__
    def assert_settled_not_negative(_state, %__P__.Settled{amount: a}),
      do: a >= 0 or PropertyDamage.fail!("negative settlement", amount: a)

    @compare every: 1, using: __USING__
    __COMPARE_TOTAL_DOC__
    def a_total(s, _root), do: if(s.unsettled == %{}, do: s.settled, else: {:pending, :unsettled})

    @compare every: 1
    __COMPARE_FEES_DOC__
    def b_fees(s, _root), do: s.fees

    @compare every: 1
    __COMPARE_CREDITED_DOC__
    def c_credited(s, _root), do: s.credited
  end
  """

  # A projection declared with the behaviour alone: its docs cannot be read,
  # and it defines no checks.
  @ledger_bare ~S"""
  defmodule __P__.Ledger do
    @moduledoc "Keeps the settled total of every payment alice makes."
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{settled: 0}

    @impl true
    def apply(s, %__P__.Settled{amount: a}), do: %{s | settled: s.settled + a}
    def apply(_s, %__P__.Boom{}), do: raise("the ledger of alice cannot apply Boom")
    def apply(s, _other), do: s
  end
  """

  @doc """
  Compiles the system from source and returns its modules. Options:

    * `:docs` - a map over the documented system's docs, per key a string,
      `false` or `:omit`
    * `:checks` - the model's check projections: `:ledger` (default),
      `:eventual` or `:none`
    * `:commands` - `:pay` (default) or `:refund`
    * `:entries` - the body of the model's `refund_paths/2`, as source text;
      the model lists an expansion for `Refund` only when it is given
    * `:setup` - `true` for a model with the setup command `Login`
    * `:bare` - `true` for a model, a ledger projection and a pay command
      declared with the behaviour alone, whose docs cannot be read
    * `:relation` - `:chunk` (default) for a relation module whose docs
      come from the docs chunk, `:plain` for one whose docs cannot be read
  """
  def define(opts \\ []) do
    prefix = "PropertyDamage.Test.CtxSec#{DocsHelpers.suffix()}"
    docs = Map.merge(@docs, Map.new(Keyword.get(opts, :docs, %{})))
    bare? = Keyword.get(opts, :bare, false)

    main =
      @template
      |> String.replace("__PAY__", if(bare?, do: @pay_bare, else: @pay_documented))
      |> String.replace("__LEDGER__", if(bare?, do: @ledger_bare, else: @ledger_documented))
      |> String.replace("__MODEL__", model_source(opts, bare?))
      |> fill_docs(docs)
      |> String.replace("__P__", prefix)

    relations = relations_source(Keyword.get(opts, :relation, :chunk), docs, prefix)

    file = "test/support/context_section_#{DocsHelpers.suffix()}.exs"

    relation_kind = Keyword.get(opts, :relation, :chunk)

    related =
      if relation_kind == :chunk,
        do: DocsHelpers.compile_with_docs(relations, file),
        else: DocsHelpers.compile(relations, file)

    # A module compiled in the VM has no docs to read; one whose beam sits on
    # the code path has them, as a module compiled by a build does.
    beams = if relation_kind == :chunk, do: put_on_code_path(related)

    compiled = DocsHelpers.compile(main, file)

    for {module, _binary} <- related ++ compiled, do: Code.ensure_loaded!(module)

    u = %{
      prefix: prefix,
      model: Module.concat([prefix, "Model"]),
      ledger: Module.concat([prefix, "Ledger"]),
      eventual: Module.concat([prefix, "Eventual"]),
      pay: Module.concat([prefix, "Pay"]),
      login: Module.concat([prefix, "Login"]),
      refund: Module.concat([prefix, "Refund"]),
      relations: Module.concat([prefix, "Relations"]),
      adapter: Module.concat([prefix, "Adapter"]),
      modules: related ++ compiled,
      beam_dir: beams
    }

    if relation_kind == :chunk do
      assert {:ok, %{moduledoc: _}} = Docs.fetch(u.relations),
             "the relation module must have a docs chunk to read"
    end

    u
  end

  defp put_on_code_path(modules) do
    dir = TmpPath.unique("context_section_beams")
    DocsHelpers.write_beams(modules, dir)
    Code.prepend_path(dir)
    dir
  end

  @doc "Removes the compiled system from the VM."
  def purge(%{modules: modules, beam_dir: dir}) do
    if dir do
      Code.delete_path(dir)
      File.rm_rf(dir)
    end

    DocsHelpers.purge(modules)
  end

  defp model_source(opts, bare?) do
    checks =
      case Keyword.get(opts, :checks, :ledger) do
        :ledger -> "[__P__.Ledger]"
        :eventual -> "[__P__.Eventual]"
        :none -> "[]"
      end

    commands =
      case Keyword.get(opts, :commands, :pay) do
        :pay ->
          "[{__P__.Pay, overrides: &number/1}]"

        :refund ->
          "[{__P__.Refund, overrides: &number/1}, " <>
            "{__P__.Blocked, when: fn _state -> false end, overrides: &number/1}]"
      end

    expansions =
      case Keyword.get(opts, :entries) do
        nil ->
          ""

        body ->
          """
          @impl true
          def expansions, do: [{__P__.Refund, &refund_paths/2}]

          def refund_paths(%__P__.Refund{n: n, amount: amount}, _state) do
            #{body}
          end

          defp credits(n, amount) do
            half = div(amount, 2)

            [
              {__P__.Credit, overrides: %{n: n, amount: half, part: 0}},
              {__P__.Credit, overrides: %{n: n, amount: amount - half, part: 1}}
            ]
          end
          """
      end

    setup =
      if Keyword.get(opts, :setup, false),
        do: "@impl true\ndef setup_each, do: [__P__.Login]",
        else: ""

    use_line = if bare?, do: "@behaviour PropertyDamage.Model", else: "use PropertyDamage.Model"

    """
    defmodule __P__.Model do
      __MODEL_DOC__
      #{use_line}

      @impl true
      def commands, do: #{commands}

      @impl true
      def command_sequence_projection, do: __P__.Counter

      @impl true
      def check_projections, do: #{checks}

      #{setup}

      #{expansions}

      defp number(state), do: %{n: state.count}
    end
    """
  end

  defp relations_source(kind, docs, prefix) do
    module_doc = if kind == :chunk, do: moduledoc(docs.relation_module), else: ""
    fun_doc = if kind == :chunk, do: function_doc(docs.relation), else: ""

    """
    defmodule #{prefix}.Relations do
      #{module_doc}
      #{fun_doc}
      def same_total(reference, variant),
        do: reference == variant or {:fail, "the totals of alice and bob disagree"}
    end
    """
  end

  defp fill_docs(source, docs) do
    source
    |> String.replace("__COMMAND_DOC__", moduledoc(docs.command))
    |> String.replace("__LOGIN_DOC__", moduledoc(docs.login))
    |> String.replace("__REFUND_DOC__", moduledoc(docs.refund))
    |> String.replace("__MODEL_DOC__", moduledoc(docs.model))
    |> String.replace("__PROJECTION_DOC__", moduledoc(docs.projection))
    |> String.replace("__EVENTUAL_PROJECTION_DOC__", moduledoc(docs.eventual_projection))
    |> String.replace("__EVENTUAL_DOC__", function_doc(docs.eventual))
    |> String.replace("__CHECK_DOC__", function_doc(docs.check))
    |> String.replace("__COMPARE_TOTAL_DOC__", function_doc(docs.compare_total))
    |> String.replace("__COMPARE_FEES_DOC__", function_doc(docs.compare_fees))
    |> String.replace("__COMPARE_CREDITED_DOC__", function_doc(docs.compare_credited))
    |> String.replace("__INVARIANT__", literal(docs.invariant))
    |> String.replace("__USING__", "{__P__.Relations, :same_total}")
  end

  defp moduledoc(:omit), do: ""
  defp moduledoc(false), do: "@moduledoc false"
  defp moduledoc(text), do: "@moduledoc " <> literal(text)

  defp function_doc(:omit), do: ""
  defp function_doc(false), do: "@doc false"
  defp function_doc(text), do: "@doc " <> literal(text)

  defp literal(text), do: inspect(text, limit: :infinity, printable_limit: :infinity)

  # ==========================================================================
  # Runs
  # ==========================================================================

  @doc "A target of the system's adapter named `name`."
  def target(u, name, config \\ %{}, opts \\ []),
    do: {u.adapter, [name: name, config: Map.merge(%{name: name}, config)] ++ opts}

  @doc "The `at:` map that sets `mode` for every payment number a run of three can reach."
  def every(mode), do: %{0 => mode, 1 => mode, 2 => mode}

  @doc "Runs the model against `targets`; returns the failure report, or fails the test."
  def run(u, targets, extra \\ []) do
    opts =
      Keyword.merge(
        [
          model: u.model,
          targets: targets,
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

  @doc "A check fails on a negative settlement."
  def check_failed(u), do: run(u, [target(u, "a", %{at: every({:sync, -100})})])

  @doc "An @eventually check times out: nothing ever settles."
  def poll_timeout(u), do: run(u, [target(u, "a", %{at: every(:never)})])

  @doc "A projection raises while it folds an event."
  def projection_violation(u), do: run(u, [target(u, "a", %{at: every(:boom)})])

  @doc "The variant settles one more and charges another fee: two observations differ."
  def diverged(u),
    do: run(u, [target(u, "a"), target(u, "b", %{fee: 2, at: every({:sync, 1})})])

  @doc "The variant never settles."
  def did_not_converge(u), do: run(u, [target(u, "a"), target(u, "b", %{at: every(:never)})])

  @doc "The adapter answers an error to the command."
  def adapter_error(u), do: run(u, [target(u, "a", %{at: every(:error)})])

  @doc "The adapter's setup answers an error."
  def setup_failed_adapter(u), do: run(u, [target(u, "a", %{fail_setup: true})])

  @doc "A setup command answers an error."
  def setup_failed_command(u), do: run(u, [target(u, "a", %{fail_login: true})])

  @doc """
  A poll error the way the engine reports it: no check name and no step it
  is tied to. Built by hand, because a run reaches it only when a poller
  fails to answer.
  """
  def poll_error(u) do
    sequence = PropertyDamage.Sequence.linear([struct(u.pay, n: 0, amount: 3)])

    FailureReport.new(
      seed: 1,
      run_number: 0,
      original_sequence: sequence,
      shrunk_sequence: sequence,
      failed_at_index: nil,
      failure_reason: PropertyDamage.Failure.poll_error(:await_timeout),
      model: u.model,
      targets: [{u.adapter, [name: "a", config: %{name: "a"}]}]
    )
  end

  @doc "A latency bound the single target exceeds."
  def latency_exceeded(u),
    do:
      run(u, [target(u, "solo", %{sleep_ms: 5})],
        max_runs: 2,
        latency: [p99: [max: {1, :milliseconds}]]
      )

  @doc """
  The variant credits more than the reference. `reference` and `variant` are
  extra target options (`expansion: :identity` for a target that runs the
  root as itself).
  """
  def refund_diverged(u, reference_opts \\ [], variant_opts \\ [], extra \\ []),
    do:
      run(
        u,
        [target(u, "a", %{}, reference_opts), target(u, "b", %{credit_bonus: 1}, variant_opts)],
        extra
      )

  # ==========================================================================
  # Readers
  # ==========================================================================

  @doc "The section's heading."
  def heading, do: @heading

  def terminal(report), do: Formatter.format(report, :terminal, color: false)
  def markdown(report), do: Formatter.format(report, :markdown, [])
  def json(report), do: report |> Formatter.format(:json, []) |> Jason.decode!()

  @doc "The items of the JSON data, failing when the key is missing or is not a list."
  def json_items!(report) do
    case json(report) do
      %{"what_this_checks" => items} when is_list(items) ->
        items

      other ->
        flunk("no what_this_checks list in the JSON data, keys: #{inspect(Map.keys(other))}")
    end
  end

  @doc "The terminal text the HTML page embeds."
  def html_text(report) do
    html = HTML.render(report)

    [_, encoded] =
      Regex.run(~r{<script type="application/json" id="pd-report">(.*?)</script>}s, html)

    Jason.decode!(encoded)
  end

  @doc "The `## ` headings of a terminal or markdown text, in order."
  def headings(text), do: for("## " <> heading <- String.split(text, "\n"), do: heading)

  @doc """
  The body lines of the section in a rendering (`:terminal`, `:markdown` or
  `:html`), blank lines at either end dropped, or `nil` when the rendering has
  no such section. In markdown the body is the fenced block under the heading.
  """
  def body(report, :terminal), do: report |> terminal() |> terminal_body()
  def body(report, :html), do: report |> html_text() |> terminal_body()
  def body(report, :markdown), do: report |> markdown() |> markdown_body()

  @doc "Like `body/2`, failing when the section is missing."
  def body!(report, rendering) do
    case body(report, rendering) do
      nil -> flunk("the #{rendering} report has no \"#{@heading}\" section")
      lines -> lines
    end
  end

  defp terminal_body(text) do
    case Enum.split_while(String.split(text, "\n"), &(&1 != "## " <> @heading)) do
      {_before, []} ->
        nil

      {_before, [_heading | rest]} ->
        rest |> Enum.take_while(&(not String.starts_with?(&1, "## "))) |> trim_blank()
    end
  end

  defp markdown_body(text) do
    case Enum.split_while(String.split(text, "\n"), &(&1 != "## " <> @heading)) do
      {_before, []} ->
        nil

      {_before, [_heading | rest]} ->
        case Enum.drop_while(rest, &(not String.starts_with?(&1, "```"))) do
          [_fence | fenced] -> fenced |> Enum.take_while(&(&1 != "```")) |> trim_blank()
          [] -> nil
        end
    end
  end

  defp trim_blank(lines) do
    lines
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc """
  Parses a section body into items. An item starts at a line whose first
  non-space character is at column 2; every other line belongs to the item
  above it. An item is `%{label:, head:, rest:}`: `head` is what follows the
  label on its line (nil when the label stands alone) and `rest` the lines
  below, without the blank line that separates it from the next item.
  """
  def items(body) do
    body
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        cond do
          label_line?(line) and acc == nil -> {:cont, [line]}
          label_line?(line) -> {:cont, Enum.reverse(acc), [line]}
          acc == nil -> {:cont, nil}
          true -> {:cont, [line | acc]}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, Enum.reverse(acc), nil}
      end
    )
    |> Enum.map(&item/1)
  end

  defp label_line?(line), do: Regex.match?(~r/^  \S/, line)

  defp item([line | rest]) do
    {label, head} =
      if String.length(line) > 16 and String.at(line, 15) == " " do
        {line |> String.slice(2, 14) |> String.trim_trailing(), String.slice(line, 16..-1//1)}
      else
        {String.trim(line), nil}
      end

    %{
      label: label,
      head: head,
      rest: rest |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
    }
  end

  @doc "The labels of the items, in order."
  def labels(body), do: body |> items() |> Enum.map(& &1.label)

  @doc "The item labeled `label`, failing when there is none."
  def item!(body, label) do
    case Enum.find(items(body), &(&1.label == label)) do
      nil -> flunk("no item labeled #{inspect(label)} in:\n#{Enum.join(body, "\n")}")
      item -> item
    end
  end

  @doc "The text lines of an item as printed, each with its column-16 indent removed."
  def text_lines(%{head: nil, rest: rest}), do: Enum.map(rest, &unindent/1)
  def text_lines(%{head: head, rest: rest}), do: [head | Enum.map(rest, &unindent/1)]

  @doc "The lines of an item below the one that carries its label and name."
  def below_label(%{rest: rest}), do: Enum.map(rest, &unindent/1)

  defp unindent(line), do: String.replace_prefix(line, String.duplicate(" ", 16), "")

  @doc "Prints `text` as the section prints a doc: 16 spaces before each non-blank line."
  def indent(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn
      "" -> ""
      line -> String.duplicate(" ", 16) <> line
    end)
  end

  @doc "The text up to the first blank line."
  def first_paragraph(text), do: text |> String.split("\n\n", parts: 2) |> hd()

  @doc "The label the section gives a failure kind."
  def kind_label(kind) do
    text = kind |> to_string() |> String.replace("_", " ")
    String.upcase(String.first(text)) <> String.slice(text, 1..-1//1)
  end

  @doc "The kind of a report, as an atom."
  def kind(%FailureReport{} = report), do: FailureReport.failure_type(report)

  @doc "Lines printed between two items are exactly one blank line."
  def assert_item_separation(body) do
    indexes = for {line, i} <- Enum.with_index(body), label_line?(line), i > 0, do: i

    for i <- indexes do
      assert Enum.at(body, i - 1) == "", "no blank line before #{inspect(Enum.at(body, i))}"

      assert Enum.at(body, i - 2) not in ["", nil],
             "more than one blank line before #{inspect(Enum.at(body, i))}"
    end

    :ok
  end

  @doc "Every non-blank line starts at column 2 (a label) or column 16; no line holds only spaces."
  def assert_columns(body) do
    for line <- body do
      refute line != "" and String.trim(line) == "", "a line of only spaces: #{inspect(line)}"

      if line != "" do
        spaces = String.length(line) - String.length(String.trim_leading(line, " "))
        assert spaces in [2, 16], "line starts at column #{spaces}: #{inspect(line)}"
      end
    end

    :ok
  end
end
