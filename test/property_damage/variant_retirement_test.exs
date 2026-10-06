defmodule PropertyDamage.VariantRetirementTest do
  # A non-reference variant whose adapter fails at a root leaves the run before
  # the next root starts anywhere: the resource pollers it started are
  # stopped, and it steps no later command, so nothing ever resolves a
  # placeholder against its registry again. The observations in these models
  # always agree, so only the failure decides how the run goes on.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Generator, Sequence}
  alias PropertyDamage.Test.ActiveSet
  alias PropertyDamage.Test.ActiveSet.{Book, Booked}
  alias PropertyDamage.Test.LatencyFixtures.RefusingMintAdapter
  alias PropertyDamage.Test.Lockstep.{Create, RoutingModel, RoutingProjection, Use}

  defmodule Same do
    @moduledoc false
    # An observation every variant agrees on, whatever it executed.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @compare every: 1
    def same(_state, _root), do: :same
  end

  defmodule PollingBookAdapter do
    @moduledoc false
    # Config keys:
    #
    #   :name      target name
    #   :test_pid  receives {:poller_alive, name, n, alive?} for every poller
    #              in `pollers` at every command
    #   :pollers   Agent holding the pids of the pollers started so far
    #   :poll      start a resource poller that never finishes at command 0
    #   :fail      the command number answered with {:error, _}
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Book{n: n}, ctx, runtime) do
      for pid <- Agent.get(ctx.pollers, & &1) do
        send(ctx.test_pid, {:poller_alive, ctx.name, n, Process.alive?(pid)})
      end

      if n == 0 and ctx[:poll], do: start_poller(ctx, runtime)

      if n == ctx[:fail],
        do: {:error, {:refused, n}},
        else: {:ok, [%Booked{n: n, by: ctx.name}]}
    end

    defp start_poller(ctx, runtime) do
      poller =
        runtime.start_poller.(
          poll_fn: fn -> :waiting end,
          handler: fn :waiting -> :continue end,
          interval_ms: 10,
          timeout_ms: 10_000,
          on_timeout: :ignore
        )

      Agent.update(ctx.pollers, &[poller.pid | &1])
    end
  end

  defmodule RetireRoutingModel do
    @moduledoc false
    # RoutingModel's commands (a Use consumes a Create's minted id), compared
    # through an observation that always agrees.
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: RoutingModel.commands()

    @impl true
    def command_sequence_projection, do: RoutingProjection

    @impl true
    def check_projections, do: [PropertyDamage.VariantRetirementTest.Same]

    @impl true
    def simulator, do: RoutingModel
  end

  setup_all do
    model = ActiveSet.define_model!(Module.concat(__MODULE__, BookModel), [Same])
    {:ok, book_model: model}
  end

  describe "a retired variant" do
    test "has its resource pollers stopped before the next root starts", ctx do
      {:ok, pollers} = Agent.start_link(fn -> [] end)

      target = fn name, config ->
        {PollingBookAdapter,
         name: name, config: Map.merge(%{name: name, test_pid: self(), pollers: pollers}, config)}
      end

      targets = [
        target.("ret_a", %{}),
        target.("ret_b", %{}),
        target.("ret_c", %{poll: true, fail: 1})
      ]

      result =
        PropertyDamage.run(
          model: ctx.book_model,
          targets: targets,
          max_runs: 1,
          max_commands: 4,
          seed: 4_242,
          validate: false,
          shrink: false
        )

      alive = for {:poller_alive, name, n, alive?} <- take_all(), do: {name, n, alive?}

      # The poller was running while "ret_c" was still in the run.
      assert {"ret_a", 1, true} in alive

      # From root 2 on, in every surviving variant, it is gone.
      later = for {name, n, alive?} <- alive, n >= 2, do: {name, alive?}
      assert {"ret_a", false} in later
      assert Enum.all?(later, fn {_name, alive?} -> alive? == false end)

      assert {:error, report} = result
      assert report.variant == %{index: 2, name: "ret_c"}
      assert report.failed_at_index == 1
    end

    test "steps no later command, so its placeholder registry is never consulted again" do
      {seed, commands, first_create, use_at} = routing_seed()
      handler = attach_command_starts()

      targets = [
        mint_target("ret_a", false),
        mint_target("ret_b", false),
        mint_target("ret_c", true)
      ]

      result =
        PropertyDamage.run(
          model: RetireRoutingModel,
          targets: targets,
          max_runs: 1,
          max_commands: 12,
          seed: seed,
          validate: false,
          shrink: false
        )

      :telemetry.detach(handler)
      messages = take_all()
      started = fn name -> for {:command_start, ^name, index} <- messages, do: index end

      # "ret_c" never started the Use whose placeholder its own failed Create
      # would have had to mint, nor any other command after its failure.
      refute use_at in started.("ret_c")
      assert Enum.all?(started.("ret_c"), &(&1 <= first_create))

      # The survivors resolved the Use against their own minted ids.
      for name <- ["ret_a", "ret_b"] do
        assert use_at in started.(name)
        assert Enum.any?(received(messages, name), &match?(%Use{target: "id_" <> _}, &1))
      end

      assert Enum.count(commands, &match?(%Create{}, &1)) > 1
      assert {:error, report} = result
      assert report.kind == :execution_failed
      assert report.variant == %{index: 2, name: "ret_c"}
      assert report.failed_at_index == first_create
      assert report.other_failures == []
    end
  end

  # A seed whose run 0 has a Create, a later Use consuming its id, and a
  # Create after that Use.
  defp routing_seed do
    Enum.find_value(1..500, fn seed ->
      commands =
        RetireRoutingModel
        |> Generator.generate_sequence(max_commands: 12)
        |> Generator.generate_value(Generator.run_seed(seed, 0))
        |> Sequence.to_list()

      first_create = Enum.find_index(commands, &match?(%Create{}, &1))
      use_at = Enum.find_index(commands, &match?(%Use{}, &1))

      if first_create && use_at && use_at > first_create &&
           Enum.any?(Enum.drop(commands, use_at + 1), &match?(%Create{}, &1)) do
        {seed, commands, first_create, use_at}
      end
    end)
  end

  defp mint_target(name, refuse) do
    {RefusingMintAdapter,
     name: name, config: %{prefix: name, refuse_create: refuse, test_pid: self()}}
  end

  defp received(messages, prefix), do: for({:received, ^prefix, command} <- messages, do: command)

  # Sends {:command_start, variant name, index} to this test for every command
  # a variant whose name starts with "ret_" starts.
  defp attach_command_starts do
    handler = "variant-retirement-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:property_damage, :command, :start],
        &__MODULE__.forward_command_start/4,
        self()
      )

    handler
  end

  @doc false
  def forward_command_start(_event, _measurements, metadata, test_pid) do
    case metadata do
      %{variant: %{name: "ret_" <> _ = name}, index: index} ->
        send(test_pid, {:command_start, name, index})

      _other ->
        :ok
    end
  end

  defp take_all do
    receive do
      message -> [message | take_all()]
    after
      0 -> []
    end
  end
end
