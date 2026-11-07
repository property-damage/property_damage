defmodule PropertyDamage.ShrinkMintedIdsTest do
  # A command whose `when:` needs two ids the system mints survives shrinking:
  # the validity check of a shrink candidate mints placeholders as generation
  # does, so a state keyed by minted ids keeps one key per id.
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, Sequence}

  defmodule Created do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Paired do
    @moduledoc false
    defstruct []
  end

  defmodule Create do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Pair do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Noop do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Ids do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{ids: %{}}

    @impl true
    def apply(state, %Created{id: id}), do: put_in(state.ids[id], true)
    def apply(state, _other), do: state
  end

  defmodule NoPair do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: :ok

    @impl true
    def apply(_state, %Paired{}), do: :paired
    def apply(state, _other), do: state

    @check every: 1
    def never_paired(state, _cmd_or_event), do: state != :paired or PropertyDamage.fail!("paired")
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Create{}, _ctx, _runtime),
      do: {:ok, [%Created{id: "id-#{System.unique_integer([:positive])}"}]}

    def execute(%Pair{}, _ctx, _runtime), do: {:ok, [%Paired{}]}
    def execute(%Noop{}, _ctx, _runtime), do: {:ok, []}
  end

  defmodule Model do
    @moduledoc false
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl PropertyDamage.Model
    def commands do
      [
        {Create, weight: 4},
        {Noop, weight: 4},
        {Pair, weight: 1, when: fn state -> map_size(state.ids) >= 2 end}
      ]
    end

    @impl PropertyDamage.Model
    def command_sequence_projection, do: Ids

    @impl PropertyDamage.Model
    def check_projections, do: [NoPair]

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Create{}, _state), do: [%Created{}]
    def simulate(%Pair{}, _state), do: [%Paired{}]
    def simulate(_command, _state), do: []
  end

  test "shrinks to the two creates the pair needs and the pair" do
    assert {:error, report} =
             PropertyDamage.run(
               model: Model,
               targets: [{Adapter, name: "minted"}],
               max_runs: 20,
               max_commands: 16,
               seed: 7
             )

    original = Sequence.to_list(report.original_sequence)
    shrunk = Sequence.to_list(FailureReport.shrunk_sequence(report))

    assert length(original) > 3
    assert Enum.map(shrunk, & &1.__struct__) == [Create, Create, Pair]
  end
end
