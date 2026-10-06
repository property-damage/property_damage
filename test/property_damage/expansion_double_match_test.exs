defmodule PropertyDamage.ExpansionDoubleMatchTest.Fixture do
  @moduledoc false
  # A root `OpenTwo` whose simulation produces two `Opened{id: external()}`
  # events, and a root `OpenOne` that produces one. Each is listed with one
  # rewrite, `[ReserveOne, ConfirmTwo]`, where `ConfirmTwo` produces two
  # `Opened` events: one leaf holds two placeholders that match each of the
  # root's placeholders by event module and field path.

  alias PropertyDamage.Generator
  alias PropertyDamage.Test.VariantSupport

  defmodule Opened do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Reserved do
    @moduledoc false
    defstruct []
  end

  for name <- [OpenTwo, OpenOne, ReserveOne, ConfirmTwo] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      use PropertyDamage.Command
      defstruct []

      @impl true
      def generator(overrides \\ %{}),
        do: %{} |> Generator.merge_overrides(overrides) |> StreamData.fixed_map()
    end
  end

  alias __MODULE__.{ConfirmTwo, OpenOne, OpenTwo, ReserveOne}

  defmodule World do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection
    def init, do: %{opened: 0}
    def apply(state, %Opened{}), do: %{state | opened: state.opened + 1}
    def apply(state, _event), do: state
  end

  defmodule Ledger do
    @moduledoc false
    use PropertyDamage.Model.Projection
    def init, do: %{opened: 0}
    def apply(state, %Opened{}), do: %{state | opened: state.opened + 1}
    def apply(state, _event), do: state

    @compare every: 1
    def totals(state, _root), do: state
  end

  # A model whose one command is `root`, rewritten to `[ReserveOne, ConfirmTwo]`.
  def define_model!(module, root) do
    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          @moduledoc false
          @behaviour PropertyDamage.Model
          def commands, do: [unquote(root)]

          def expansions,
            do: [
              {unquote(root),
               fn _root, _state -> [[unquote(ReserveOne), unquote(ConfirmTwo)]] end}
            ]

          def command_sequence_projection, do: unquote(World)
          def check_projections, do: [unquote(Ledger)]
          def simulator, do: unquote(__MODULE__)
        end
      end
    )

    module
  end

  def simulate(%OpenTwo{}, _state), do: [%Opened{}, %Opened{}]
  def simulate(%OpenOne{}, _state), do: [%Opened{}]
  def simulate(%ConfirmTwo{}, _state), do: [%Opened{}, %Opened{}]
  def simulate(%ReserveOne{}, _state), do: [%Reserved{}]

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.ExpansionDoubleMatchTest.Fixture

    @impl true
    def setup(config) do
      VariantSupport.record(config.recorder, {:setup, config.name})
      {:ok, config}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Fixture.ReserveOne{}, _ctx, _runtime), do: {:ok, [%Reserved{}]}
    def execute(_command, ctx, _runtime), do: {:ok, [%Opened{id: "#{ctx.name}-1"}]}
  end
end

defmodule PropertyDamage.ExpansionDoubleMatchTest do
  # A root placeholder aliases to the one leaf placeholder with the same event
  # module and field path. Two matching placeholders minted by one leaf (two
  # matching events of that leaf) are two candidates: generation fails before
  # any target is set up, naming the root, the entry, the field and each
  # candidate with its leaf index.
  use ExUnit.Case, async: false

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  alias PropertyDamage.ExpansionDoubleMatchTest.Fixture
  alias PropertyDamage.ExpansionDoubleMatchTest.Fixture.{Adapter, OpenOne, OpenTwo}

  defp generation_error(model) do
    recorder = start_recorder()
    target = {Adapter, [name: "solo", config: %{name: "solo", recorder: recorder}]}

    error =
      assert_raise ArgumentError, fn ->
        PropertyDamage.run(
          model: model,
          targets: [target],
          seed: 1,
          max_runs: 1,
          max_commands: 2,
          shrink: false,
          validate: false
        )
      end

    assert recorded(recorder) == [], "a target was set up before the generation error"
    error.message
  end

  test "two matching events of one leaf are two candidates for each root placeholder" do
    message = generation_error(Fixture.define_model!(DoubleMatch.TwoRootEvents, OpenTwo))

    assert message =~ "OpenTwo[0]"
    assert message =~ "root 0"
    assert message =~ "[:id]"
    assert message =~ "several"
    assert message =~ ~r/leaf 1 \(ConfirmTwo\)[^,]*event 0/
    assert message =~ ~r/leaf 1 \(ConfirmTwo\)[^,]*event 1/
  end

  test "a root with one matching event still fails when one leaf mints two matches" do
    message = generation_error(Fixture.define_model!(DoubleMatch.OneRootEvent, OpenOne))

    assert message =~ "OpenOne[0]"
    assert message =~ "[:id]"
    assert message =~ "several"
    assert message =~ "ConfirmTwo"
  end
end
