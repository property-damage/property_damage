defmodule PropertyDamage.ShrinkReplayableTest.Fixtures do
  @moduledoc false
  # A model whose simulator mints an account id for an Open only once
  # another Open ran before it. Every Add credits the last account opened,
  # with no `when:` that would keep that earlier Open in a shrink candidate.
  # A candidate that drops the earlier Open still holds the id the original
  # run minted, but simulating its roots again mints nothing for the Open
  # that is left.
  alias PropertyDamage.Test.ShrinkAxis, as: A

  defmodule Marker do
    @moduledoc false
    defstruct []
  end

  defmodule World do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ShrinkAxis, as: A

    @impl true
    def init, do: %{adds: 0, seen: false, accounts: [], opens: 0}

    @impl true
    def apply(state, %A.Open{}), do: %{state | opens: state.opens + 1}
    def apply(state, %A.Opened{id: id}), do: %{state | accounts: state.accounts ++ [id]}
    def apply(state, %A.Added{}), do: %{state | adds: state.adds + 1}
    def apply(state, %A.Parted{}), do: %{state | seen: true}
    def apply(state, _other), do: state
  end

  def simulate(%A.Open{}, %{opens: n}) when n >= 1, do: [%A.Opened{}]
  def simulate(%A.Open{}, _state), do: [%Marker{}]
  def simulate(command, state), do: A.simulate(command, state)

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model

    alias PropertyDamage.Test.ShrinkAxis, as: A

    @impl true
    def commands, do: [A.Open, {A.Add, overrides: &%{account: List.last(&1.accounts)}}]
    @impl true
    def command_sequence_projection, do: PropertyDamage.ShrinkReplayableTest.Fixtures.World
    @impl true
    def check_projections, do: [A.Sum]
    @impl true
    def simulator, do: PropertyDamage.ShrinkReplayableTest.Fixtures
    @impl true
    def expansions, do: [{A.Add, &A.parts/2}]
  end

  defmodule PlainModel do
    @moduledoc false
    # Without expansions: every Open mints an account and every Add credits
    # the last one opened.
    use PropertyDamage.Model

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
  end
end

defmodule PropertyDamage.ShrinkReplayableTest do
  # A shrunk failure replays from its own artifact even when the model's
  # simulator mints an id only in some states: a shrink candidate whose
  # roots, simulated again as the artifact's replay simulates them, would
  # not mint every id its commands hold is invalid and never runs.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, Replay}
  alias PropertyDamage.ShrinkReplayableTest.Fixtures
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R
  alias PropertyDamage.Test.ShrinkAxis, as: A

  # At seed 7 with 8 commands the run fails in "second" at an Add whose
  # account the third Open minted (two Opens ran before it).
  @seed 7

  defp targets, do: [A.target("ref"), A.target("second", :random, %{bug: :part1})]

  defp identity(report),
    do:
      {report.kind, Failure.name(report.failure_reason), report.variant.name,
       report.failed_at_index}

  defp failing do
    dir = R.tmp_dir!()

    assert {:error, report} =
             R.run(Fixtures.Model, targets(),
               seed: @seed,
               max_runs: 1,
               max_commands: 8,
               replay_dir: dir,
               seed_library: false
             )

    {report, F.drain()}
  end

  test "the shrunk failure replays from its artifact and steps through Replay.run" do
    {report, _messages} = failing()

    assert report.replay_status == :written

    assert Enum.any?(
             R.roots(report),
             &is_struct(Map.get(&1, :account), PropertyDamage.Placeholder)
           )

    assert {:error, again} =
             R.run(Fixtures.Model, targets(),
               only: [replay: report.replay_path],
               replay_dir: false
             )

    F.drain()
    assert again.replay_status == :reproduced
    assert identity(again) == identity(report)

    assert {:ok, steps} = Replay.run(report)
    F.drain()
    assert steps != []
    assert Enum.all?(steps, &(&1.result == :ok))
  end

  test "a candidate that keeps one Open before a credited account never runs" do
    {_report, messages} = failing()

    # Only a second Open mints an account, so an execution that credits an
    # account after a single Open ran a candidate whose replay could not
    # resolve that account.
    unreplayable =
      for name <- ["ref", "second"],
          executed <- F.segments(messages, name),
          Enum.count(executed, &is_struct(&1, A.Open)) == 1,
          Enum.any?(executed, &(Map.get(&1, :account) != nil)),
          do: {name, executed}

    assert F.setups(messages, "ref") > 2
    assert unreplayable == []
  end

  test "without expansions, a shrunk failure whose account was minted by a later Open replays" do
    dir = R.tmp_dir!()
    targets = [A.target("ref"), A.target("second", :random, %{bug: :every})]

    # At seed 1 the shrink drops the first Open; the Open left was generated
    # second, so the account the Add credits names that position.
    assert {:error, report} =
             R.run(Fixtures.PlainModel, targets,
               seed: 1,
               max_runs: 1,
               max_commands: 8,
               replay_dir: dir,
               seed_library: false
             )

    F.drain()
    assert [%A.Open{}, %A.Add{account: %PropertyDamage.Placeholder{}}] = R.roots(report)
    assert report.replay_status == :written

    assert {:error, again} =
             R.run(Fixtures.PlainModel, targets,
               only: [replay: report.replay_path],
               replay_dir: false
             )

    F.drain()
    assert again.replay_status == :reproduced
    assert identity(again) == identity(report)

    # The artifact records each root under the id it was generated with.
    assert [first, second] = Enum.map(report.replay.roots, & &1.root_id)
    assert first < second and second > 1
  end
end
