defmodule PropertyDamage.Test.CheckKindMatrix do
  @moduledoc false
  # A small model with one check projection that declares every check form the
  # projection macros emit, each check passing on every run of the model. The
  # check kind matrix test runs every reader of a projection's check metadata
  # over it.
  #
  # `Commands.CreateWidget` and `Commands.UpdateWidget` follow the
  # `Create<Entity>` / `Update<Entity>` naming that maps to `Events.WidgetCreated`
  # and `Events.WidgetUpdated`, so the suggestions analyzer finds their events.

  defmodule Events do
    @moduledoc false

    defmodule WidgetCreated do
      @moduledoc false
      defstruct [:n]
    end

    defmodule WidgetUpdated do
      @moduledoc false
      defstruct [:n]
    end
  end

  defmodule Commands do
    @moduledoc false

    defmodule CreateWidget do
      @moduledoc false
      use PropertyDamage.Command,
        observables: [PropertyDamage.Test.CheckKindMatrix.Events.WidgetCreated]

      defstruct [:n]

      @impl true
      def generator(overrides \\ %{}) do
        %{n: StreamData.integer(1..9)}
        |> PropertyDamage.Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end
    end

    defmodule UpdateWidget do
      @moduledoc false
      use PropertyDamage.Command,
        observables: [PropertyDamage.Test.CheckKindMatrix.Events.WidgetUpdated]

      defstruct [:n]

      @impl true
      def generator(overrides \\ %{}) do
        %{n: StreamData.integer(1..9)}
        |> PropertyDamage.Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end
    end
  end

  defmodule Sequence do
    @moduledoc false
    # The command-sequence projection: counts what the model has simulated.
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.CheckKindMatrix.Events.{WidgetCreated, WidgetUpdated}

    @impl true
    def init, do: %{created: 0, updated: 0}

    @impl true
    def apply(state, %WidgetCreated{}), do: %{state | created: state.created + 1}
    def apply(state, %WidgetUpdated{}), do: %{state | updated: state.updated + 1}
    def apply(state, _other), do: state
  end

  defmodule Checks do
    @moduledoc false
    # Declares every check form. Each check holds on every run: the counters
    # never go negative and the events are counted once.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.CheckKindMatrix.Commands.{CreateWidget, UpdateWidget}
    alias PropertyDamage.Test.CheckKindMatrix.Events.{WidgetCreated, WidgetUpdated}

    @impl true
    def init, do: %{created: 0, updated: 0}

    @impl true
    def apply(state, %WidgetCreated{}), do: %{state | created: state.created + 1}
    def apply(state, %WidgetUpdated{}), do: %{state | updated: state.updated + 1}
    def apply(state, _other), do: state

    defp sane?(state), do: state.created >= 0 and state.updated >= 0

    # every: with a count and with the wildcard targets

    @check every: 1
    def assert_every_step(state, _step), do: sane?(state)

    @check every: 3
    def assert_every_third_step(state, _step), do: sane?(state)

    @check every: :command
    def assert_every_command(state, _step), do: sane?(state)

    @check every: :event
    def assert_every_event(state, _step), do: sane?(state)

    @check every: {2, :command}
    def assert_every_second_command(state, _step), do: sane?(state)

    @check every: {2, :event}
    def assert_every_second_event(state, _step), do: sane?(state)

    # every: with command or event modules

    @check every: CreateWidget
    def assert_after_create(state, _step), do: sane?(state)

    @check every: [CreateWidget, UpdateWidget]
    def assert_after_either(state, _step), do: sane?(state)

    @check every: {2, CreateWidget}
    def assert_every_second_create(state, _step), do: sane?(state)

    @check every: {2, [CreateWidget, UpdateWidget]}
    def assert_every_second_of_either(state, _step), do: sane?(state)

    # lifecycle boundaries

    @check at: :startup
    def assert_clean_start(state, _step), do: state.created == 0 and state.updated == 0

    @check at: :teardown
    def assert_clean_finish(state, _step), do: sane?(state)

    # temporal

    @eventually after: WidgetCreated, timeout: {1, :second}, interval: {10, :milliseconds}
    def assert_widgets_visible(_state, %WidgetCreated{}) do
      fn state -> state.created >= 1 end
    end

    # boundary observations, one per schedule shape

    @compare every: 1
    def compare_every_root(state, _root), do: state.created

    @compare every: 3
    def compare_every_third_root(state, _root), do: state.created

    @compare every: :end
    def compare_at_end(state, _root), do: state.created

    @compare every: CreateWidget
    def compare_after_create(state, _root), do: state.created

    @compare every: [CreateWidget, :end]
    def compare_after_create_and_at_end(state, _root), do: state.created

    @compare every: {2, CreateWidget}
    def compare_every_second_create(state, _root), do: state.created
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.CheckKindMatrix.Commands.{CreateWidget, UpdateWidget}
    alias PropertyDamage.Test.CheckKindMatrix.Events.{WidgetCreated, WidgetUpdated}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%CreateWidget{n: n}, _context, _runtime), do: {:ok, [%WidgetCreated{n: n}]}
    def execute(%UpdateWidget{n: n}, _context, _runtime), do: {:ok, [%WidgetUpdated{n: n}]}
  end

  defmodule Model do
    @moduledoc false
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    alias PropertyDamage.Test.CheckKindMatrix.Commands.{CreateWidget, UpdateWidget}
    alias PropertyDamage.Test.CheckKindMatrix.Events.{WidgetCreated, WidgetUpdated}

    @impl PropertyDamage.Model
    def commands, do: [CreateWidget, UpdateWidget]

    @impl PropertyDamage.Model
    def command_sequence_projection, do: PropertyDamage.Test.CheckKindMatrix.Sequence

    @impl PropertyDamage.Model
    def check_projections, do: [PropertyDamage.Test.CheckKindMatrix.Checks]

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%CreateWidget{n: n}, _state), do: [%WidgetCreated{n: n}]
    def simulate(%UpdateWidget{n: n}, _state), do: [%WidgetUpdated{n: n}]
  end
end
