defmodule PropertyDamage.ExternalMarkersPathsTest do
  @moduledoc """
  Every path that generates or simulates commands again under a run reads the
  run's `external_markers:` option: the teardown draw, the expansion walk, the
  shrinker, the replay of an artifact and a re-shrink. An atom marker in an
  event struct becomes a placeholder on each of them, so the command that
  consumes it receives the id the SUT minted, never the marker atom.
  """
  use ExUnit.Case, async: false

  # A run that fails before a Create executes skips the Release of that
  # order with a warning.
  @moduletag :capture_log

  alias PropertyDamage.Failure

  @marker :__order_id__

  defmodule Created do
    @moduledoc false
    defstruct id: :__order_id__, name: nil
  end

  defmodule Shipped do
    @moduledoc false
    defstruct [:order_id]
  end

  defmodule Tracked do
    @moduledoc false
    defstruct [:order_id]
  end

  defmodule Released do
    @moduledoc false
    defstruct [:order_id]
  end

  defmodule Create do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:name]

    @impl true
    def generator(overrides \\ %{}) do
      %{name: StreamData.member_of(["alice", "bob"])}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Ship do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:order_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{order_id: StreamData.constant(nil)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Track do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:order_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{order_id: StreamData.constant(nil)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Release do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:order_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{order_id: StreamData.constant(nil)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Orders do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{orders: %{}}

    @impl true
    def apply(state, %Created{} = event), do: put_in(state, [:orders, event.id], event.name)
    def apply(state, _event), do: state
  end

  defmodule Agreement do
    @moduledoc false
    # The final-boundary comparison a model with expansions declares.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @compare every: :end
    def nothing(_state, _root), do: :ok
  end

  defmodule Sim do
    @moduledoc false
    # The simulator every model below shares, and the id each consumer takes.

    def simulate(%Create{name: name}, _state), do: [%Created{name: name}]
    def simulate(%Ship{order_id: id}, _state), do: [%Shipped{order_id: id}]
    def simulate(%Track{order_id: id}, _state), do: [%Tracked{order_id: id}]
    def simulate(%Release{order_id: id}, _state), do: [%Released{order_id: id}]

    def commands do
      [
        {Create, weight: 1},
        {Ship,
         weight: 2,
         when: fn state -> map_size(state.orders) > 0 end,
         overrides: fn state -> %{order_id: StreamData.member_of(ids(state))} end}
      ]
    end

    # The last order the state holds, or nil.
    def last_id(state), do: state |> ids() |> List.last()

    defp ids(state), do: state.orders |> Map.keys() |> Enum.sort()
  end

  defmodule TeardownModel do
    @moduledoc false
    # Each run ends with a Release of the last order its roots created.
    use PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl true
    def commands, do: Sim.commands()

    @impl true
    def teardown_each do
      [{Release, overrides: fn state -> %{order_id: StreamData.constant(Sim.last_id(state))} end}]
    end

    @impl true
    def command_sequence_projection, do: Orders
    @impl true
    def check_projections, do: []
    @impl true
    def simulator, do: __MODULE__
    @impl true
    defdelegate simulate(command, state), to: Sim
  end

  defmodule ExpansionModel do
    @moduledoc false
    # A Ship root runs as three leaves: a Track of the last order the roots
    # before it created, a Create, and a Track of the order that Create made.
    use PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl true
    def commands, do: Sim.commands()

    @impl true
    def expansions do
      [
        {Ship,
         fn _ship, _state ->
           [
             [
               {Track,
                overrides: fn state -> %{order_id: StreamData.constant(Sim.last_id(state))} end},
               Create,
               {Track,
                overrides: fn _state, done -> %{order_id: StreamData.constant(created(done))} end}
             ]
           ]
         end}
      ]
    end

    @impl true
    def check_projections, do: [Agreement]

    defp created(done) do
      Enum.find_value(done, fn %{events: events} ->
        Enum.find_value(events, fn
          %Created{id: id} -> id
          _event -> nil
        end)
      end)
    end

    @impl true
    def command_sequence_projection, do: Orders
    @impl true
    def simulator, do: __MODULE__
    @impl true
    defdelegate simulate(command, state), to: Sim
  end

  defmodule Adapter do
    @moduledoc false
    # Mints an order id per Create and logs the id every consumer receives.
    # With `fail: kind` it rejects every consumer it logs as `kind`.
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def execute(%Create{name: name}, ctx, _runtime) do
      id = "ord_#{System.unique_integer([:positive])}"
      Agent.update(ctx.log, &[{:minted, id} | &1])
      {:ok, [%Created{id: id, name: name}]}
    end

    def execute(%Ship{order_id: id}, ctx, _runtime),
      do: consume(ctx, :shipped, id, [%Shipped{order_id: id}])

    def execute(%Track{order_id: id}, ctx, _runtime),
      do: consume(ctx, :tracked, id, [%Tracked{order_id: id}])

    def execute(%Release{order_id: id}, ctx, _runtime) do
      Agent.update(ctx.log, &[{:released, id} | &1])
      {:ok, [%Released{order_id: id}]}
    end

    defp consume(ctx, kind, id, events) do
      Agent.update(ctx.log, &[{kind, id} | &1])
      if ctx.fail == kind, do: {:error, :rejected}, else: {:ok, events}
    end

    @impl true
    def teardown(_ctx), do: :ok
  end

  setup do
    {:ok, log} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(log), do: Agent.stop(log) end)
    %{log: log}
  end

  defp run(model, log, extra) do
    fail = Keyword.get(extra, :fail)
    # A replay runs the one run its artifact records, from the seed it records.
    draw = if extra[:only], do: [], else: [max_runs: 10, max_commands: 6, seed: 1]

    PropertyDamage.run(
      [
        model: model,
        targets: [{Adapter, config: %{log: log, fail: fail}}],
        verbose: false,
        replay_dir: false,
        external_markers: [@marker]
      ]
      |> Keyword.merge(draw)
      |> Keyword.merge(Keyword.delete(extra, :fail))
    )
  end

  # The ids the SUT received for `kind`, nil ids left out, with every id the
  # SUT minted.
  defp received(log, kind) do
    entries = Agent.get(log, & &1)
    minted = for {:minted, id} <- entries, do: id
    {for({^kind, id} <- entries, id != nil, do: id), minted}
  end

  defp assert_resolved(log, kind) do
    {ids, minted} = received(log, kind)

    assert ids != [], "the SUT received no #{kind} id"
    refute @marker in ids, "the SUT received the marker atom as a #{kind} id"
    assert Enum.all?(ids, &(&1 in minted)), "#{kind} ids not minted: #{inspect(ids -- minted)}"
  end

  defp reset(log), do: Agent.update(log, fn _ -> [] end)

  describe "teardown generation" do
    test "run/1 draws teardown commands against the ids the SUT minted", %{log: log} do
      assert {:ok, _} = run(TeardownModel, log, [])
      assert_resolved(log, :released)
    end

    test "a shrink draws its candidates' teardown commands against minted ids", %{log: log} do
      assert {:error, report} = run(TeardownModel, log, fail: :shipped)
      assert report.shrink_iterations > 0
      assert_resolved(log, :released)
    end
  end

  describe "expansion walk" do
    test "run/1 realizes leaves against the ids the SUT minted", %{log: log} do
      assert {:ok, _} = run(ExpansionModel, log, [])
      assert_resolved(log, :tracked)
    end

    test "a shrink realizes its candidates' leaves against minted ids", %{log: log} do
      assert {:error, report} = run(ExpansionModel, log, fail: :tracked)
      assert report.shrink_iterations > 0
      assert_resolved(log, :tracked)
    end
  end

  describe "replay of an artifact" do
    @describetag :tmp_dir

    test "only: [replay: path] registers the ids its recorded roots consume",
         %{log: log, tmp_dir: dir} do
      assert {:error, report} = run(TeardownModel, log, fail: :shipped, replay_dir: dir)
      assert report.replay_status == :written
      reset(log)

      assert {:error, replayed} =
               run(TeardownModel, log,
                 fail: :shipped,
                 replay_dir: false,
                 only: [replay: report.replay_path]
               )

      assert Failure.name(replayed.failure_reason) == Failure.name(report.failure_reason)
      assert_resolved(log, :shipped)
    end

    test "only: [replay: path] registers the ids the recorded leaves consume",
         %{log: log, tmp_dir: dir} do
      assert {:error, report} = run(ExpansionModel, log, fail: :tracked, replay_dir: dir)
      assert report.replay_status == :written
      reset(log)

      assert {:error, replayed} =
               run(ExpansionModel, log,
                 fail: :tracked,
                 replay_dir: false,
                 only: [replay: report.replay_path]
               )

      assert Failure.name(replayed.failure_reason) == Failure.name(report.failure_reason)
      assert_resolved(log, :tracked)
    end
  end

  describe "a saved report" do
    @describetag :tmp_dir

    defp save_and_load(report, dir) do
      {:ok, path} = PropertyDamage.Persistence.save(report, dir)

      case PropertyDamage.Persistence.load(path) do
        {:ok, loaded} -> loaded
        {:ok, loaded, _warnings} -> loaded
      end
    end

    test "keeps the run's external markers through a save and a load",
         %{log: log, tmp_dir: dir} do
      assert {:error, report} = run(ExpansionModel, log, fail: :tracked, shrink: false)

      loaded = save_and_load(report, dir)

      assert Map.get(loaded, :external_markers) == [@marker]
    end

    test "replays through PropertyDamage.replay/1 with the markers it records",
         %{log: log, tmp_dir: dir} do
      assert {:error, report} = run(ExpansionModel, log, fail: :tracked, shrink: false)
      loaded = save_and_load(report, dir)
      reset(log)

      assert {:ok, _steps} = PropertyDamage.replay(loaded)

      assert_resolved(log, :tracked)
    end
  end

  describe "re-shrink" do
    test "shrink_further/2 re-executes with the markers it is given", %{log: log} do
      assert {:error, report} = run(ExpansionModel, log, fail: :tracked, shrink: false)
      reset(log)

      assert {:ok, _further} =
               PropertyDamage.shrink_further(report, external_markers: [@marker])

      assert_resolved(log, :tracked)
    end
  end
end
