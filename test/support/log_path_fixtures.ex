defmodule PropertyDamage.Test.LogPathFixtures do
  @moduledoc false
  # Fixtures for the paths a log line takes outside a command's `execute/3`
  # (DR-054): a process that the adapter's `setup/1` leaves running, an
  # injector around a failing adapter setup, a nemesis whose fault outlives
  # a failing run, and a mock notified of commands and events. They build on
  # `PropertyDamage.Test.LogFixtures`, whose events, commands and checks they
  # reuse.

  alias PropertyDamage.MockServiceRegistry
  alias PropertyDamage.Test.LogFixtures, as: F

  defmodule SetupTaskAdapter do
    @moduledoc false
    # setup/1 starts a long-lived poller that logs on request and reports to
    # `:test_pid` whether the call raised; execute/3 asks it to log during
    # each step, teardown/1 asks it once more. setup/1 and teardown/1 also
    # each start a Task that logs while they run.
    use PropertyDamage.Adapter
    require PropertyDamage

    alias PropertyDamage.Test.LogFixtures, as: F

    @impl true
    def setup(config) do
      {:ok, poller} = Task.start(fn -> loop() end)
      PropertyDamage.log("setup by alice")
      Task.async(fn -> PropertyDamage.log("task started by setup") end) |> Task.await()
      {:ok, Map.merge(config, %{name: "alice", poller: poller})}
    end

    @impl true
    def execute(%F.Act{n: n} = command, ctx, _runtime) do
      send(ctx.test_pid, {:poller, {:step, n}, poll(ctx.poller, "poll during step #{n}")})
      F.answer(command, ctx)
    end

    @impl true
    def teardown(ctx) do
      PropertyDamage.log("teardown by alice")
      Task.async(fn -> PropertyDamage.log("task started by teardown") end) |> Task.await()
      send(ctx.test_pid, {:poller, :teardown, poll(ctx.poller, "poll from the setup task")})
      send(ctx.poller, :stop)
      :ok
    end

    defp poll(poller, message) do
      send(poller, {:log, self(), message})

      receive do
        {:polled, outcome} -> outcome
      end
    end

    defp loop do
      receive do
        {:log, from, message} ->
          send(from, {:polled, attempt(message)})
          loop()

        :stop ->
          :ok
      end
    end

    defp attempt(message) do
      PropertyDamage.log(message)
      :logged
    rescue
      PropertyDamage.Log.NoScopeError -> :no_scope
    end
  end

  defmodule LoggingInjector do
    @moduledoc false
    # An injector that logs in setup/1 and teardown/1 and emits nothing.
    use PropertyDamage.Adapter.Injector
    require PropertyDamage

    @emits []

    @impl true
    def setup(_config) do
      PropertyDamage.log("injector setup by alice")
      {:ok, %{}}
    end

    @impl true
    def teardown(_context) do
      PropertyDamage.log("injector teardown by alice")
      :ok
    end

    @impl true
    def to_event(_payload), do: :skip
  end

  defmodule RefusingInjector do
    @moduledoc false
    # An injector whose setup/1 logs, then refuses to start.
    use PropertyDamage.Adapter.Injector
    require PropertyDamage

    @emits []

    @impl true
    def setup(_config) do
      PropertyDamage.log("refusing injector setup")
      {:error, :injector_down}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def to_event(_payload), do: :skip
  end

  defmodule RaisingSetupAdapter do
    @moduledoc false
    # An adapter whose setup/1 logs, then raises.
    use PropertyDamage.Adapter
    require PropertyDamage

    alias PropertyDamage.Test.LogFixtures, as: F

    @impl true
    def setup(_config) do
      PropertyDamage.log("setup about to raise")
      raise "setup refused"
    end

    @impl true
    def execute(command, ctx, _runtime), do: F.answer(command, ctx)

    @impl true
    def teardown(_ctx), do: :ok
  end

  defmodule Fault do
    @moduledoc false
    # An auto-restoring nemesis that logs in inject/2 and restore/2; its
    # `duration_ms` decides whether a later sweep or the end of the run
    # lifts it.
    @behaviour PropertyDamage.Nemesis
    require PropertyDamage

    defstruct [:tag, duration_ms: 0]

    @impl true
    def precondition(_state), do: true

    @impl true
    def new!(_state, overrides) do
      StreamData.constant(%__MODULE__{
        tag: Map.get(overrides, :tag, :short),
        duration_ms: Map.get(overrides, :duration_ms, 0)
      })
    end

    @impl true
    def inject(%__MODULE__{tag: tag}, _ctx) do
      PropertyDamage.log("inject #{tag}")
      {:ok, []}
    end

    @impl true
    def restore(%__MODULE__{tag: tag}, _ctx) do
      PropertyDamage.log("restore #{tag}")
      {:ok, []}
    end

    @impl true
    def auto_restore?, do: true

    @impl true
    def duration_ms(%__MODULE__{duration_ms: duration}), do: duration
  end

  defmodule FaultCounter do
    @moduledoc false
    # Numbers the roots: two faults first, then Acts.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(s, %PropertyDamage.Test.LogFixtures.Act{}), do: %{s | count: s.count + 1}
    def apply(s, %PropertyDamage.Test.LogPathFixtures.Fault{}), do: %{s | count: s.count + 1}
    def apply(s, _other), do: s
  end

  defmodule FaultModel do
    @moduledoc false
    # Root 0 injects a fault the next sweep lifts, root 1 one only the end of
    # the run lifts, every later root is an Act checked by Guard.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.LogFixtures.Act
    alias PropertyDamage.Test.LogPathFixtures.Fault

    @impl true
    def commands do
      [
        {Fault, when: &(&1.count == 0), overrides: fn _ -> %{tag: :short, duration_ms: 0} end},
        {Fault,
         when: &(&1.count == 1), overrides: fn _ -> %{tag: :long, duration_ms: 600_000} end},
        {Act, when: &(&1.count >= 2), overrides: &%{n: &1.count - 2}}
      ]
    end

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.LogPathFixtures.FaultCounter

    @impl true
    def check_projections, do: [PropertyDamage.Test.LogFixtures.Guard]
  end

  defmodule NotifiedMock do
    @moduledoc false
    # A mock that logs when it is told of a command and of an event.
    use PropertyDamage.MockServiceAdapter
    require PropertyDamage

    @emits []

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def init_state, do: %{}

    @impl true
    def on_command(%{n: n}, state) do
      PropertyDamage.log("mock saw act #{n}")
      state
    end

    @impl true
    def on_event(%{note: note}, state) do
      PropertyDamage.log("mock saw #{note}")
      state
    end

    def on_event(_event, state), do: state

    @impl true
    def handle_request(_request, state), do: {:ok, %{status: 200}, state}
  end

  defmodule MockPushingAdapter do
    @moduledoc false
    # Answers each Act after pushing an Injected event through the mock, so
    # the engine tells the mock of that event after the step.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.LogFixtures, as: F

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def execute(%F.Act{n: n} = command, ctx, runtime) do
      event = %F.Injected{n: n, by: ctx.name, note: "pushed #{n}"}
      :ok = MockServiceRegistry.push_events(runtime.mock_registry, NotifiedMock, [event])
      F.answer(command, ctx)
    end

    @impl true
    def teardown(_ctx), do: :ok
  end

  @doc false
  # A target of the logging adapter with `LoggingInjector` around it.
  def injected_target(name, config) do
    {F.log_adapter(),
     name: name, config: Map.merge(%{name: name}, config), injectors: [LoggingInjector]}
  end

  @doc false
  # A target of `adapter` named alice with `injectors` around it.
  def serviced_target(adapter, injectors, config \\ %{}) do
    {adapter, name: "alice", config: Map.merge(%{name: "alice"}, config), injectors: injectors}
  end

  @doc false
  # A target of `MockPushingAdapter` with `NotifiedMock` registered.
  def mocked_target(name, config) do
    {MockPushingAdapter,
     name: name, config: Map.merge(%{name: name}, config), mocks: [{NotifiedMock, %{}}]}
  end

  @doc false
  # The messages printed in `block`'s log lines.
  def log_messages(block), do: block |> F.logs() |> Enum.map(& &1.message)
end
