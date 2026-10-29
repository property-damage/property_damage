defmodule PropertyDamage.ExpansionRootPlaceholderStateTest do
  # A target that ran a rewrite at a root holds, in its simulated state, the
  # root's placeholder where the aliased leaf placeholder would be. A later
  # root generated against the root sequence carries the root's placeholder,
  # so its `simulate/2`, an expansion function and a leaf's `overrides:` find
  # it in that state, as they do in a target that ran the root as itself.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Expansion, Generator}

  defmodule Opened do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Reserved do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Used do
    @moduledoc false
    defstruct [:account_id]
  end

  defmodule Open do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Reserve do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Confirm do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Use do
    @moduledoc false
    use PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]
    defstruct [:account_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{account_id: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Touch do
    @moduledoc false
    use PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]
    defstruct [:account_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{account_id: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Accounts do
    @moduledoc false
    # The sequence projection: the accounts opened so far, keyed by id.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{accounts: %{}}

    @impl true
    def apply(state, %Opened{id: id}), do: put_in(state.accounts[id], %{uses: 0})
    def apply(state, _other), do: state
  end

  defmodule Counts do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{opened: 0, used: 0}

    @impl true
    def apply(state, %Opened{}), do: %{state | opened: state.opened + 1}
    def apply(state, %Used{}), do: %{state | used: state.used + 1}
    def apply(state, _other), do: state

    @compare every: 1
    def counts(state, _root), do: state
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Open{}, _ctx, _runtime), do: {:ok, [%Opened{id: id("open")}]}
    def execute(%Confirm{}, _ctx, _runtime), do: {:ok, [%Opened{id: id("open")}]}
    def execute(%Reserve{}, _ctx, _runtime), do: {:ok, [%Reserved{id: id("res")}]}
    def execute(%Use{account_id: id}, _ctx, _runtime), do: {:ok, [%Used{account_id: id}]}
    def execute(%Touch{account_id: id}, _ctx, _runtime), do: {:ok, [%Used{account_id: id}]}

    defp id(kind), do: "#{kind}-#{System.unique_integer([:positive])}"
  end

  defmodule Model do
    @moduledoc false
    # Open runs as Reserve then Confirm; Confirm produces the root's Opened id.
    # Use looks its account up in state, as a model's simulator does.
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands do
      [
        {Open, when: &(map_size(&1.accounts) == 0)},
        {Use,
         when: &(map_size(&1.accounts) > 0),
         overrides: fn s ->
           %{account_id: StreamData.member_of(Enum.sort(Map.keys(s.accounts)))}
         end}
      ]
    end

    @impl true
    def command_sequence_projection, do: Accounts

    @impl true
    def check_projections, do: [Counts]

    @impl true
    def expansions, do: [{Open, fn _open, _state -> [[Reserve, Confirm]] end}]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Open{}, _state), do: [%Opened{}]
    def simulate(%Reserve{}, _state), do: [%Reserved{}]
    def simulate(%Confirm{}, _state), do: [%Opened{}]

    def simulate(%Use{account_id: id}, state) do
      %{uses: _} = Map.fetch!(state.accounts, id)
      [%Used{account_id: id}]
    end

    def simulate(%Touch{account_id: id}, _state), do: [%Used{account_id: id}]
  end

  defmodule ReaderModel do
    @moduledoc false
    # Model, with Use rewritten as Touch: the expansion function and Touch's
    # `overrides:` look the root's id up in the target's state.
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    defdelegate commands, to: Model

    @impl true
    defdelegate command_sequence_projection, to: Model

    @impl true
    defdelegate check_projections, to: Model

    @impl true
    def expansions do
      [
        {Open, fn _open, _state -> [[Reserve, Confirm]] end},
        {Use,
         fn %Use{account_id: id}, state ->
           %{uses: _} = Map.fetch!(state.accounts, id)

           [
             [
               {Touch,
                overrides: fn s ->
                  %{uses: _} = Map.fetch!(s.accounts, id)
                  %{account_id: id}
                end}
             ]
           ]
         end}
      ]
    end

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    defdelegate simulate(command, state), to: Model
  end

  defmodule Guard do
    @moduledoc false
    # Fails once a use follows a reserve, so a failure needs a rewritten Open
    # and a Use after it, and shrinking keeps both.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{reserved: 0, used: 0}

    @impl true
    def apply(state, %Reserved{}), do: %{state | reserved: state.reserved + 1}
    def apply(state, %Used{}), do: %{state | used: state.used + 1}
    def apply(state, _other), do: state

    @check every: 1
    def no_use_after_reserve(state, _cmd_or_event) do
      not (state.reserved >= 1 and state.used >= 1) or
        PropertyDamage.fail!("a use after a reserve")
    end
  end

  defmodule FollowModel do
    @moduledoc false
    # ReaderModel with a check that keeps a rewritten Open and a Use after it
    # through shrinking, so a second target follows the reference's rewrite.
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    defdelegate commands, to: ReaderModel

    @impl true
    defdelegate command_sequence_projection, to: ReaderModel

    @impl true
    def check_projections, do: [Counts, Guard]

    # Two entries for Open, so two `:random` targets can differ there; the
    # second never reserves, so a run that fails ran the first.
    @impl true
    def expansions do
      [
        {Open, fn _open, _state -> [[Reserve, Confirm], [Confirm]] end}
        | tl(ReaderModel.expansions())
      ]
    end

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    defdelegate simulate(command, state), to: Model
  end

  defmodule LeafWhenModel do
    @moduledoc false
    # ReaderModel with Touch listed as a command whose `when:` reads the
    # accounts the rewritten Open produced: a leaf's precondition is its
    # module's `commands/0` `when:`, evaluated against the target's state.
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands do
      [
        {Open, when: &(map_size(&1.accounts) == 0)},
        {Use,
         when: &(map_size(&1.accounts) > 0),
         overrides: fn s ->
           %{account_id: StreamData.member_of(Enum.sort(Map.keys(s.accounts)))}
         end},
        {Touch,
         when: fn s ->
           Enum.any?(s.accounts, fn {_id, account} -> match?(%{uses: _}, account) end)
         end,
         overrides: fn s ->
           %{account_id: StreamData.member_of(Enum.sort(Map.keys(s.accounts)))}
         end}
      ]
    end

    @impl true
    defdelegate command_sequence_projection, to: ReaderModel

    @impl true
    defdelegate check_projections, to: ReaderModel

    @impl true
    defdelegate expansions, to: ReaderModel

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    defdelegate simulate(command, state), to: Model
  end

  defp run(model) do
    PropertyDamage.run(
      model: model,
      targets: [{Adapter, name: "split"}],
      max_runs: 3,
      max_commands: 4,
      seed: 1,
      shrink: false
    )
  end

  test "a later root's simulate/2 finds the rewritten root's id in the target's state" do
    assert {:ok, stats} = run(Model)
    assert %{"split" => %{Open => %{"Open[0]" => opens}}} = stats.expansion_counts
    assert opens == 3
  end

  test "an expansion function and a leaf's overrides: find the rewritten root's id" do
    assert {:ok, stats} = run(ReaderModel)

    assert %{"split" => %{Open => %{"Open[0]" => 3}, Use => %{"Use[0]" => uses}}} =
             stats.expansion_counts

    assert uses > 0
  end

  test "a replay of the recorded leaves presents the root's id to a later root" do
    sequence =
      Model |> Generator.generate_sequence(max_commands: 4) |> Generator.generate_value(1)

    [%Open{} | uses] = PropertyDamage.Sequence.to_list(sequence)
    assert uses != []

    recorded =
      [%{root_id: 0, entry: "Open[0]", commands: [%Reserve{}, %Confirm{}]}] ++
        for {use, root_id} <- Enum.with_index(uses, 1),
            do: %{root_id: root_id, entry: nil, commands: [use]}

    replayed = Expansion.recorded(Model, sequence, 1, %{"split" => recorded}, %{})

    assert [%{leaves?: true, aliases: aliases} | rest] = replayed.variants["split"].choices
    assert map_size(aliases) == 1
    assert Enum.map(rest, & &1.commands) == Enum.map(uses, &[&1])
  end

  test "a leaf's when: holds against the state that carries the rewritten root's id" do
    assert {:ok, stats} = run(LeafWhenModel)

    assert %{"split" => %{Open => %{"Open[0]" => 3}, Use => %{"Use[0]" => uses}}} =
             stats.expansion_counts

    assert uses > 0
  end

  test "the :follow shrink path presents the root's id to the roots after the copied leaves" do
    targets = [{Adapter, name: "ref"}, {Adapter, name: "copy"}]

    run = fn seed, opts ->
      PropertyDamage.run(
        [
          model: FollowModel,
          targets: targets,
          seed: seed,
          max_commands: 4,
          max_runs: 1,
          compare: [converge_within: 1],
          replay_dir: false,
          validate: false
        ] ++ opts
      )
    end

    choice = fn report, name, root -> Enum.at(report.expansions[name], root) end

    entry = fn report, name, root -> choice.(report, name, root).entry end

    # A seed whose run fails with the reference running Open as the reserving
    # entry and the copy as the other, so phase 3 has a choice to copy.
    seed =
      Enum.find(1..80, fn seed ->
        case run.(seed, shrink: false) do
          {:error, report} ->
            report.kind == :check_failed and entry.(report, "ref", 0) == "Open[0]" and
              entry.(report, "copy", 0) == "Open[1]"

          {:ok, _stats} ->
            false
        end
      end) || flunk("no seed in 1..80 fails with the reserving entry in the reference only")

    assert {:error, report} = run.(seed, [])
    assert report.kind == :check_failed

    ref = choice.(report, "ref", 0)
    copy = choice.(report, "copy", 0)
    assert ref.entry == "Open[0]", "the reference kept its rewrite through shrinking"

    assert {copy.entry, copy.leaves} == {ref.entry, ref.leaves}, "the copy followed the reference"
  end
end
