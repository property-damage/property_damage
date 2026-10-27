defmodule PropertyDamage.Test.ReplayFixtures do
  @moduledoc """
  Fixtures for the replay artifact: the file a failing run writes, the loader
  that reads it back as data, the `only: [replay: path]` run option, the
  report footer and every path that re-executes a failure from the report's
  `replay` term.

  Most tests run `PropertyDamage.Test.ExpansionFor.Model` (a setup `Fund`,
  `Noise` and `Refund` roots, `Refund[1]` rewriting a refund into two `Credit`
  leaves, a teardown `Close`) with its recording adapter; its `bug: :credit`
  config makes one target answer every `Credit` with one too many, so only the
  rewrite entry exposes the divergence. This module adds:

    * `ExternalModel`: an `Open` root whose event carries an `external()` id
      and a `Refund` root that consumes it, so the roots and the leaves of a
      failure hold `%PropertyDamage.Placeholder{}` values;
    * `CheckModel`: `Refund` roots only, with a check that fails on a credit
      the adapter answers skewed (`bug: :check`), so one target alone fails
      where it ran the rewrite;
    * `FunModel`, `PidModel`, `RefModel`, `PortModel`: one `Mark` root that
      always runs as one `Tag` leaf, whose `payload` field the expansion's
      `overrides:` fill with a value no artifact can hold (a function nested
      in a map inside a list, a pid, a reference, a port); `CleanModel` is the
      same model with a plain payload.

  Every model here compares `Tally` after every root. The `Recorder` adapter
  sends the same messages as `PropertyDamage.Test.ExpansionFor.Recorder`
  (`{:setup, name}`, `{:executed, name, command}`, `{:teardown, name}`), so
  `ExpansionFor.drain/0`, `segments/2` and `setups/2` read what it ran. Its
  `bug: true` config answers every `Tag` and `Credit` with one too many;
  `bug: :check` answers every `Credit` with the part `:skewed`.

  The seed and run coordinates of a report are read through
  `report_coordinates/1`, `run_seed_for/2` and `report_run/1` only.
  """

  import ExUnit.Assertions

  alias PropertyDamage.{FailureReport, Generator, Sequence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.ExpansionFor
  alias PropertyDamage.Test.TmpPath

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule Marked do
    @moduledoc false
    defstruct [:n]
  end

  defmodule Tagged do
    @moduledoc false
    defstruct [:n]
  end

  defmodule Opened do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Refunded do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Credited do
    @moduledoc false
    defstruct [:amount, :part]
  end

  # ==========================================================================
  # Commands
  # ==========================================================================

  defmodule Mark do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Tag do
    @moduledoc false
    # A leaf: `n` and `payload` come from `overrides:`.
    use PropertyDamage.Command
    defstruct [:n, :payload]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.integer(1..9), payload: StreamData.constant(nil)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Open do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:label]

    @impl true
    def generator(overrides \\ %{}) do
      %{label: StreamData.integer(1..1_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Refund do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:account_id, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{account_id: StreamData.constant(nil), amount: StreamData.integer(2..1_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Credit do
    @moduledoc false
    # A leaf of `Refund[1]`: every field comes from `overrides:`.
    use PropertyDamage.Command
    defstruct [:account_id, :amount, :part]

    @impl true
    def generator(overrides \\ %{}) do
      %{
        account_id: StreamData.constant(nil),
        amount: StreamData.integer(0..1_000),
        part: StreamData.constant(0)
      }
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule World do
    @moduledoc false
    # The sequence projection: the accounts opened so far, as placeholders.
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ReplayFixtures, as: R

    @impl true
    def init, do: %{accounts: []}

    @impl true
    def apply(state, %R.Opened{id: id}), do: %{state | accounts: state.accounts ++ [id]}
    def apply(state, _other), do: state
  end

  defmodule Tally do
    @moduledoc false
    # The total every target is compared on after every root.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ReplayFixtures, as: R

    @impl true
    def init, do: %{total: 0}

    @impl true
    def apply(state, %R.Tagged{n: n}), do: %{state | total: state.total + n}
    def apply(state, %R.Refunded{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %R.Credited{amount: a}), do: %{state | total: state.total + a}
    def apply(state, _other), do: state

    @compare every: 1
    def total(state, _root), do: state.total
  end

  defmodule CreditCheck do
    @moduledoc false
    # Fails on a credit the adapter answered skewed.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: PropertyDamage.Test.ReplayFixtures.Credited
    def credit_answered_plainly(_state, %{part: part}) do
      part != :skewed or PropertyDamage.fail!("a credit answered skewed")
    end
  end

  # ==========================================================================
  # Adapter
  # ==========================================================================

  defmodule Recorder do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.ReplayFixtures, as: R

    @impl true
    def setup(config) do
      send(config.pid, {:setup, config.name})
      {:ok, config}
    end

    @impl true
    def teardown(ctx) do
      send(ctx.pid, {:teardown, ctx.name})
      :ok
    end

    @impl true
    def execute(command, ctx, _runtime) do
      send(ctx.pid, {:executed, ctx.name, command})
      {:ok, [answer(command, ctx)]}
    end

    defp answer(%R.Mark{n: n}, _ctx), do: %R.Marked{n: n}
    defp answer(%R.Tag{n: n}, ctx), do: %R.Tagged{n: n + skew(ctx)}

    defp answer(%R.Open{}, ctx),
      do: %R.Opened{id: "#{ctx.name}-account-#{System.unique_integer([:positive])}"}

    defp answer(%R.Refund{amount: a}, _ctx), do: %R.Refunded{amount: a}

    defp answer(%R.Credit{amount: a, part: p}, ctx) do
      part = if Map.get(ctx, :bug) == :check, do: :skewed, else: p
      %R.Credited{amount: a + skew(ctx), part: part}
    end

    defp skew(ctx), do: if(Map.get(ctx, :bug) == true, do: 1, else: 0)
  end

  # ==========================================================================
  # Models
  # ==========================================================================

  defmodule ExternalModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.ReplayFixtures, as: R

    @impl true
    def commands do
      [
        R.Open,
        {R.Refund, when: &(&1.accounts != []), overrides: &%{account_id: List.last(&1.accounts)}}
      ]
    end

    @impl true
    def command_sequence_projection, do: R.World

    @impl true
    def check_projections, do: [R.Tally]

    @impl true
    def simulator, do: R

    @impl true
    def expansions, do: [{R.Refund, &R.refund_split/2}]
  end

  defmodule CheckModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.ReplayFixtures, as: R

    @impl true
    def commands, do: [R.Refund]

    @impl true
    def command_sequence_projection, do: R.World

    @impl true
    def check_projections, do: [R.Tally, R.CreditCheck]

    @impl true
    def simulator, do: R

    @impl true
    def expansions, do: [{R.Refund, &R.refund_split/2}]
  end

  for {name, poison} <- [
        CleanModel: :clean,
        FunModel: :function,
        PidModel: :pid,
        RefModel: :reference,
        PortModel: :port
      ] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      @behaviour PropertyDamage.Model

      alias PropertyDamage.Test.ReplayFixtures, as: R

      @impl true
      def commands, do: [R.Mark]

      @impl true
      def command_sequence_projection, do: R.World

      @impl true
      def check_projections, do: [R.Tally]

      @impl true
      def simulator, do: R

      @impl true
      def expansions, do: [{R.Mark, &R.mark_as_tag(unquote(poison), &1, &2)}]
    end
  end

  defmodule LeafRootModel do
    @moduledoc false
    # An Open (whose event carries an external() id) rewrites to one Open
    # with the same label: an entry whose one leaf is the root itself.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.ReplayFixtures, as: R

    @impl true
    def commands, do: [R.Open]

    @impl true
    def command_sequence_projection, do: R.World

    @impl true
    def check_projections, do: [R.Tally]

    @impl true
    def simulator, do: R

    @impl true
    def expansions, do: [{R.Open, &R.same_open/2}]
  end

  @doc false
  # Open: one entry, `Open[0]`, one Open leaf with the root's label.
  def same_open(%Open{label: label}, _state), do: [[{Open, overrides: %{label: label}}]]

  @doc false
  # Refund: `Refund[0]` is the identity; `Refund[1]` credits the amount in two
  # parts on the same account.
  def refund_split(%Refund{account_id: account, amount: n} = refund, _state) do
    half = div(n, 2)

    [
      [refund],
      [
        {Credit, overrides: %{account_id: account, amount: half, part: 0}},
        {Credit, overrides: %{account_id: account, amount: n - half, part: 1}}
      ]
    ]
  end

  @doc false
  # Mark: one entry, `Mark[0]`, one `Tag` leaf carrying `payload_for(poison)`.
  def mark_as_tag(poison, %Mark{n: n}, _state),
    do: [[{Tag, overrides: %{n: n, payload: payload_for(poison)}}]]

  @doc false
  # The value a `Tag` leaf carries, and the field path to the value an
  # artifact cannot hold.
  def payload_for(:clean), do: [%{note: "plain"}]
  def payload_for(:function), do: [%{f: &__MODULE__.noop/0}]
  def payload_for(:pid), do: self()
  def payload_for(:reference), do: make_ref()
  def payload_for(:port), do: :erlang.list_to_port(~c"#Port<0.0>")

  @doc false
  def poison_field(:function), do: [:payload, 0, :f]
  def poison_field(_poison), do: [:payload]

  @doc false
  def noop, do: :ok

  @doc false
  # The simulator every model here shares: each command answers one event.
  def simulate(%Mark{n: n}, _state), do: [%Marked{n: n}]
  def simulate(%Tag{n: n}, _state), do: [%Tagged{n: n}]
  def simulate(%Open{}, _state), do: [%Opened{}]
  def simulate(%Refund{amount: a}, _state), do: [%Refunded{amount: a}]
  def simulate(%Credit{amount: a, part: p}, _state), do: [%Credited{amount: a, part: p}]
  def simulate(_command, _state), do: []

  # ==========================================================================
  # Targets and runs
  # ==========================================================================

  @doc false
  # A `targets:` entry for this module's recorder.
  def target(name, expansion \\ :random, config \\ %{}) do
    {Recorder,
     name: name, config: Map.merge(%{name: name, pid: self()}, config), expansion: expansion}
  end

  @doc false
  # `PropertyDamage.run/1` with a one-millisecond convergence bound, so a
  # divergence fails at once.
  def run(model, targets, opts) do
    PropertyDamage.run([model: model, targets: targets, compare: [converge_within: 1]] ++ opts)
  end

  @doc false
  # `PropertyDamage.run/1` for a fixture smoke test. Smoke runs fail on
  # purpose; where the run option `replay_dir:` exists they pass
  # `replay_dir: false`, so a smoke run never writes a replay artifact into
  # the working directory.
  def smoke_run(opts) do
    known = PropertyDamage.Options.run_schema().schema
    quiet = if Keyword.has_key?(known, :replay_dir), do: [replay_dir: false], else: []
    PropertyDamage.run(opts ++ quiet)
  end

  @doc false
  # A fresh directory under the system tmp dir, removed when the test exits.
  def tmp_dir! do
    dir = TmpPath.unique("pd_replay")

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc false
  # A directory path under a fresh tmp dir that does not exist yet.
  def missing_dir!, do: Path.join(tmp_dir!(), "nested/replays")

  @doc false
  # The files in `dir`; none when the directory does not exist.
  def files(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  @doc false
  # The artifact file name for `report`: the model's last name segment and
  # the report's seed.
  def artifact_name(report) do
    segment = report.model |> Module.split() |> List.last()
    "#{segment}_seed#{report.seed}.replay.exs"
  end

  # ==========================================================================
  # Seed and run coordinates (one place, shared with ExpansionFor)
  # ==========================================================================

  @doc false
  # The `{seed, run}` that regenerates the failing run of `report`.
  def report_coordinates(report), do: ExpansionFor.report_coordinates(report)

  @doc false
  # The effective seed of run `run` (1-based) of a campaign seeded with `seed`.
  def run_seed_for(seed, run), do: ExpansionFor.run_seed_for(seed, run)

  @doc false
  # The campaign run (1-based) `report` failed in.
  def report_run(report), do: ExpansionFor.report_run(report)

  # ==========================================================================
  # Reading reports and artifacts
  # ==========================================================================

  @doc false
  def artifact_module, do: Module.concat(PropertyDamage, ReplayArtifact)

  @doc false
  # `PropertyDamage.ReplayArtifact.read(path)`.
  def read_artifact(path), do: call(artifact_module(), :read, [path])

  @doc false
  # `PropertyDamage.ReplayArtifact.parse(text)`.
  def parse_artifact(text), do: call(artifact_module(), :parse, [text])

  @doc false
  # `PropertyDamage.FailureReport.replay_command(report)`.
  def replay_command(report), do: call(failure_report_module(), :replay_command, [report])

  @doc false
  # `PropertyDamage.FailureReport.expansion_command(report)`.
  def expansion_command(report), do: call(failure_report_module(), :expansion_command, [report])

  @doc false
  # `call` as the printed report shows it: the report binds its targets once
  # (`targets = [...]`) and every call names `targets: targets`.
  def printed(report, call) do
    source = call(failure_report_module(), :targets_source, [report])
    String.replace(call, "targets: " <> source, "targets: targets")
  end

  defp failure_report_module, do: Module.concat([PropertyDamage, "FailureReport"])

  # A call into a function that may not exist yet.
  defp call(module, function, args), do: apply(module, function, args)

  @doc false
  # The term an artifact file holds; fails the test when it does not load.
  def term!(path) do
    assert {:ok, term} = read_artifact(path)
    term
  end

  @doc false
  # A report or stats field that may not exist yet: read by a key the
  # compiler does not see, so the type checker does not flag fields the
  # report gains later. Raises `KeyError` when the field is missing.
  def field(map, key), do: Map.fetch!(map, key)

  @doc false
  # `map` with `key` set to `value`, by a key the compiler does not see.
  def put_field(map, key, value), do: Map.put(map, key, value)

  @doc false
  # `report`'s `replay_path`, asserting the file exists.
  def replay_path!(report) do
    path = field(report, :replay_path)
    assert is_binary(path), "expected a replay_path, got: #{inspect(path)}"
    assert File.exists?(path), "no artifact at #{path}"
    path
  end

  @doc false
  # What `name` ran, as an artifact records it: the prefix, then the commands
  # of every root.
  def concrete(term, name) do
    term.prefix ++ Enum.flat_map(Map.fetch!(term.choices, name), & &1.commands)
  end

  @doc false
  # A trace choice as an artifact records it.
  def recorded_choice(choice), do: Map.take(choice, [:root_id, :entry, :commands, :aliases])

  @doc false
  # The root commands of the sequence `report` describes.
  def roots(report), do: report |> FailureReport.shrunk_sequence() |> Sequence.to_list()

  @doc false
  # The report as the terminal prints it, without color.
  def text(report), do: Formatter.format(report, :terminal, color: false)

  @doc false
  # The last `n` non-blank lines of the printed report, whitespace-trimmed.
  def last_lines(report, n) do
    report
    |> text()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-n)
  end

  @doc false
  # A failure reason as text, whatever its shape.
  def reason_text(reason) when is_binary(reason), do: reason
  def reason_text(reason), do: inspect(reason, limit: :infinity, printable_limit: :infinity)

  @doc false
  # The last segment of a module name.
  def short(module), do: module |> Module.split() |> List.last()
end
