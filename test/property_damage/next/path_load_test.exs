defmodule PropertyDamage.Next.PathLoadTest do
  # What a model that states paths may declare, checked before anything
  # runs. `@compare every: 1` loads only on a model with `expansions/0`;
  # every other `@compare` form raises on every model. `expansions/0` is a
  # list of `{command module, fun/2}` pairs over the model's own command
  # modules, each module once, and a paths function returns the command
  # alone as its first path. Two lanes and paths do not combine.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Test.Paths
  alias PropertyDamage.Next.Test.Paths.{Pay, PlainModel, SplitModel}
  alias PropertyDamage.Next.Test.Terms

  # --- @compare forms

  defmodule EveryEnd do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @compare every: :end
    def observed(state, _root), do: state
  end

  defmodule EveryTwo do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @compare every: 2
    def observed(state, _root), do: state
  end

  defmodule EveryPay do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @compare every: PropertyDamage.Next.Test.Paths.Pay
    def observed(state, _root), do: state
  end

  defmodule EverySecondPay do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @compare every: {2, PropertyDamage.Next.Test.Paths.Pay}
    def observed(state, _root), do: state
  end

  for {name, projection} <- [
        EndModel: EveryEnd,
        TwoModel: EveryTwo,
        PayModel: EveryPay,
        SecondPayModel: EverySecondPay
      ] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      # The refund model's specs and paths, with one @compare form.
      use PropertyDamage.Next.Model

      alias PropertyDamage.Next.Test.Paths.{Expansions, SplitModel, State}

      @projection projection
      def steps, do: SplitModel.steps()
      def simulator, do: SplitModel.simulator()
      def command_sequence_projection, do: State
      def check_projections, do: [@projection]
      def expansions, do: Expansions.refunds()
    end
  end

  defmodule EveryOneWithoutPaths do
    @moduledoc false
    # @compare every: 1 on a model that states no paths.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.Test.Paths.{SplitModel, State, Totals}

    def steps, do: SplitModel.steps()
    def simulator, do: SplitModel.simulator()
    def command_sequence_projection, do: State
    def check_projections, do: [Totals]
  end

  # --- expansions/0 and paths functions that break the rules

  defmodule Bad do
    @moduledoc false
    # Statements and paths functions that break the rules.
    alias PropertyDamage.Next.Test.Paths.{Expansions, Pay, Peek}

    def statement(:not_a_list), do: :none
    def statement(:not_pairs), do: [Pay]
    def statement(:one_argument), do: [{Pay, &one_argument/1}]
    def statement(:other_module), do: [{Peek, &plain/2}]
    def statement(:twice), do: [{Pay, &plain/2}, {Pay, &plain/2}]
    def statement(:no_paths), do: [{Pay, &no_paths/2}]
    def statement(:other_first), do: [{Pay, &other_first/2}]
    def statement(:longer_first), do: [{Pay, &longer_first/2}]

    def one_argument(pay), do: [[pay]]
    def no_paths(_pay, _state), do: []
    def other_first(%Pay{} = pay, _state), do: [[%{pay | amount: pay.amount + 1}], [pay]]
    def longer_first(%Pay{} = pay, _state), do: [[pay, pay]]
    def plain(pay, state), do: Expansions.pay_paths(pay, state)
  end

  # Each model lists only payments, so every step is a listed one.
  for {name, statement} <- [
        NotAListModel: :not_a_list,
        NotPairsModel: :not_pairs,
        OneArgumentModel: :one_argument,
        OtherModuleModel: :other_module,
        TwiceModel: :twice,
        NoPathsModel: :no_paths,
        OtherFirstModel: :other_first,
        LongerFirstModel: :longer_first
      ] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      use PropertyDamage.Next.Model

      alias PropertyDamage.Next.PathLoadTest.Bad
      alias PropertyDamage.Next.StepSpec
      alias PropertyDamage.Next.Test.Paths.{Pay, Simulator, State}

      @statement statement
      def steps, do: StepSpec.normalize([Pay])
      def simulator, do: Simulator
      def command_sequence_projection, do: State
      def expansions, do: Bad.statement(@statement)
    end
  end

  defmodule PayOnlyModel do
    @moduledoc false
    # The specs of the models above, with no paths: its journals replay on
    # each of them.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Paths.{Pay, Simulator, State}

    def steps, do: StepSpec.normalize([Pay])
    def simulator, do: Simulator
    def command_sequence_projection, do: State
  end

  defp run(model, opts \\ []) do
    [model: model, adapter: Paths.Adapter, seed: 1, max_steps: 4, max_plans: 2, config: %{}]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  defp replay(model, journal, opts \\ []),
    do:
      Next.replay(
        journal,
        Keyword.merge([model: model, adapter: Paths.Adapter, config: %{}], opts)
      )

  defp argument_error(fun) do
    error = Terms.raised(fun)
    assert %ArgumentError{} = error
    Exception.message(error)
  end

  describe "@compare" do
    test "every: 1 loads on a model with expansions/0" do
      assert {:ok, %{plans: 2}} = run(SplitModel)
    end

    test "every: 1 on a model without expansions/0 raises at run/1 and replay/2" do
      journal = Next.plan(PlainModel, 1, max_steps: 4).journal

      for call <- [
            fn -> run(EveryOneWithoutPaths) end,
            fn -> replay(EveryOneWithoutPaths, journal) end
          ] do
        assert argument_error(call) =~ inspect(Paths.Totals)
      end
    end

    for {name, projection} <- [
          EndModel: EveryEnd,
          TwoModel: EveryTwo,
          PayModel: EveryPay,
          SecondPayModel: EverySecondPay
        ] do
      test "#{inspect(projection)}'s form raises at run/1 and replay/2 on a model with expansions/0" do
        model = Module.concat(__MODULE__, unquote(name))
        journal = Next.plan(PlainModel, 1, max_steps: 4).journal

        assert argument_error(fn -> run(model) end) =~ inspect(unquote(projection))
        assert argument_error(fn -> replay(model, journal) end) =~ inspect(unquote(projection))
      end
    end
  end

  describe "expansions/0" do
    for name <- [
          :NotAListModel,
          :NotPairsModel,
          :OneArgumentModel,
          :OtherModuleModel,
          :TwiceModel
        ] do
      test "#{name} raises ArgumentError naming the model when a plan is built" do
        model = Module.concat(__MODULE__, unquote(name))

        assert argument_error(fn -> Next.plan(model, 1, max_steps: 4) end) =~ inspect(model)
      end
    end

    test "a statement that breaks the rules also raises at run/1 and replay/2" do
      model = __MODULE__.TwiceModel
      journal = Next.plan(PayOnlyModel, 1, max_steps: 4).journal

      assert argument_error(fn -> run(model) end) =~ inspect(model)
      assert argument_error(fn -> replay(model, journal) end) =~ inspect(model)
    end
  end

  describe "a paths function" do
    for name <- [:NoPathsModel, :OtherFirstModel, :LongerFirstModel] do
      test "#{name}: a first path other than the command alone raises ArgumentError naming the module" do
        model = Module.concat(__MODULE__, unquote(name))

        assert argument_error(fn -> Next.plan(model, 1, max_steps: 4) end) =~ inspect(Pay)
      end
    end

    test "the first-path rule also guards run/1" do
      assert argument_error(fn -> run(__MODULE__.OtherFirstModel) end) =~ inspect(Pay)
    end
  end

  describe "two lanes with paths" do
    test "raise ArgumentError in plan/3, naming :lanes and expansions/0" do
      message = argument_error(fn -> Next.plan(SplitModel, 1, max_steps: 2, lanes: 2) end)

      assert message =~ ":lanes"
      assert message =~ "expansions/0"
    end

    test "raise ArgumentError in run/1" do
      message = argument_error(fn -> run(SplitModel, max_steps: 2, lanes: 2) end)

      assert message =~ ":lanes"
      assert message =~ "expansions/0"
    end

    test "raise ArgumentError in replay/2 of a journal recorded with two lanes" do
      journal = Next.plan(PlainModel, 1, max_steps: 2, lanes: 2).journal
      assert journal.lanes != nil

      message = argument_error(fn -> replay(SplitModel, journal) end)

      assert message =~ ":lanes"
      assert message =~ "expansions/0"
    end

    test "one lane with paths builds a plan, and two lanes without paths still do" do
      assert %{steps: [_ | _]} = Next.plan(SplitModel, 1, max_steps: 2)
      assert %{steps: [_ | _]} = Next.plan(PlainModel, 1, max_steps: 2, lanes: 2)
    end
  end
end
