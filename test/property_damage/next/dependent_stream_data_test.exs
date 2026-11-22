defmodule PropertyDamage.Next.DependentStreamDataTest do
  # A dependent field (from/2) or a dependent assign
  # (StepSpec.assign_from_command/3) may return a StreamData generator. PD's
  # own engine draws it, warns once per site in each call of run/1, plan/3 or
  # replay/2, and lists the site as kept. With `dependent_stream_data: :raise`
  # it raises instead. An engine that can fit such a value does neither.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import PropertyDamage.Next.Test.OwnLog, only: [with_own_log: 1]

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Journal, Model, StepSpec}
  alias PropertyDamage.Next.Test.Fixtures, as: F
  alias PropertyDamage.Next.Test.Shrink
  alias PropertyDamage.Next.Test.Surface

  defmodule Base do
    @moduledoc false
    use PropertyDamage.Next.Command

    defstruct [:base]

    def generator(_state, _opts), do: %{base: integer(1..5)}

    def stream_echo(%__MODULE__{base: base}), do: StreamData.integer(1..base)
    def description_echo(%__MODULE__{base: base}), do: integer(base..base)
  end

  defmodule AssignModel do
    @moduledoc false
    # Spec 1's assign :echo is a StreamData generator computed from the command.
    use PropertyDamage.Next.Model

    def steps do
      [Base]
      |> StepSpec.normalize()
      |> Enum.map(&StepSpec.assign_from_command(&1, :echo, fn c -> Base.stream_echo(c) end))
    end

    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule BothModel do
    @moduledoc false
    # A dependent field at spec 1 and a dependent assign at spec 2.
    use PropertyDamage.Next.Model

    def steps, do: StepSpec.normalize([F.PlainFrom]) ++ AssignModel.steps()
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule DescriptionModel do
    @moduledoc false
    # Dependent fields and a dependent assign that return PD's descriptions.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.Gen

    def steps do
      [F.Chain, Base]
      |> StepSpec.normalize()
      |> Enum.map(&StepSpec.assign_from_command(&1, :echo, fn c -> echo(c) end))
    end

    defp echo(%Base{} = command), do: Base.description_echo(command)
    defp echo(%F.Chain{base: base}), do: Gen.integer(base..base)

    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
  end

  defmodule FittingEngine do
    @moduledoc false
    # An engine that says it can fit a dependent StreamData value. It draws
    # every value through PD's own engine, unwrapped when generation hands it
    # a dependent generator in a wrapper.
    @behaviour PropertyDamage.Next.Engine

    alias PropertyDamage.Next.Engine.Native

    def fits_dependent?(_generator), do: true

    def draw(journal, key, generator, seed),
      do: Native.draw(journal, key, unwrap(generator), seed)

    defp unwrap(%{__struct__: PropertyDamage.Next.Engine.Dependent, generator: inner}), do: inner
    defp unwrap(generator), do: generator
  end

  @field_site %{site: :field, command: F.PlainFrom, key: :derived, spec: nil}
  @assign_site %{site: :assign, command: Base, key: :echo, spec: 1}

  @merged_text "a StreamData generator. PD's engine cannot fit its value when the field it " <>
                 "depends on changes. Return one of PD's descriptions instead: integer/1, " <>
                 "member_of/1 or boolean/0."

  # The number of warnings in `log`: each names PD's three descriptions once.
  defp warnings(log), do: log |> String.split("boolean/0") |> length() |> Kernel.-(1)

  defp kept(term), do: term |> Surface.field(:kept) |> Enum.sort()

  defp model_run(model, opts \\ []) do
    [model: model, adapter: Shrink.Adapter, seed: 3, max_steps: 4, max_plans: 3]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  describe "warn mode, the default" do
    test "a from/2 field that returns a StreamData generator warns once per call, naming the site" do
      for model <- [F.PlainFromModel, F.DelegatedFromModel], call <- 1..2 do
        {plan, log} = with_own_log(fn -> Next.plan(model, call, max_steps: 6) end)
        [module] = Enum.map(model.steps(), & &1.command)

        assert length(plan.steps) == 6
        assert warnings(log) == 1
        assert log =~ inspect(module)
        assert log =~ "derived"
        assert log =~ "integer/1"
        assert log =~ "member_of/1"
      end
    end

    test "the value is drawn from the generator the function returned" do
      capture_log(fn ->
        for step <- Next.plan(F.PlainFromModel, 4, max_steps: 10).steps do
          assert step.command.derived in 1..step.command.base
        end
      end)
    end

    test "a dependent assign that returns a StreamData generator warns once per call" do
      {plan, log} = with_own_log(fn -> Next.plan(AssignModel, 1, max_steps: 6) end)

      assert warnings(log) == 1
      assert log =~ inspect(Base)
      assert log =~ "echo"

      for step <- plan.steps, do: assert(step.assigns.echo in 1..step.command.base)
    end

    test "two sites in one plan warn once each" do
      {_plan, log} = with_own_log(fn -> Next.plan(BothModel, 2, max_steps: 12) end)
      assert warnings(log) == 2
    end

    test "a run of several plans warns once per site" do
      {result, log} =
        with_own_log(fn -> model_run(BothModel, max_steps: 12, ignored_assigns: [:echo]) end)

      assert {:ok, %{plans: 3}} = result
      assert warnings(log) == 2
    end

    test "a run that fails after its first plan and shrinks warns once per site" do
      fails? = fn
        %F.PlainFrom{base: 5, derived: derived}, _earlier -> derived >= 3
        _command, _earlier -> false
      end

      {failure, log} =
        Enum.find_value(1..60, fn seed ->
          {result, log} =
            with_own_log(fn ->
              Next.run(
                model: F.PlainFromModel,
                adapter: Shrink.Adapter,
                seed: seed,
                max_steps: 2,
                max_plans: 50,
                config: %{fails?: fails?}
              )
            end)

          case result do
            {:error, %Failure{plan_number: number} = failure} when number >= 2 -> {failure, log}
            _other -> nil
          end
        end) || flunk("no seed in 60 fails after its first plan")

      assert Surface.field(failure, :shrink_runs) > 0
      assert warnings(log) == 1
    end

    test "a description returned by a dependent field or assign does not warn" do
      {plan, log} = with_own_log(fn -> Next.plan(DescriptionModel, 1, max_steps: 10) end)

      assert warnings(log) == 0
      assert kept(plan) == []
    end

    test "each site is on the kept list of the plan, the run, the failure and the replay" do
      capture_log(fn ->
        assert kept(Next.plan(BothModel, 2, max_steps: 12)) ==
                 Enum.sort([@field_site, %{@assign_site | spec: 2}])

        assert kept(Next.plan(F.PlainFromModel, 2, max_steps: 3)) == [@field_site]

        assert {:ok, ok} = model_run(F.PlainFromModel)
        assert kept(ok) == [@field_site]

        fails? = fn _command, _earlier -> true end

        assert {:error, %Failure{} = failure} =
                 model_run(F.PlainFromModel, config: %{fails?: fails?})

        assert kept(failure) == [@field_site]

        assert {:ok, replayed} =
                 Next.replay(Next.plan(F.PlainFromModel, 1, max_steps: 3).journal,
                   model: F.PlainFromModel,
                   adapter: Shrink.Adapter
                 )

        assert kept(replayed) == [@field_site]
      end)
    end
  end

  describe "raise mode" do
    test "a from/2 field raises at the first draw with the site and the error text" do
      error =
        assert_raise Surface.dependent_error(), fn ->
          Next.plan(F.PlainFromModel, 1, max_steps: 2, dependent_stream_data: :raise)
        end

      message = Exception.message(error)
      assert message =~ inspect(F.PlainFrom) <> ", field :derived: the from/2 function returned "
      assert message =~ @merged_text
      assert Surface.field(error, :site) == @field_site
    end

    test "a dependent assign raises, naming the site" do
      error =
        assert_raise Surface.dependent_error(), fn ->
          Next.plan(AssignModel, 1, max_steps: 2, dependent_stream_data: :raise)
        end

      message = Exception.message(error)
      assert message =~ inspect(Base)
      assert message =~ ":echo"
      assert message =~ "a StreamData generator"
      assert message =~ "integer/1, member_of/1 or boolean/0"
      assert Surface.field(error, :site) == @assign_site
    end

    test "run/1 and replay/2 raise in raise mode" do
      assert_raise Surface.dependent_error(), fn ->
        model_run(F.PlainFromModel, dependent_stream_data: :raise)
      end

      {plan, _log} = with_own_log(fn -> Next.plan(F.PlainFromModel, 1, max_steps: 3) end)

      assert_raise Surface.dependent_error(), fn ->
        Next.replay(plan.journal,
          model: F.PlainFromModel,
          adapter: Shrink.Adapter,
          dependent_stream_data: :raise
        )
      end
    end

    test "a description does not raise" do
      plan = Next.plan(DescriptionModel, 1, max_steps: 10, dependent_stream_data: :raise)
      assert length(plan.steps) == 10
    end
  end

  describe "an engine that can fit the value" do
    test "gives neither a warning, a raise, nor a kept site" do
      {plan, log} =
        with_own_log(fn -> Next.plan(BothModel, 2, max_steps: 12, engine: FittingEngine) end)

      assert warnings(log) == 0
      assert kept(plan) == []

      raised =
        Next.plan(BothModel, 2,
          max_steps: 12,
          engine: FittingEngine,
          dependent_stream_data: :raise
        )

      assert raised.steps == plan.steps
    end
  end

  describe "after the source field changes" do
    test "the dependent value follows its stored path on the new generator" do
      specs = Model.specs!(F.PlainFromModel)
      key = {{0, 1}, :command, :derived}
      old = StreamData.integer(1..5)

      {seed, path} =
        Enum.find_value(1..100, fn seed ->
          key_seed = Journal.key_seed(seed, key)

          case Surface.child_count(old, key_seed, []) do
            0 -> nil
            count -> {seed, [count - 1]}
          end
        end) || flunk("no seed in 100 gives a value with children")

      key_seed = Journal.key_seed(seed, key)
      {stored, ^path} = Surface.walk(old, key_seed, path)

      journal = fn base ->
        %Journal{
          seed: seed,
          max_steps: 1,
          fingerprint: Journal.fingerprint(specs),
          entries: %{
            {{0, 1}, :pick} => {:pick, 1, F.PlainFrom},
            {{0, 1}, :command, :base} => {:integer, base, 1..5},
            key => {:stream_data, stored, path}
          }
        }
      end

      capture_log(fn ->
        same = Next.plan(F.PlainFromModel, journal.(5))
        assert [%{command: %F.PlainFrom{base: 5, derived: ^stored}}] = same.steps
        assert same.journal.entries[key] == {:stream_data, stored, path}

        changed = Next.plan(F.PlainFromModel, journal.(2))
        {value, reached} = Surface.walk(StreamData.integer(1..2), key_seed, path)

        assert [%{command: %F.PlainFrom{base: 2, derived: ^value}}] = changed.steps
        assert changed.journal.entries[key] == {:stream_data, value, reached}
        assert value in 1..2
      end)
    end
  end
end
