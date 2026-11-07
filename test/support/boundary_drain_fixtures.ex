defmodule PropertyDamage.Test.BoundaryDrain do
  @moduledoc false
  # A linear model whose result depends on when an asynchronous event folds.
  #
  # `Spend` commands draw on a credit of 30. After every command step a charge
  # of 10 arrives from outside the command (the check `charge_after_step`
  # pushes it into the run's event queue, as a system that bills a moment
  # after it answers). A run that folds the queue at each root boundary sees
  # the charge before the next command folds; a run that folds it inside the
  # next command's step sees it after that command's own events.
  #
  # `Model` spends 15 per command. Folded at the boundaries, two charges
  # precede the third command (30 - 10 - 10 < 15), so it overdraws there.
  # Folded after the next command, only one charge precedes the third command
  # (30 - 10 >= 15), so the overdraft waits for the fourth. `QuietModel`
  # spends nothing and never overdraws.
  #
  # The charge needs the run's event queue. The injector hands it to the
  # `Box` at setup, so a run whose target declares no injector never charges.

  defmodule Events do
    @moduledoc false

    defmodule Spent do
      @moduledoc false
      defstruct [:amount]
    end

    defmodule Charged do
      @moduledoc false
      defstruct [:seq]
    end
  end

  defmodule Box do
    @moduledoc false
    # The event queue of the run in flight and the count of charges pushed.
    # One named process, so tests that use it run one at a time.
    alias PropertyDamage.EventQueue
    alias PropertyDamage.Test.BoundaryDrain.Events.Charged

    @name __MODULE__

    def start, do: Agent.start_link(fn -> %{queue: nil, pushed: 0} end, name: @name)

    def stop, do: Agent.stop(@name)

    # Back to a run that has no queue and has pushed nothing.
    def reset, do: Agent.update(@name, fn _box -> %{queue: nil, pushed: 0} end)

    def bind(queue), do: Agent.update(@name, &%{&1 | queue: queue})

    # Pushes one charge when a queue is bound; a run without the injector has
    # none, so nothing arrives.
    def charge do
      Agent.get_and_update(@name, fn
        %{queue: nil} = box ->
          {:ok, box}

        %{queue: queue, pushed: pushed} = box ->
          EventQueue.push(queue, __MODULE__, %Charged{seq: pushed})
          {:ok, %{box | pushed: pushed + 1}}
      end)
    end
  end

  defmodule Commands do
    @moduledoc false

    defmodule Spend do
      @moduledoc false
      use PropertyDamage.Command
      defstruct [:amount]

      @impl true
      def generator(overrides \\ %{}) do
        %{amount: StreamData.constant(15)}
        |> PropertyDamage.Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end
    end

    defmodule SpendNone do
      @moduledoc false
      use PropertyDamage.Command
      defstruct [:amount]

      @impl true
      def generator(overrides \\ %{}) do
        %{amount: StreamData.constant(0)}
        |> PropertyDamage.Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end
    end
  end

  defmodule Sequence do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{spent: 0}

    @impl true
    def apply(state, %Events.Spent{amount: amount}), do: %{state | spent: state.spent + amount}
    def apply(state, _other), do: state
  end

  defmodule Checks do
    @moduledoc false
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.BoundaryDrain.{Box, Events}

    @impl true
    def init, do: %{credit: 30, overdrawn: false}

    @impl true
    def apply(state, %Events.Spent{amount: amount}) do
      if amount > state.credit, do: %{state | overdrawn: true}, else: state
    end

    def apply(state, %Events.Charged{}), do: %{state | credit: state.credit - 10}
    def apply(state, _other), do: state

    @check every: :command
    def assert_not_overdrawn(state, _command), do: not state.overdrawn

    # Models the system billing just after a command's step ends: a charge
    # reaches the event queue once the step's own events are folded.
    @check every: :command
    def charge_after_step(_state, _command) do
      Box.charge()
      true
    end
  end

  defmodule Injector do
    @moduledoc false
    use PropertyDamage.Adapter.Injector

    alias PropertyDamage.Test.BoundaryDrain.{Box, Events}

    @emits [Events.Charged]

    @impl true
    def setup(%{event_queue: queue}) do
      Box.bind(queue)
      {:ok, %{}}
    end

    @impl true
    def teardown(_context) do
      Box.bind(nil)
      :ok
    end

    @impl true
    def to_event(_payload), do: :skip
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.BoundaryDrain.{Commands, Events}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Commands.Spend{amount: amount}, _context, _runtime),
      do: {:ok, [%Events.Spent{amount: amount}]}

    def execute(%Commands.SpendNone{amount: amount}, _context, _runtime),
      do: {:ok, [%Events.Spent{amount: amount}]}
  end

  defmodule Model do
    @moduledoc false
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    alias PropertyDamage.Test.BoundaryDrain.{Commands, Events}

    @impl PropertyDamage.Model
    def commands, do: [Commands.Spend]

    @impl PropertyDamage.Model
    def command_sequence_projection, do: PropertyDamage.Test.BoundaryDrain.Sequence

    @impl PropertyDamage.Model
    def check_projections, do: [PropertyDamage.Test.BoundaryDrain.Checks]

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Commands.Spend{amount: amount}, _state), do: [%Events.Spent{amount: amount}]
  end

  defmodule QuietModel do
    @moduledoc false
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    alias PropertyDamage.Test.BoundaryDrain.{Commands, Events}

    @impl PropertyDamage.Model
    def commands, do: [Commands.SpendNone]

    @impl PropertyDamage.Model
    def command_sequence_projection, do: PropertyDamage.Test.BoundaryDrain.Sequence

    @impl PropertyDamage.Model
    def check_projections, do: [PropertyDamage.Test.BoundaryDrain.Checks]

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Commands.SpendNone{amount: amount}, _state),
      do: [%Events.Spent{amount: amount}]
  end
end
