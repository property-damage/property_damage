defmodule PropertyDamage.LoadTest.WorkerSessionParityTest do
  # A worker that runs its sequences through the stepping seam executes the
  # same commands, with the same resolved placeholder values and the same
  # outcomes, as the worker's own loop does for the same seed and worker id.
  use ExUnit.Case, async: true

  alias PropertyDamage.Generator
  alias PropertyDamage.LoadTest.{Metrics, Worker}

  defmodule Created do
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Create do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: StreamData.fixed_map(Generator.merge_overrides(%{}, overrides))
  end

  defmodule Use do
    @behaviour PropertyDamage.Command
    defstruct [:target]

    @impl true
    def generator(overrides),
      do:
        StreamData.fixed_map(
          Generator.merge_overrides(%{target: StreamData.constant(nil)}, overrides)
        )
  end

  defmodule Boom do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: StreamData.fixed_map(Generator.merge_overrides(%{}, overrides))
  end

  defmodule Created.Projection do
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{created: []}

    @impl true
    def apply(state, %Created{id: id}), do: %{state | created: [id | state.created]}
    def apply(state, _other), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands do
      [
        Create,
        {Use,
         when: fn state -> state.created != [] end,
         overrides: fn state -> %{target: Generator.external_from(state, path: [:id])} end},
        Boom
      ]
    end

    @impl true
    def command_sequence_projection, do: Created.Projection

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Create{}, _state), do: [%Created{}]
    def simulate(_command, _state), do: []
  end

  defmodule Adapter do
    use PropertyDamage.Adapter, default_timeout: 1_000

    @impl true
    def setup(%{recorder: recorder}), do: {:ok, %{recorder: recorder}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Create{} = command, %{recorder: recorder}, _runtime) do
      id = "real_#{Agent.get_and_update(recorder, fn log -> {length(log), log} end)}"
      Agent.update(recorder, &[{command.__struct__, nil, :ok} | &1])
      {:ok, [%Created{id: id}]}
    end

    def execute(%Use{target: target}, %{recorder: recorder}, _runtime) do
      Agent.update(recorder, &[{Use, target, :ok} | &1])
      {:ok, []}
    end

    def execute(%Boom{}, %{recorder: recorder}, _runtime) do
      Agent.update(recorder, &[{Boom, nil, :error} | &1])
      {:error, :boom}
    end
  end

  # Runs `count` sequences on one worker and returns what it executed (the
  # adapter's log, in order), each sequence's result and the metrics' error
  # count.
  defp run_worker(session, count) do
    test_pid = self()
    handler = {__MODULE__, session, make_ref()}

    :telemetry.attach(
      handler,
      [:property_damage, :command, :stop],
      &__MODULE__.forward_command/4,
      test_pid
    )

    {:ok, recorder} = Agent.start_link(fn -> [] end)
    {:ok, metrics} = Metrics.start_link()

    opts = [
      worker_id: 3,
      seed: 20_261_109,
      model: Model,
      target: %PropertyDamage.Target{
        adapter: Adapter,
        config: %{recorder: recorder},
        name: "parity-#{session}",
        index: 0
      },
      metrics: metrics
    ]

    {:ok, worker} = Worker.start_link(Keyword.put(opts, :session, session))

    results =
      for _ <- 1..count do
        {:ok, result} = Worker.execute_sequence(worker)
        Map.take(result, [:commands_run, :errors])
      end

    Worker.stop(worker)
    Process.sleep(20)
    errors = Metrics.snapshot(metrics).errors_by_type
    Metrics.stop(metrics)
    :telemetry.detach(handler)
    {recorder |> Agent.get(& &1) |> Enum.reverse(), results, errors}
  end

  @doc false
  def forward_command(_event, _measure, %{variant: %{name: name}}, test_pid),
    do: send(test_pid, {:engine_command, name})

  defp engine_commands(name, acc \\ 0) do
    receive do
      {:engine_command, ^name} -> engine_commands(name, acc + 1)
    after
      0 -> acc
    end
  end

  test "a stepping worker executes what a legacy worker executes" do
    {legacy_log, legacy_results, legacy_errors} = run_worker(:legacy, 12)
    {stepping_log, stepping_results, stepping_errors} = run_worker(:stepping, 12)

    modules = fn log -> Enum.map(log, &elem(&1, 0)) end
    targets = fn log -> for {Use, target, _} <- log, do: target end
    outcomes = fn log -> Enum.map(log, &elem(&1, 2)) end

    # The series are not vacuous: commands ran, a consumer received a resolved
    # value and a command failed.
    assert modules.(legacy_log) != []
    assert targets.(legacy_log) != []
    assert Enum.all?(targets.(legacy_log), &is_binary(&1))
    assert :error in outcomes.(legacy_log)
    assert Enum.sum(Enum.map(legacy_results, & &1.errors)) > 0

    # Only the engine emits command events: the stepping worker ran every
    # command through it and the legacy worker none.
    assert engine_commands("parity-legacy") == 0
    assert engine_commands("parity-stepping") == length(stepping_log)

    assert modules.(stepping_log) == modules.(legacy_log)
    assert targets.(stepping_log) == targets.(legacy_log)
    assert outcomes.(stepping_log) == outcomes.(legacy_log)
    assert stepping_results == legacy_results
    assert stepping_errors == legacy_errors
  end
end
