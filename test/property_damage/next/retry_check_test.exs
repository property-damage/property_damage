defmodule PropertyDamage.Next.RetryCheckTest do
  # A retry is a fault in the model's own terms: a layer sets the assign
  # `retry` beside a command, the adapter's catch-all clause for it runs the
  # call twice and acknowledges the assign, and a check compares what the two
  # calls returned. PD gains no function for it; the event that carries both
  # answers is the test's own.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Gen, Report, StepSpec}

  defmodule Created do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    # `at` is when the system answered; `id` is the record's identity.
    defstruct [:name, :at, id: external()]
  end

  defmodule Retried do
    @moduledoc false
    # The answers of the first call and of the call made again.
    defstruct [:first, :again]
  end

  defmodule Create do
    @moduledoc false
    use PropertyDamage.Next.Command

    defstruct [:name, :key]

    def generator(_state, _opts), do: %{name: integer(1..5), key: mint_per_run(:uuid)}
  end

  defmodule Directory do
    @moduledoc """
    A system that creates records. With `idempotent: true` a second create
    with the same key answers with the record already made, stamped anew;
    otherwise it makes a second record.
    """
    use Agent

    def start(idempotent?),
      do: Agent.start_link(fn -> %{idempotent?: idempotent?, records: %{}} end)

    def create(directory, name, key) do
      Agent.get_and_update(directory, fn state ->
        case state do
          %{idempotent?: true, records: %{^key => id}} -> {{:ok, id, stamp()}, state}
          _ -> new_record(state, name, key)
        end
      end)
    end

    defp new_record(state, _name, key) do
      id = "rec_#{map_size(state.records) + 1}_#{System.unique_integer([:positive])}"
      {{:ok, id, stamp()}, %{state | records: Map.put(state.records, key, id)}}
    end

    defp stamp, do: System.unique_integer([:monotonic])
  end

  defmodule Projection do
    @moduledoc false
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Next.RetryCheckTest.{Create, Retried}

    @impl true
    def init, do: %{retried: []}

    @impl true
    def apply(state, %Retried{} = retried), do: %{state | retried: [retried | state.retried]}
    def apply(state, _event), do: state

    # The two answers must be equal except for their timestamps; their ids
    # are compared.
    @check every: Create
    def retry_answers_agree(state, _command) do
      Enum.all?(state.retried, fn %Retried{first: first, again: again} ->
        untimed(first) == untimed(again) or
          PropertyDamage.fail!("The retry answered differently from the first call",
            first: first,
            again: again
          )
      end)
    end

    defp untimed(events), do: Enum.map(events, &%{&1 | at: nil})
  end

  defmodule Simulator do
    @moduledoc false
    @behaviour PropertyDamage.Model.Simulator

    alias PropertyDamage.Next.RetryCheckTest.{Create, Created}

    @impl true
    def simulate(%Create{name: name}, _state), do: [%Created{name: name}]
  end

  defmodule Layers do
    @moduledoc false
    # The retry is a fault: only the adapter's port sees it.
    def retries(%StepSpec{command: Create} = spec),
      do: StepSpec.assign(spec, :retry, Gen.boolean())

    def retries(spec), do: spec
  end

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.RetryCheckTest.{Create, Layers, Projection, Simulator}

    def steps, do: [Create] |> StepSpec.normalize() |> StepSpec.transform(&Layers.retries/1)
    def command_sequence_projection, do: Projection
    def check_projections, do: [Projection]
    def simulator, do: Simulator
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour PropertyDamage.Next.Adapter

    alias PropertyDamage.Next.RetryCheckTest.{Create, Created, Directory, Retried}
    alias PropertyDamage.Next.Runtime

    @impl true
    def setup(config, runtime) do
      {:ok, directory} = Directory.start(config.idempotent?)
      {:ok, %{directory: directory, pd: runtime}}
    end

    @impl true
    def teardown(%{directory: directory}), do: Agent.stop(directory)

    # The catch-all retry clause comes first: it runs the call twice with
    # the retry removed, and returns the first call's events with one that
    # holds both answers.
    @impl true
    def execute(command, %{retry: true} = assigns, context) do
      :ok = Runtime.ack(context.pd, :retry)
      plain = Map.delete(assigns, :retry)
      {:ok, first} = execute(command, plain, context)
      {:ok, again} = execute(command, plain, context)
      {:ok, first ++ [%Retried{first: first, again: again}]}
    end

    def execute(%Create{name: name, key: key}, _assigns, %{directory: directory}) do
      {:ok, id, at} = Directory.create(directory, name, key)
      {:ok, [%Created{id: id, name: name, at: at}]}
    end
  end

  defp run(idempotent?) do
    Next.run(
      model: Model,
      adapter: Adapter,
      config: %{idempotent?: idempotent?},
      seed: 3,
      max_steps: 5,
      max_plans: 50
    )
  end

  test "finds a system whose retry creates a second record, and shrinks to one retried step" do
    assert {:error, %Failure{plan: plan, reason: reason}} = run(false)

    assert inspect(reason) =~ "The retry answered differently from the first call"
    assert [%{command: %Create{}, assigns: %{retry: true}}] = plan.steps
  end

  test "passes a system whose retry answers with the same record, stamped anew" do
    assert {:ok, %Report{} = report} = run(true)

    assert %{Adapter => [%{key: :retry, set: set, acknowledged: acknowledged}]} = report.assigns
    assert set > 0
    assert acknowledged == set
  end
end
