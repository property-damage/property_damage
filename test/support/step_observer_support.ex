defmodule PropertyDamage.Test.StepObserver do
  @moduledoc false
  # Fixtures for the tests that pin what a mock adapter is told during a run:
  # a recording mock, a stand-in adapter that drives the mock's
  # `handle_request/2` through the registry, a small model, and the helpers
  # that start a stepping state and read the record list.
  #
  # The recording mock appends one record per callback to a named Agent:
  #
  #   {:command, name, index}       on_command/2 (index counts the mock's calls)
  #   {:event, name, n}             on_event/2
  #   {:projections, summary}       handle_request/2, with the projections the
  #                                 registry holds when the request arrives
  #   {:teardown, summary}          teardown/1, with the projections the
  #                                 registry holds at teardown
  #
  # Mock config keys (all optional), read in `setup/1` into the mock's state:
  #
  #   :push_on    indexes of the commands whose handle_request/2 pushes an
  #               `Echoed` event
  #   :raise_on   index of the command whose on_command/2 raises
  #   :raise_event  value of the Echoed `n` whose on_event/2 raises

  alias PropertyDamage.Executor.Stepping
  alias PropertyDamage.MockServiceRegistry

  defmodule Recorder do
    @moduledoc false
    # The ordered record list, and the registry pid the adapter saw (so a
    # check can push to it after a step's own flush).
    use Agent

    def start do
      stop()
      Agent.start_link(fn -> %{records: [], registry: nil} end, name: __MODULE__)
    end

    def stop do
      if pid = Process.whereis(__MODULE__) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      :ok
    end

    def record(entry), do: Agent.update(__MODULE__, &%{&1 | records: [entry | &1.records]})
    def records, do: Agent.get(__MODULE__, &Enum.reverse(&1.records))
    def put_registry(pid), do: Agent.update(__MODULE__, &%{&1 | registry: pid})
    def registry, do: Agent.get(__MODULE__, & &1.registry)
  end

  # ==========================================================================
  # Events and commands
  # ==========================================================================

  defmodule Stepped do
    @moduledoc false
    defstruct [:n]
  end

  defmodule Echoed do
    @moduledoc false
    defstruct [:n]
  end

  defmodule First do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Second do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule Counter do
    @moduledoc false
    # The sequence projection: numbers the commands of a generated sequence.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %PropertyDamage.Test.StepObserver.First{}),
      do: %{state | count: state.count + 1}

    def apply(state, %PropertyDamage.Test.StepObserver.Second{}),
      do: %{state | count: state.count + 1}

    def apply(state, _other), do: state
  end

  defmodule Ledger do
    @moduledoc false
    # What the run has folded: the Stepped values and the Echoed values.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{stepped: [], echoed: []}

    @impl true
    def apply(state, %PropertyDamage.Test.StepObserver.Stepped{n: n}),
      do: %{state | stepped: state.stepped ++ [n]}

    def apply(state, %PropertyDamage.Test.StepObserver.Echoed{n: n}),
      do: %{state | echoed: state.echoed ++ [n]}

    def apply(state, _other), do: state
  end

  defmodule LateEcho do
    @moduledoc false
    # Pushes a mock event after the step's own mock flush, as a system does
    # that calls its mock after the command returned. Runs after `Second`.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.StepObserver.{Echoed, Mock, Recorder, Second}

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: Second
    def push_late(_state, %Second{n: n}) do
      :ok =
        PropertyDamage.MockServiceRegistry.push_event(Recorder.registry(), Mock, %Echoed{
          n: {:late, n}
        })
    end
  end

  defmodule FinalEcho do
    @moduledoc false
    # Pushes a mock event while the boundary drain checks a late echo, so the
    # event arrives after the last drain's own mock flush and is folded when
    # the run finalizes.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.StepObserver.{Echoed, Mock, Recorder}

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: Echoed
    def push_final(_state, %Echoed{n: {:late, n}}) do
      :ok =
        PropertyDamage.MockServiceRegistry.push_event(Recorder.registry(), Mock, %Echoed{
          n: {:final, n}
        })
    end

    def push_final(_state, _event), do: true
  end

  defmodule OrderProbe do
    @moduledoc false
    # Keeps the events it folded in order, and records them when the final
    # check runs, so a test can place that check against the mock's callbacks.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.StepObserver.{Echoed, Recorder, Stepped}

    @impl true
    def init, do: %{folded: []}

    @impl true
    def apply(state, %Stepped{n: n}), do: %{state | folded: state.folded ++ [{:stepped, n}]}
    def apply(state, %Echoed{n: n}), do: %{state | folded: state.folded ++ [{:echoed, n}]}
    def apply(state, _other), do: state

    @check at: :teardown
    def final_check(state, _phase) do
      Recorder.record({:final_check, state.folded})
      true
    end
  end

  # ==========================================================================
  # The recording mock
  # ==========================================================================

  defmodule Mock do
    @moduledoc false
    use PropertyDamage.MockServiceAdapter

    alias PropertyDamage.MockServiceRegistry
    alias PropertyDamage.Test.StepObserver.{Echoed, Ledger, Recorder}

    @emits [Echoed]

    @impl true
    def setup(config) do
      registry = config[:registry]
      {:ok, state} = MockServiceRegistry.get_state(registry, __MODULE__)

      state =
        %{
          state
          | push_on: config[:push_on] || [],
            raise_on: config[:raise_on],
            raise_event: config[:raise_event]
        }

      :ok = MockServiceRegistry.update_state(registry, __MODULE__, state)
      {:ok, %{registry: registry}}
    end

    @impl true
    def teardown(%{registry: registry}) do
      {:ok, state} = MockServiceRegistry.get_handler_state(registry, __MODULE__)
      Recorder.record({:teardown, summary(state.projections)})
      :ok
    end

    @impl true
    def init_state, do: %{seen: 0, push_on: [], raise_on: nil, raise_event: nil}

    @impl true
    def on_command(command, state) do
      index = state.seen
      Recorder.record({:command, name(command), index})
      if state.raise_on == index, do: raise("mock refused command #{index}")
      %{state | seen: index + 1}
    end

    @impl true
    def on_event(event, state) do
      Recorder.record({:event, name(event), event.n})
      if state.raise_event == event.n, do: raise("mock refused event #{inspect(event.n)}")
      state
    end

    @impl true
    def handle_request(%{n: n}, state) do
      Recorder.record({:projections, summary(state.projections)})
      events = if n in state.push_on, do: [%Echoed{n: n}], else: []
      {:ok, %{status: 200}, events}
    end

    defp name(%{__struct__: module}), do: module |> Module.split() |> List.last()

    defp summary(projections) do
      case Map.fetch(projections, Ledger) do
        {:ok, ledger} -> ledger
        :error -> :none
      end
    end
  end

  # ==========================================================================
  # The adapter and the model
  # ==========================================================================

  defmodule Adapter do
    @moduledoc false
    # Drives the mock's handle_request/2 through the registry for every
    # command, as the transport of an outbound call does, then answers a
    # Stepped event.
    use PropertyDamage.Adapter

    alias PropertyDamage.MockServiceRegistry
    alias PropertyDamage.Test.StepObserver.{Mock, Recorder, Stepped}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%{n: n}, _ctx, %{mock_registry: registry}) do
      Recorder.put_registry(registry)
      {:ok, state} = MockServiceRegistry.get_handler_state(registry, Mock)
      {:ok, _response, events} = Mock.handle_request(%{n: n}, state)
      :ok = MockServiceRegistry.push_events(registry, Mock, events)
      {:ok, [%Stepped{n: n}]}
    end
  end

  defmodule Model do
    @moduledoc false
    # First, then Second for every later command, numbered by position.
    use PropertyDamage.Model

    alias PropertyDamage.Test.StepObserver.{First, Second}

    @impl true
    def commands do
      [
        {First, when: fn s -> s.count == 0 end, overrides: &number/1},
        {Second, when: fn s -> s.count > 0 end, overrides: &number/1}
      ]
    end

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.StepObserver.Counter

    @impl true
    def check_projections, do: [PropertyDamage.Test.StepObserver.Ledger]

    defp number(state), do: %{n: state.count}
  end

  defmodule LateModel do
    @moduledoc false
    # Model whose last command is followed by a late mock push.
    use PropertyDamage.Model

    @impl true
    defdelegate commands, to: PropertyDamage.Test.StepObserver.Model

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.StepObserver.Counter

    @impl true
    def check_projections do
      [PropertyDamage.Test.StepObserver.Ledger, PropertyDamage.Test.StepObserver.LateEcho]
    end
  end

  defmodule FinalModel do
    @moduledoc false
    # Model whose last command is followed by a late mock push, and whose
    # check of that push pushes once more after the boundary drain.
    use PropertyDamage.Model

    @impl true
    defdelegate commands, to: PropertyDamage.Test.StepObserver.Model

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.StepObserver.Counter

    @impl true
    def check_projections do
      [
        PropertyDamage.Test.StepObserver.Ledger,
        PropertyDamage.Test.StepObserver.LateEcho,
        PropertyDamage.Test.StepObserver.FinalEcho
      ]
    end
  end

  defmodule OrderModel do
    @moduledoc false
    # FinalModel plus the projection that records the final check.
    use PropertyDamage.Model

    alias PropertyDamage.Test.StepObserver.{FinalModel, Model, OrderProbe}

    @impl true
    defdelegate commands, to: Model

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.StepObserver.Counter

    @impl true
    def check_projections, do: FinalModel.check_projections() ++ [OrderProbe]
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  @doc false
  # One unshrunk run of `model` over `count` commands against `targets`.
  def run(model, targets, count, extra \\ []) do
    [
      model: model,
      targets: targets,
      max_runs: 1,
      max_commands: count,
      seed: 4_242,
      validate: false,
      shrink: false,
      replay_dir: false
    ]
    |> Keyword.merge(extra)
    |> PropertyDamage.run()
  end

  @doc false
  # The target of the stand-in adapter with the recording mock registered.
  def target(mock_config \\ %{}),
    do: {Adapter, name: "alice", config: %{}, mocks: [{Mock, mock_config}]}

  @doc false
  # A stepping state over `Model` with a started registry holding one
  # recording mock set up as a run would set it up, plus the stepping
  # context. The one place a test hands the registry to the stepping API.
  def start_stepping_state(mock_config \\ %{}) do
    {:ok, registry} = MockServiceRegistry.start_link([])
    :ok = MockServiceRegistry.register(registry, Mock)
    {:ok, mock_context} = Mock.setup(Map.put(mock_config, :registry, registry))

    state = Stepping.init_state(Model, step_observer: MockServiceRegistry.observer(registry))

    ctx = %Stepping.Context{
      model: Model,
      adapter: Adapter,
      adapter_context: %{}
    }

    {state, ctx, registry, mock_context}
  end
end
