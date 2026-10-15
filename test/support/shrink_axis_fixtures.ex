defmodule PropertyDamage.Test.ShrinkAxis do
  @moduledoc false
  # Models for the shrinker's expansion axis. `Add` and `Take` roots expand
  # into `Part` or `Piece` leaves that add up to the root's amount, and every
  # target is compared on the sum after every root. The `Adder` adapter sends
  # the recorder messages `PropertyDamage.Test.ExpansionFor.drain/0` reads
  # (`{:setup, name}`, `{:executed, name, command}`, `{:teardown, name}`).
  # Its `bug:` config:
  #
  #   :part1  a Part with `part: 1` answers one too many
  #   :part   every Part answers one too many
  #   :every  every command answers one too many

  alias PropertyDamage.Generator
  alias PropertyDamage.Test.ShrinkAxis, as: A

  defmodule Added do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Parted do
    @moduledoc false
    defstruct [:amount, :part]
  end

  defmodule Pieced do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Opened do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
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

  defmodule Add do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount, :account]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(2..40), account: StreamData.constant(nil)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Take do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(2..40)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Part do
    @moduledoc false
    # A leaf. `memo` is drawn by its generator (0 is the least it draws); the
    # expansions set every other field with `overrides:`.
    use PropertyDamage.Command
    defstruct [:amount, :part, :memo, :account]

    @impl true
    def generator(overrides \\ %{}) do
      %{
        amount: StreamData.integer(0..1_000),
        part: StreamData.constant(0),
        memo: StreamData.integer(0..1_000),
        account: StreamData.constant(nil)
      }
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Piece do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(0..1_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule World do
    @moduledoc false
    # The sequence projection: roots done, whether a Part ran, accounts open.
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ShrinkAxis, as: A

    @impl true
    def init, do: %{adds: 0, seen: false, accounts: []}

    @impl true
    def apply(state, %A.Added{}), do: %{state | adds: state.adds + 1}
    def apply(state, %A.Parted{}), do: %{state | seen: true}
    def apply(state, %A.Opened{id: id}), do: %{state | accounts: state.accounts ++ [id]}
    def apply(state, _event), do: state
  end

  defmodule Sum do
    @moduledoc false
    # The sum every target is compared on after every root.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{sum: 0}

    @impl true
    def apply(state, %{amount: amount}) when is_integer(amount),
      do: %{state | sum: state.sum + amount}

    def apply(state, _event), do: state

    @compare every: 1
    def sum(state, _root), do: state.sum
  end

  defmodule Adder do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.ShrinkAxis, as: A

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

    defp answer(%A.Open{}, _ctx),
      do: %A.Opened{id: "account-#{System.unique_integer([:positive])}"}

    defp answer(%A.Add{amount: a} = c, ctx), do: %A.Added{amount: a + skew(c, ctx)}
    defp answer(%A.Take{amount: a} = c, ctx), do: %A.Added{amount: a + skew(c, ctx)}

    defp answer(%A.Part{amount: a, part: p} = c, ctx),
      do: %A.Parted{amount: a + skew(c, ctx), part: p}

    defp answer(%A.Piece{amount: a} = c, ctx), do: %A.Pieced{amount: a + skew(c, ctx)}

    defp skew(%A.Part{part: 1}, %{bug: :part1}), do: 1
    defp skew(%A.Part{}, %{bug: :part}), do: 1
    defp skew(_command, %{bug: :every}), do: 1
    defp skew(_command, _ctx), do: 0
  end

  @doc false
  # Add: one Part of the whole amount, or two Parts (`part` 0 and 1). The
  # root alone is not listed.
  def parts(%Add{amount: n, account: account}, _state) do
    [[part(n, 0, account)], [part(div(n, 2), 0, account), part(n - div(n, 2), 1, account)]]
  end

  @doc false
  # Add: the root alone, or two Parts.
  def add_or_parts(%Add{amount: n} = add, _state),
    do: [[add], [part(div(n, 2), 0, nil), part(n - div(n, 2), 1, nil)]]

  @doc false
  # Take: the root alone and two Parts; once a Part ran, also two Pieces.
  def take_entries(%Take{amount: n} = take, state) do
    parts = [part(div(n, 2), 0, nil), part(n - div(n, 2), 1, nil)]

    pieces = [
      {Piece, overrides: %{amount: div(n, 2)}},
      {Piece, overrides: %{amount: n - div(n, 2)}}
    ]

    if state.seen, do: [[take], parts, pieces], else: [[take], parts]
  end

  defp part(amount, part, account),
    do: {Part, overrides: %{amount: amount, part: part, account: account}}

  @doc false
  # The simulator every model here shares: each command answers one event.
  def simulate(%Open{}, _state), do: [%Opened{}]
  def simulate(%Add{amount: a}, _state), do: [%Added{amount: a}]
  def simulate(%Take{amount: a}, _state), do: [%Added{amount: a}]
  def simulate(%Part{amount: a, part: p}, _state), do: [%Parted{amount: a, part: p}]
  def simulate(%Piece{amount: a}, _state), do: [%Pieced{amount: a}]
  def simulate(_command, _state), do: []

  defmodule PartsModel do
    @moduledoc false
    # Add roots only; the function does not list the root alone.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.ShrinkAxis, as: A

    @impl true
    def commands, do: [A.Add]
    @impl true
    def command_sequence_projection, do: A.World
    @impl true
    def check_projections, do: [A.Sum]
    @impl true
    def simulator, do: A
    @impl true
    def expansions, do: [{A.Add, &A.parts/2}]
  end

  defmodule AccountModel do
    @moduledoc false
    # An Open mints an account id; every Add credits the last account opened,
    # so the roots and their leaves hold a placeholder.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.ShrinkAxis, as: A

    @impl true
    def commands,
      do: [
        A.Open,
        {A.Add, when: &(&1.accounts != []), overrides: &%{account: List.last(&1.accounts)}}
      ]

    @impl true
    def command_sequence_projection, do: A.World
    @impl true
    def check_projections, do: [A.Sum]
    @impl true
    def simulator, do: A
    @impl true
    def expansions, do: [{A.Add, &A.parts/2}]
  end

  defmodule StateModel do
    @moduledoc false
    # A Take offers its Pieces only once a Part ran in the target's own state.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.ShrinkAxis, as: A

    @impl true
    def commands, do: [A.Add, {A.Take, when: &(&1.adds >= 1)}]
    @impl true
    def command_sequence_projection, do: A.World
    @impl true
    def check_projections, do: [A.Sum]
    @impl true
    def simulator, do: A
    @impl true
    def expansions, do: [{A.Add, &A.add_or_parts/2}, {A.Take, &A.take_entries/2}]
  end

  @doc false
  # A `targets:` entry for the `Adder` adapter that reports to the calling
  # process.
  def target(name, expansion \\ :random, config \\ %{}) do
    {Adder,
     name: name, config: Map.merge(%{name: name, pid: self()}, config), expansion: expansion}
  end
end
