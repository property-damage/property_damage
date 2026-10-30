defmodule PropertyDamage.Test.ExpansionFor do
  @moduledoc """
  Fixtures for regenerating one target's concrete sequence
  (`PropertyDamage.Expansion.for/5`) and for running part of a campaign
  (the `only:` run option).

  ## The model

  `PropertyDamage.Test.ExpansionFor.Model` has:

    * a setup prefix: one `Fund` whose `amount` its generator draws;
    * roots: `Noise` (never expanded) and `Refund`, whose expansion function
      returns two entries: `Refund[0]`, the identity, and `Refund[1]`, two
      `Credit` leaves that split the amount (each leaf also draws a `memo`);
    * a teardown suffix: one `Close` whose `n` its generator draws;
    * `Totals`, a check projection with `@compare every: 1` on the funded and
      refunded totals. Each call sends `{:compared, target_name}` to the test
      process, so a test can prove the comparison ran or did not.

  `PropertyDamage.Test.ExpansionFor.PlainModel` has no `expansions/0` and no
  `@compare` function: `Noise` roots only.

  Setup, root, leaf and teardown commands are told apart by module:
  `setup_module/0`, `teardown_module/0`.

  ## The adapter

  `Recorder` sends to the process named by `pid` in its config:

      {:setup, name}               setup/1 ran: one execution of that target
      {:executed, name, command}   execute/3 ran with that command
      {:teardown, name}            teardown/1 ran

  Config keys besides `name` and `pid`:

    * `bug: :credit` - every `Credited` event answers its amount plus one, so
      a target that ran `Refund[1]` diverges from one that did not;
    * `refuse: module` - every command of that module answers
      `{:error, :refused}`.

  ## Helpers

    * `target/3` - a `targets:` entry for the recorder;
    * `drain/0`, `segments/2`, `setups/2` - read what each target ran;
    * `without_suffix/1` - a command list without its teardown commands;
    * `generated/4` - the sequence the generator produces for run n;
    * `run_seed_for/2`, `report_coordinates/1`, `report_run/1` - the seed and
      run coordinates, kept in one place;
    * `expansion_for/5` - calls `PropertyDamage.Expansion.for/5`;
    * `outcome/1` - runs a function and reports a raise as data.
  """

  alias PropertyDamage.{Generator, Sequence}

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule Funded do
    @moduledoc false
    defstruct [:amount, :by, :pid]
  end

  defmodule Noised do
    @moduledoc false
    defstruct [:n, :by, :pid]
  end

  defmodule Refunded do
    @moduledoc false
    defstruct [:amount, :by, :pid]
  end

  defmodule Credited do
    @moduledoc false
    defstruct [:amount, :part, :by, :pid]
  end

  defmodule Closed do
    @moduledoc false
    defstruct [:n, :by, :pid]
  end

  # ==========================================================================
  # Commands
  # ==========================================================================

  defmodule Fund do
    @moduledoc false
    # The setup command: its amount comes from its generator.
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(1..1_000_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Noise do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.integer(1..1_000_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Refund do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(2..1_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Credit do
    @moduledoc false
    # A leaf: `amount` and `part` come from `overrides:`, `memo` from the
    # leaf's own draw.
    use PropertyDamage.Command
    defstruct [:amount, :part, :memo]

    @impl true
    def generator(overrides \\ %{}) do
      %{
        amount: StreamData.integer(0..1_000),
        part: StreamData.constant(0),
        memo: StreamData.integer(1..1_000_000_000)
      }
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Close do
    @moduledoc false
    # The teardown command.
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.integer(1..1_000_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule World do
    @moduledoc false
    # The sequence projection: counts roots.
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ExpansionFor, as: F

    @impl true
    def init, do: %{roots: 0}

    @impl true
    def apply(state, %event{}) when event in [F.Noised, F.Refunded],
      do: %{state | roots: state.roots + 1}

    def apply(state, _other), do: state
  end

  defmodule Totals do
    @moduledoc false
    # The totals every target is compared on after every root. Both entries
    # of a Refund fold to the same totals.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ExpansionFor, as: F

    @impl true
    def init, do: %{funded: 0, refunded: 0, by: nil, pid: nil}

    @impl true
    def apply(state, %F.Funded{amount: a} = e), do: learn(%{state | funded: state.funded + a}, e)

    def apply(state, %F.Refunded{amount: a} = e),
      do: learn(%{state | refunded: state.refunded + a}, e)

    def apply(state, %F.Credited{amount: a} = e),
      do: learn(%{state | refunded: state.refunded + a}, e)

    def apply(state, %{by: _} = e), do: learn(state, e)
    def apply(state, _other), do: state

    defp learn(state, %{by: by, pid: pid}) when not is_nil(by), do: %{state | by: by, pid: pid}
    defp learn(state, _event), do: state

    @compare every: 1
    def totals(state, _root) do
      if is_pid(state.pid), do: send(state.pid, {:compared, state.by})
      {state.funded, state.refunded}
    end
  end

  defmodule Quiet do
    @moduledoc false
    # A check projection with no @compare function.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state
  end

  # ==========================================================================
  # Adapter
  # ==========================================================================

  defmodule Recorder do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.ExpansionFor, as: F

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

      if Map.get(ctx, :refuse) == command.__struct__,
        do: {:error, :refused},
        else: {:ok, [answer(command, ctx)]}
    end

    defp answer(%F.Fund{amount: a}, ctx), do: %F.Funded{amount: a, by: ctx.name, pid: ctx.pid}
    defp answer(%F.Noise{n: n}, ctx), do: %F.Noised{n: n, by: ctx.name, pid: ctx.pid}

    defp answer(%F.Refund{amount: a}, ctx),
      do: %F.Refunded{amount: a, by: ctx.name, pid: ctx.pid}

    defp answer(%F.Credit{amount: a, part: p}, ctx) do
      skew = if Map.get(ctx, :bug) == :credit, do: 1, else: 0
      %F.Credited{amount: a + skew, part: p, by: ctx.name, pid: ctx.pid}
    end

    defp answer(%F.Close{n: n}, ctx), do: %F.Closed{n: n, by: ctx.name, pid: ctx.pid}
  end

  # ==========================================================================
  # Models
  # ==========================================================================

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model

    alias PropertyDamage.Test.ExpansionFor, as: F

    @impl true
    def commands, do: [F.Noise, F.Refund]

    @impl true
    def command_sequence_projection, do: F.World

    @impl true
    def check_projections, do: [F.Totals]

    @impl true
    def simulator, do: F

    @impl true
    def setup_each, do: [F.Fund]

    @impl true
    def teardown_each, do: [F.Close]

    @impl true
    def expansions, do: [{F.Refund, &F.refund_split/2}]
  end

  defmodule PlainModel do
    @moduledoc false
    use PropertyDamage.Model

    alias PropertyDamage.Test.ExpansionFor, as: F

    @impl true
    def commands, do: [F.Noise]

    @impl true
    def command_sequence_projection, do: F.World

    @impl true
    def check_projections, do: [F.Quiet]

    @impl true
    def simulator, do: F
  end

  @doc false
  # Refund: `Refund[0]` is the identity; `Refund[1]` credits the amount in two
  # parts.
  def refund_split(%Refund{amount: n} = refund, _state) do
    half = div(n, 2)

    [
      [refund],
      [
        {Credit, overrides: %{amount: half, part: 0}},
        {Credit, overrides: %{amount: n - half, part: 1}}
      ]
    ]
  end

  @doc false
  # The simulator both models share: each command answers one event.
  def simulate(%Fund{amount: a}, _state), do: [%Funded{amount: a}]
  def simulate(%Noise{n: n}, _state), do: [%Noised{n: n}]
  def simulate(%Refund{amount: a}, _state), do: [%Refunded{amount: a}]
  def simulate(%Credit{amount: a, part: p}, _state), do: [%Credited{amount: a, part: p}]
  def simulate(%Close{n: n}, _state), do: [%Closed{n: n}]
  def simulate(_command, _state), do: []

  @doc false
  def setup_module, do: Fund

  @doc false
  def teardown_module, do: Close

  # ==========================================================================
  # Targets and what they ran
  # ==========================================================================

  @doc false
  # A `targets:` entry named `name` that reports to the calling process.
  def target(name, expansion \\ :random, config \\ %{}) do
    {Recorder,
     name: name, config: Map.merge(%{name: name, pid: self()}, config), expansion: expansion}
  end

  @doc false
  # Every recorder message already in the mailbox, in arrival order.
  def drain do
    receive do
      {tag, _name} = message when tag in [:setup, :teardown] -> [message | drain()]
      {:executed, _name, _command} = message -> [message | drain()]
    after
      0 -> []
    end
  end

  @doc false
  # The commands `name` executed, one list per execution (each setup/1 starts
  # one), in order.
  def segments(messages, name) do
    messages
    |> Enum.reduce([], fn
      {:setup, ^name}, acc -> [[] | acc]
      {:executed, ^name, command}, [current | rest] -> [[command | current] | rest]
      _other, acc -> acc
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  @doc false
  # How many times setup/1 ran for `name`.
  def setups(messages, name), do: Enum.count(messages, &(&1 == {:setup, name}))

  @doc false
  # `commands` without the teardown commands.
  def without_suffix(commands), do: Enum.reject(commands, &is_struct(&1, Close))

  @doc false
  # The sequence (setup commands, roots, teardown commands) the generator
  # produces for run `run` (1-based) of a campaign seeded with `seed`.
  def generated(model, seed, run, max_commands) do
    run_seed = run_seed_for(seed, run)

    sequence =
      model
      |> Generator.generate_sequence(max_commands: max_commands)
      |> Generator.generate_value(run_seed)

    Generator.teardown_commands(model, sequence, run_seed)
  end

  @doc false
  # The root commands of `generated/4`.
  def roots(model, seed, run, max_commands),
    do: model |> generated(seed, run, max_commands) |> Sequence.to_list()

  # ==========================================================================
  # Seed and run coordinates
  # ==========================================================================

  @doc false
  # The effective seed of run `run` (1-based) of a campaign seeded with `seed`.
  def run_seed_for(seed, run) when run >= 1, do: Generator.run_seed(seed, run - 1)

  @doc false
  # The `{seed, run}` that regenerates the failing run of `report`: its
  # effective seed, as run 1.
  def report_coordinates(report), do: {report.seed, 1}

  @doc false
  # The campaign run (1-based) `report` failed in.
  def report_run(report), do: Map.get(report, :run)

  # ==========================================================================
  # Calls into code that may not exist yet
  # ==========================================================================

  @doc false
  def expansion_module, do: Module.concat(PropertyDamage, Expansion)

  @doc false
  # `PropertyDamage.Expansion.for(model, seed, run, name, opts)`.
  def expansion_for(model, seed, run, name, opts \\ []) do
    args = [model, seed, run, name, opts]
    apply(expansion_module(), :for, args)
  end

  @doc false
  # `{:raised, exception}` when `fun` raises, otherwise `{:returned, result}`.
  def outcome(fun) do
    {:returned, fun.()}
  rescue
    error -> {:raised, error}
  end
end
