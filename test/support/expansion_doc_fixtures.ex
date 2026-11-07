defmodule PropertyDamage.Test.ExpansionDoc do
  @moduledoc false
  # Fixtures for the `doc:` of an expansion entry through shrinking.
  #
  # `Model` has two roots, `Flag` and `Pay`. A `Flag` root sets a flag in the
  # sequence state. `Pay` has expansions: the entries `put_spec/1` stores, and,
  # in front of them, one extra entry while the flag is set. Dropping the
  # `Flag` root therefore shifts the index of every entry behind the extra one.
  #
  # An entry of a spec is `{sequence, weight, doc}`. A sequence is a list of
  # leaf modules, or `:root` for the root itself (the listed identity). The
  # entries of a spec all differ as sequences, so a realized choice names the
  # entry it ran by its commands.
  #
  # The spec lives in `:persistent_term`, so tests that use `Model` must not
  # run concurrently with each other.

  alias PropertyDamage.Generator

  @leaf_count 6

  defmodule Flagged do
    @moduledoc false
    defstruct []
  end

  defmodule Paid do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Stepped do
    @moduledoc false
    defstruct [:leaf]
  end

  defmodule Flag do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Pay do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  for n <- 1..@leaf_count do
    defmodule Module.concat(__MODULE__, "Leaf#{n}") do
      @moduledoc false
      use PropertyDamage.Command
      defstruct []

      @impl true
      def generator(overrides \\ %{}) do
        %{}
        |> Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end
    end
  end

  defmodule World do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ExpansionDoc.Flagged

    @impl true
    def init, do: %{flag: false}

    @impl true
    def apply(state, %Flagged{}), do: %{state | flag: true}
    def apply(state, _other), do: state
  end

  defmodule Flags do
    @moduledoc false
    # Compares the flag on every target at every root: all targets agree.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ExpansionDoc.Flagged

    @impl true
    def init, do: %{flag: false}

    @impl true
    def apply(state, %Flagged{}), do: %{state | flag: true}
    def apply(state, _other), do: state

    @compare every: 1
    def flag(state, _root), do: state.flag
  end

  defmodule Adapter do
    @moduledoc false
    # Config: `:fail`, a command module whose every command answers an error.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.ExpansionDoc

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(command, ctx, _runtime) do
      if command.__struct__ == Map.get(ctx, :fail),
        do: {:error, {:refused, command.__struct__}},
        else: {:ok, ExpansionDoc.simulate(command, nil)}
    end
  end

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model

    alias PropertyDamage.Test.ExpansionDoc
    alias PropertyDamage.Test.ExpansionDoc.{Flag, Flags, Pay, World}

    def commands, do: [Flag, Pay]
    def expansions, do: [{Pay, &ExpansionDoc.entries/2}]
    def command_sequence_projection, do: World
    def check_projections, do: [Flags]
    def simulator, do: ExpansionDoc
  end

  @doc false
  def simulate(%Flag{}, _state), do: [%Flagged{}]
  def simulate(%Pay{amount: a}, _state), do: [%Paid{amount: a}]
  def simulate(%module{}, _state), do: [%Stepped{leaf: module}]

  @doc false
  def leaf(n) when n in 1..@leaf_count, do: Module.concat(__MODULE__, "Leaf#{n}")

  @doc false
  # Stores the spec `Model` lists: `%{front: entry | nil, base: [entry]}`.
  def put_spec(spec), do: :persistent_term.put({__MODULE__, :spec}, spec)

  @doc false
  # The entries `Model` lists for a `Pay` root: the front entry only while a
  # `Flag` root already ran.
  def entries(%Pay{} = pay, %{flag: flag}) do
    spec = :persistent_term.get({__MODULE__, :spec})
    front = if flag and spec.front, do: [spec.front], else: []
    Enum.map(front ++ spec.base, &listed(&1, pay))
  end

  defp listed({:root, weight, doc}, pay), do: listed({[pay], weight, doc}, pay)

  defp listed({sequence, weight, doc}, _pay) do
    options = if(weight == 1, do: [], else: [weight: weight]) ++ if(doc, do: [doc: doc], else: [])
    if options == [], do: sequence, else: {sequence, options}
  end

  @doc false
  # `%{command modules => doc}` for every entry of `spec`, the root as
  # `[Pay]`: what a realized choice's doc must equal, read from its commands.
  def docs_by_modules(spec) do
    for {sequence, _weight, doc} <- all_entries(spec), into: %{} do
      {if(sequence == :root, do: [Pay], else: sequence), doc}
    end
  end

  @doc false
  def all_entries(%{front: front, base: base}), do: Enum.reject([front | base], &is_nil/1)

  @doc false
  # A Recorder-free target: `fail` names the module whose commands are refused.
  def target(name, fail \\ nil) do
    {Adapter, name: name, config: %{name: name, fail: fail}}
  end

  @doc false
  def run(opts) do
    PropertyDamage.run(
      [
        model: Model,
        targets: [target("a", opts[:fail]), target("b")],
        max_runs: 1,
        max_commands: 6,
        seed: 1,
        shrink: true,
        validate: false,
        replay_dir: false
      ]
      |> Keyword.merge(Keyword.delete(opts, :fail))
    )
  end
end
