defmodule PropertyDamage.Test.SetupCommands do
  @moduledoc false
  # Fixtures for setup commands and teardown commands: a model's
  # `setup_each/0` and `teardown_each/0` sequences, run before and after the
  # roots of every run in every target.
  #
  # `FixtureAdapter` appends to a shared recorder
  # (`PropertyDamage.Test.VariantSupport.start_recorder/0`):
  #
  #   {:setup, name}               setup/1 ran
  #   {:execute, name, command}    execute/3 ran with the resolved command
  #   {:teardown, name}            teardown/1 ran
  #
  # and the fixture projections add:
  #
  #   {:teardown_check, name}      Fixture's :teardown check ran
  #   {:compared, name, n}         Fixture's @compare observation ran at root n
  #   {:every3, ticks}             EveryThird's `every: 3` check fired
  #
  # Models are defined at runtime by `define_model!/2`; their callback lists
  # are kept in `:persistent_term`, so a spec may hold functions.

  alias PropertyDamage.Generator
  alias PropertyDamage.Test.VariantSupport

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule UserCreated do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:name, :by, :sink, id: external()]
  end

  defmodule LoggedIn do
    @moduledoc false
    defstruct [:user_id, :by, :sink]
  end

  defmodule Acted do
    @moduledoc false
    defstruct [:n, :user_id, :by, :sink, mode: :plain]
  end

  defmodule ThingMade do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:by, :sink, id: external()]
  end

  defmodule Noted do
    @moduledoc false
    defstruct [:thing_id, :by]
  end

  # ==========================================================================
  # Commands
  # ==========================================================================

  defmodule CreateUser do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:name]

    @impl true
    def generator(overrides \\ %{}) do
      %{name: StreamData.string(:alphanumeric, min_length: 1, max_length: 8)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Login do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:user_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{user_id: StreamData.constant(nil)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Act do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n, :user_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0), user_id: StreamData.constant(nil)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Other do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:v]

    @impl true
    def generator(overrides \\ %{}) do
      %{v: StreamData.integer(0..1_000_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Tick do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule MakeThing do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Cleanup do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:thing_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{thing_id: StreamData.constant(nil)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule World do
    @moduledoc false
    # The sequence projection: the fixture user, the things made and the
    # number of Act roots folded.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{user: nil, logged_in: false, things: [], acts: 0, ticks: 0}

    @impl true
    def apply(state, %UserCreated{id: id}), do: %{state | user: id}
    def apply(state, %LoggedIn{}), do: %{state | logged_in: true}
    def apply(state, %ThingMade{id: id}), do: %{state | things: state.things ++ [id]}
    def apply(state, %Act{}), do: %{state | acts: state.acts + 1}
    def apply(state, %Tick{}), do: %{state | ticks: state.ticks + 1}
    def apply(state, _other), do: state
  end

  defmodule Fixture do
    @moduledoc false
    # Learns the target name and recorder from the events, compares the Act
    # count across targets at every root and records its :teardown check.
    # Teardown events (`Noted`) must never reach it: folding one raises.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{by: nil, sink: nil, acts: 0, mode: :plain}

    @impl true
    def apply(_state, %Noted{}), do: raise("a teardown event was folded")

    def apply(state, %Acted{by: by, sink: sink, mode: mode}),
      do: %{state | by: by, sink: sink, acts: state.acts + 1, mode: mode}

    def apply(state, %{by: by, sink: sink}) when not is_nil(by),
      do: %{state | by: by, sink: sink}

    def apply(state, _other), do: state

    @compare every: 1
    def acts(state, root) do
      VariantSupport.record(state.sink, {:compared, state.by, root_number(root)})

      case state.mode do
        :pending -> {:pending, :waiting}
        :shift -> state.acts + 100
        _ -> state.acts
      end
    end

    @check at: :teardown
    def assert_teardown(state, _phase) do
      VariantSupport.record(state.sink, {:teardown_check, state.by})
      :ok
    end

    @check every: PropertyDamage.Test.SetupCommands.Noted
    def assert_no_teardown_event(_state, _event) do
      PropertyDamage.fail!("a teardown event was checked")
    end

    defp root_number(%Act{n: n}), do: n
    defp root_number(_root), do: nil
  end

  defmodule LoginCheck do
    @moduledoc false
    # Fails on every Login command.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _other), do: state

    @check every: PropertyDamage.Test.SetupCommands.Login
    def assert_login_allowed(_state, _login) do
      PropertyDamage.fail!("login is not allowed")
    end
  end

  defmodule LoginCompare do
    @moduledoc false
    # A boundary observation scheduled at Login only.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{logins: 0}

    @impl true
    def apply(state, %LoggedIn{}), do: %{state | logins: state.logins + 1}
    def apply(state, _other), do: state

    @compare every: PropertyDamage.Test.SetupCommands.Login
    def logins(state, _root), do: state.logins
  end

  defmodule EveryThird do
    @moduledoc false
    # Records the Tick count each time its `every: 3` check fires.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{ticks: 0, sink: nil}

    @impl true
    def apply(state, %Tick{}), do: %{state | ticks: state.ticks + 1}
    def apply(state, %UserCreated{sink: sink}), do: %{state | sink: sink}
    def apply(state, _other), do: state

    @check every: 3
    def assert_sampled(state, _item) do
      send(:persistent_term.get({PropertyDamage.Test.SetupCommands, :every3}), {
        :every3,
        state.ticks
      })

      :ok
    end
  end

  # ==========================================================================
  # Adapter
  # ==========================================================================

  defmodule FixtureAdapter do
    @moduledoc false
    # Config keys:
    #
    #   :name          target name
    #   :recorder      the shared recorder
    #   :fail_setup    setup/1 answers {:error, :no_backend}
    #   :fail          %{command_module => :error | :raise}
    #   :drop_id       CreateUser answers a UserCreated without its id
    #   :no_event      CreateUser answers no event
    #   :mode          Acted's mode (:plain | :shift | :pending)
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.SetupCommands.{
      Act,
      Acted,
      Cleanup,
      CreateUser,
      LoggedIn,
      Login,
      MakeThing,
      Noted,
      Other,
      ThingMade,
      Tick,
      UserCreated
    }

    @impl true
    def setup(config) do
      VariantSupport.record(config[:recorder], {:setup, config.name})

      if config[:fail_setup] do
        {:error, :no_backend}
      else
        {:ok, Map.put(config, :counter, :counters.new(1, []))}
      end
    end

    @impl true
    def teardown(ctx) do
      VariantSupport.record(ctx[:recorder], {:teardown, ctx.name})
      :ok
    end

    @impl true
    def execute(command, ctx, _runtime) do
      VariantSupport.record(ctx[:recorder], {:execute, ctx.name, command})

      case Map.get(Map.get(ctx, :fail, %{}), command.__struct__) do
        :error -> {:error, {:refused, command.__struct__}}
        :raise -> raise "#{inspect(command.__struct__)} exploded"
        nil -> {:ok, answer(command, ctx)}
      end
    end

    defp answer(%CreateUser{name: name}, ctx) do
      cond do
        ctx[:no_event] -> []
        ctx[:drop_id] -> [%UserCreated{name: name, id: nil, by: ctx.name, sink: ctx[:recorder]}]
        true -> [%UserCreated{name: name, id: mint(ctx, "u"), by: ctx.name, sink: ctx[:recorder]}]
      end
    end

    defp answer(%Login{user_id: user_id}, ctx),
      do: [%LoggedIn{user_id: user_id, by: ctx.name, sink: ctx[:recorder]}]

    defp answer(%Act{n: n, user_id: user_id}, ctx) do
      [
        %Acted{
          n: n,
          user_id: user_id,
          by: ctx.name,
          sink: ctx[:recorder],
          mode: Map.get(ctx, :mode, :plain)
        }
      ]
    end

    defp answer(%MakeThing{}, ctx),
      do: [%ThingMade{id: mint(ctx, "t"), by: ctx.name, sink: ctx[:recorder]}]

    defp answer(%Cleanup{thing_id: thing_id}, ctx), do: [%Noted{thing_id: thing_id, by: ctx.name}]
    defp answer(%Other{}, _ctx), do: []
    defp answer(%Tick{}, _ctx), do: []

    # A value unique to this target and run: the target name and a counter.
    defp mint(ctx, kind) do
      :counters.add(ctx.counter, 1, 1)
      "#{ctx.name}-#{kind}#{:counters.get(ctx.counter, 1)}"
    end
  end

  # ==========================================================================
  # Models
  # ==========================================================================

  @doc false
  # The usual setup commands: a fixture user, then a login as that user.
  def standard_setup do
    [
      {CreateUser, overrides: %{name: "fixture"}},
      {Login, overrides: fn state -> %{user_id: state.user} end}
    ]
  end

  @doc false
  # Act roots that need the fixture user.
  def act_roots do
    [{Act, when: fn state -> state.user != nil end, overrides: &act_overrides/1}]
  end

  defp act_overrides(state), do: %{n: state.acts, user_id: state.user}

  @doc false
  # Defines `module` as a model. Options (all optional):
  #
  #   :commands     commands/0 (default `act_roots/0`)
  #   :setup        setup_each/0; `nil` defines no callback (default nil)
  #   :teardown     teardown_each/0; `nil` defines no callback (default nil)
  #   :checks       check_projections/0 (default `[Fixture]`)
  #   :simulate     the simulator; `:default` answers like FixtureAdapter
  #   :terminate    `true` defines terminate_early?/3, which sends
  #                 `{:terminate_early, command}` to the generating process
  def define_model!(module, opts \\ []) do
    :persistent_term.put({__MODULE__, module}, %{
      commands: Keyword.get(opts, :commands, act_roots()),
      setup: Keyword.get(opts, :setup),
      teardown: Keyword.get(opts, :teardown),
      checks: Keyword.get(opts, :checks, [Fixture])
    })

    support = __MODULE__
    setup? = Keyword.get(opts, :setup) != nil
    teardown? = Keyword.get(opts, :teardown) != nil
    terminate? = Keyword.get(opts, :terminate, false)

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          @moduledoc false
          @behaviour PropertyDamage.Model

          @impl true
          def commands, do: unquote(support).spec(unquote(module), :commands)

          @impl true
          def command_sequence_projection, do: unquote(World)

          @impl true
          def check_projections, do: unquote(support).spec(unquote(module), :checks)

          @impl true
          def simulator, do: unquote(support)

          if unquote(setup?) do
            @impl true
            def setup_each, do: unquote(support).spec(unquote(module), :setup)
          end

          if unquote(teardown?) do
            @impl true
            def teardown_each, do: unquote(support).spec(unquote(module), :teardown)
          end

          if unquote(terminate?) do
            @impl true
            def terminate_early?(_state, command, _events) do
              send(self(), {:terminate_early, command})
              false
            end
          end
        end
      end
    )

    module
  end

  @doc false
  def spec(module, key), do: :persistent_term.get({__MODULE__, module})[key]

  # The simulator every fixture model shares.
  @doc false
  def simulate(%CreateUser{name: name}, _state), do: [%UserCreated{name: name}]
  def simulate(%Login{user_id: user_id}, _state), do: [%LoggedIn{user_id: user_id}]
  def simulate(%Act{n: n, user_id: user_id}, _state), do: [%Acted{n: n, user_id: user_id}]
  def simulate(%MakeThing{}, _state), do: [%ThingMade{}]
  def simulate(%Cleanup{thing_id: thing_id}, _state), do: [%Noted{thing_id: thing_id}]
  def simulate(_command, _state), do: []

  @doc false
  def target(name, recorder, config \\ %{}) do
    {FixtureAdapter, name: name, config: Map.merge(%{name: name, recorder: recorder}, config)}
  end

  @doc false
  # The commands `name` executed, in order.
  def executed(entries, name), do: for({:execute, ^name, command} <- entries, do: command)

  @doc false
  # The recorder entries of one target, in order.
  def of(entries, name) do
    Enum.filter(entries, fn entry -> tuple_size(entry) >= 2 and elem(entry, 1) == name end)
  end

  @doc false
  # The position of the first entry matching `match?`, or nil.
  def position(entries, match?), do: Enum.find_index(entries, match?)
end
