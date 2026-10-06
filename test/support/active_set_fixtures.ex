defmodule PropertyDamage.Test.ActiveSet do
  @moduledoc false
  # Fixtures for adapter errors at a root and the set of variants still
  # running. Every command is a `Book` numbered by its root index, and each
  # adapter fails on that number, so a failure stays with its command when a
  # sequence is shrunk.
  #
  # Adapters, checks and observations append to a shared recorder
  # (`PropertyDamage.Test.VariantSupport.start_recorder/0`):
  #
  #   {:setup, name}            setup/1 ran
  #   {:executed, name, n}      execute/3 ran for the command numbered n
  #   {:teardown, name}         teardown/1 ran
  #   {:teardown_check, name}   Watch's :teardown check ran
  #   {:compared, name, n}      an observation built with `observed/2` ran

  alias PropertyDamage.Generator
  alias PropertyDamage.Test.VariantSupport

  defmodule Booked do
    @moduledoc false
    # `sink` is the recorder and `fail_teardown` the adapter's setting, so a
    # projection can report and fail without knowing the test.
    defstruct [:n, :by, :sink, fail_teardown: false]
  end

  defmodule Book do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.constant(0)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Seq do
    @moduledoc false
    # The sequence projection: numbers the commands.
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %Book{}), do: %{state | count: state.count + 1}
    def apply(state, _other), do: state
  end

  defmodule Watch do
    @moduledoc false
    # Records its :teardown check, and fails it when the adapter asked for that.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{by: nil, sink: nil, fail_teardown: false}

    @impl true
    def apply(state, %Booked{by: by, sink: sink, fail_teardown: fail}),
      do: %{state | by: by, sink: sink, fail_teardown: fail}

    def apply(state, _other), do: state

    @check at: :teardown
    def assert_torn_down_cleanly(state, _phase) do
      VariantSupport.record(state.sink, {:teardown_check, state.by})

      if state.fail_teardown do
        PropertyDamage.fail!("teardown check failed", variant: state.by)
      end

      :ok
    end
  end

  defmodule BookAdapter do
    @moduledoc false
    # Config keys:
    #
    #   :name           target name (also Booked.by)
    #   :recorder       the shared recorder
    #   :fail           %{n => :error | :raise}: fail the command numbered n
    #   :fail_after     %{n => m}: answer {:error, _} to n only when m was
    #                   executed earlier in this run
    #   :fail_unless    %{n => m}: answer {:error, _} to n only when m was NOT
    #                   executed earlier in this run
    #   :fail_teardown  Watch's :teardown check fails in this variant
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.ActiveSet.{Book, Booked}
    alias PropertyDamage.Test.VariantSupport

    @impl true
    def setup(config) do
      VariantSupport.record(config[:recorder], {:setup, config.name})
      # One flag per command number executed in this run.
      {:ok, Map.put(config, :seen, :atomics.new(64, []))}
    end

    @impl true
    def teardown(ctx) do
      VariantSupport.record(ctx[:recorder], {:teardown, ctx.name})
      :ok
    end

    @impl true
    def execute(%Book{n: n}, ctx, _runtime) do
      VariantSupport.record(ctx[:recorder], {:executed, ctx.name, n})
      outcome = outcome(ctx, n)
      :atomics.put(ctx.seen, n + 1, 1)

      case outcome do
        :ok ->
          {:ok,
           [
             %Booked{
               n: n,
               by: ctx.name,
               sink: ctx[:recorder],
               fail_teardown: Map.get(ctx, :fail_teardown, false)
             }
           ]}

        :error ->
          {:error, {:refused, n}}

        :raise ->
          raise "book #{n} exploded"
      end
    end

    defp outcome(ctx, n) do
      cond do
        mode = Map.get(Map.get(ctx, :fail, %{}), n) ->
          mode

        m = Map.get(Map.get(ctx, :fail_after, %{}), n) ->
          if seen?(ctx, m), do: :error, else: :ok

        m = Map.get(Map.get(ctx, :fail_unless, %{}), n) ->
          if seen?(ctx, m), do: :ok, else: :error

        true ->
          :ok
      end
    end

    defp seen?(ctx, m), do: :atomics.get(ctx.seen, m + 1) == 1
  end

  @doc false
  def commands, do: [{Book, overrides: &number/1}]

  defp number(state), do: %{n: state.count}

  @doc false
  # Records `{:compared, by, root.n}` and returns `value`; for use inside an
  # observation, given the Watch-shaped state.
  def observed(%{by: by, sink: sink}, %Book{n: n}, value) do
    VariantSupport.record(sink, {:compared, by, n})
    value
  end

  @doc false
  # Defines a model: Book commands, Seq as the sequence projection,
  # `projections` as check projections.
  def define_model!(module, projections) do
    support = __MODULE__

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          @moduledoc false
          @behaviour PropertyDamage.Model

          @impl true
          def commands, do: unquote(support).commands()

          @impl true
          def command_sequence_projection, do: unquote(Seq)

          @impl true
          def check_projections, do: unquote(projections)
        end
      end
    )

    module
  end

  @doc false
  def target(name, recorder, config \\ %{}) do
    {BookAdapter, name: name, config: Map.merge(%{name: name, recorder: recorder}, config)}
  end

  @doc false
  # The recorder entries of the first run only (each run starts with the
  # reference's setup).
  def first_run(recorder) do
    [first | rest] = VariantSupport.recorded(recorder)
    [first | Enum.take_while(rest, &(&1 != first))]
  end

  @doc false
  def executed(entries, name), do: for({:executed, ^name, n} <- entries, do: n)

  @doc false
  def compared(entries, name), do: for({:compared, ^name, n} <- entries, do: n)

  @doc false
  # The position of the first entry matching `match?`, or nil.
  def position(entries, match?), do: Enum.find_index(entries, match?)
end
