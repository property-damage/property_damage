defmodule PropertyDamage.ComparePredicateTest do
  # `using:` names the relation that decides whether a variant's value agrees
  # with the reference's (DR-051): `:fun`, `{Mod, :fun}` or `{Mod, :fun, args}`,
  # called with the reference value first for each non-reference variant.
  use ExUnit.Case, async: true

  alias PropertyDamage.Failure
  alias PropertyDamage.Test.Compare

  @ns inspect(__MODULE__)

  @header """
    use PropertyDamage.Model.Projection
    alias PropertyDamage.Test.Compare.{Paid, Settled}

    @impl true
    def init, do: %{settled: 0, fees: 0, by: nil}

    @impl true
    def apply(s, %Paid{fee: f, by: by}), do: %{s | fees: s.fees + f, by: by}
    def apply(s, %Settled{amount: a}), do: %{s | settled: s.settled + a}
    def apply(s, _), do: s
  """

  # Every value carries the variant's own name under :id and its fees, so
  # `==` would never agree across variants.
  @value "%{settled: s.settled, fees: s.fees, id: s.by}"

  @sources %{
    remote: """
    defmodule #{@ns}.Remote do
    #{@header}
      @compare using: {PropertyDamage.Test.Compare, :same_settled?}
      def totals(s, _root), do: #{@value}
    end
    """,
    remote_args: """
    defmodule #{@ns}.RemoteArgs do
    #{@header}
      @compare using: {PropertyDamage.Test.Compare, :settled_within, [1]}
      def totals(s, _root), do: #{@value}
    end
    """,
    private: """
    defmodule #{@ns}.Private do
    #{@header}
      @compare using: :within_one
      def totals(s, _root), do: #{@value}

      defp within_one(reference, variant) do
        abs(reference.settled - variant.settled) <= 1 or
          {:fail, "settled differs by more than one"}
      end
    end
    """,
    module_private: """
    defmodule #{@ns}.ModulePrivate do
    #{@header}
      @compare using: {__MODULE__, :within, [1]}
      def totals(s, _root), do: #{@value}

      defp within(reference, variant, tolerance),
        do: abs(reference.settled - variant.settled) <= tolerance
    end
    """,
    normalized: """
    defmodule #{@ns}.Normalized do
    #{@header}
      import PropertyDamage.Equivalence

      @compare every: 1
      def totals(s, _root), do: #{@value} |> normalize() |> drop_keys([:fees])
    end
    """,
    kept_exception: """
    defmodule #{@ns}.KeptException do
    #{@header}
      @compare using: :same_settled
      def totals(s, _root), do: #{@value}

      defp same_settled(reference, variant) do
        reference.settled == variant.settled or
          {:fail, %ArgumentError{message: "settled disagrees"}}
      end
    end
    """,
    positional: """
    defmodule #{@ns}.Positional do
    #{@header}
      @compare using: :same_settled
      def totals(s, _root), do: #{@value}

      defp same_settled(reference, variant) do
        reference.settled == variant.settled or
          {:fail,
           "reference=" <> Integer.to_string(reference.settled) <>
             " variant=" <> Integer.to_string(variant.settled)}
      end
    end
    """,
    exact: """
    defmodule #{@ns}.Exact do
    #{@header}
      @compare every: 1
      def totals(s, _root), do: %{settled: s.settled}
    end
    """,
    raising_observation: """
    defmodule #{@ns}.RaisingObservation do
    #{@header}
      @compare every: 1
      def totals(s, _root) do
        if s.by == "b", do: raise("observation exploded"), else: %{settled: s.settled}
      end
    end
    """,
    retired_mismatch: """
    defmodule #{@ns}.RetiredMismatch do
    #{@header}
      @compare using: :same_settled
      def totals(s, _root), do: #{@value}

      defp same_settled(reference, variant) do
        if reference.settled == variant.settled, do: :match, else: {:mismatch, "settled differs"}
      end
    end
    """,
    raising_predicate: """
    defmodule #{@ns}.RaisingPredicate do
    #{@header}
      @compare using: :explode
      def totals(s, _root), do: %{settled: s.settled}

      defp explode(_reference, _variant), do: raise(ArgumentError, "predicate exploded")
    end
    """
  }

  setup_all do
    compiled = Compare.compile_all(@sources)

    models =
      for name <- Map.keys(@sources), into: %{} do
        projection = Module.concat(__MODULE__, Macro.camelize(Atom.to_string(name)))
        module = Module.concat([__MODULE__, "Model", Macro.camelize(Atom.to_string(name))])
        {name, Compare.define_model!(module, [projection])}
      end

    {:ok, compiled: compiled, models: models}
  end

  defp model!(ctx, name) do
    Compare.fixture!(ctx.compiled, name)
    Map.fetch!(ctx.models, name)
  end

  defp key(ctx, name), do: {Compare.fixture!(ctx.compiled, name), :totals}

  # "b" pays a different fee from "a"; `delta` shifts its settlement at root 1.
  defp targets(delta) do
    at = if delta == 0, do: %{}, else: %{1 => {:sync, delta}}
    [Compare.target("a"), Compare.target("b", %{fee: 3, at: at})]
  end

  defp diverge!(ctx, name, delta) do
    assert {:error, report} =
             Compare.run(model!(ctx, name), targets(delta), compare: [converge_within: 30])

    assert report.kind == :diverged
    assert Failure.name(report.failure_reason) == key(ctx, name)
    divergence = report.failure_reason.type

    {Map.fetch!(divergence, :reference_value), Map.fetch!(divergence, :variant_value),
     Map.fetch!(divergence, :mismatch)}
  end

  describe "the three named forms of using:" do
    test "{Mod, :fun} names a remote 2-arity relation", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :remote), targets(0))

      {reference, variant, mismatch} = diverge!(ctx, :remote, 5)
      # `false` becomes a mismatch holding both values, reference first.
      assert Compare.mismatch?(mismatch)
      assert mismatch.left == reference
      assert mismatch.right == variant
      assert variant.settled == reference.settled + 5
    end

    test "{Mod, :fun, args} calls fun(reference, variant, arg1, ..., argN)", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :remote_args), targets(1))
      {reference, variant, _mismatch} = diverge!(ctx, :remote_args, 2)
      assert variant.settled == reference.settled + 2
    end

    test ":fun names a private function of the projection", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :private), targets(0))
      assert {:ok, _stats} = Compare.run(model!(ctx, :private), targets(1))

      {_reference, _variant, mismatch} = diverge!(ctx, :private, 5)
      # A string becomes a mismatch with that message.
      assert Compare.mismatch?(mismatch)
      assert mismatch.message == "settled differs by more than one"
      assert Exception.message(mismatch) == "settled differs by more than one"
    end

    test "{__MODULE__, :fun, args} names a private function of the projection", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :module_private), targets(1))
      {reference, variant, _mismatch} = diverge!(ctx, :module_private, 2)
      assert variant.settled == reference.settled + 2
    end

    test "__compare_using__/1 returns a 2-arity function for each form", ctx do
      for name <- [:remote, :remote_args, :private, :module_private, :exact] do
        {projection, observation} = key(ctx, name)
        assert is_function(projection.__compare_using__(observation), 2)
      end
    end

    test "an observation that normalizes its own value needs no using:", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :normalized), targets(0))

      {reference, variant, mismatch} = diverge!(ctx, :normalized, 5)
      assert Compare.mismatch?(mismatch)
      # The values compared: ids stripped, fees dropped.
      assert reference == %{settled: variant.settled - 5}
      assert {mismatch.left, mismatch.right} == {reference, variant}
    end
  end

  describe "what using: returns" do
    test "{:fail, exception} keeps that exception as the mismatch", ctx do
      {_reference, _variant, mismatch} = diverge!(ctx, :kept_exception, 5)
      assert %ArgumentError{message: "settled disagrees"} = mismatch
    end

    test "using: receives the reference value first and the variant value second", ctx do
      {reference, variant, mismatch} = diverge!(ctx, :positional, 5)

      assert Exception.message(mismatch) ==
               "reference=#{reference.settled} variant=#{variant.settled}"
    end

    test "the retired {:mismatch, _} disagrees with the grammar nudge", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :retired_mismatch), targets(0))
      {_reference, _variant, mismatch} = diverge!(ctx, :retired_mismatch, 5)

      assert Exception.message(mismatch) ==
               ~s(returned {:mismatch, "settled differs"}, which is not a verdict; ) <>
                 "a verdict is truthy, `nil`/`false`, or `{:fail, reason}`"
    end

    test "without using:, values agree under ==", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :exact), targets(0))
      {reference, variant, _mismatch} = diverge!(ctx, :exact, 1)
      assert variant == %{settled: reference.settled + 1}
    end
  end

  describe "every non-reference variant is compared with the reference" do
    test "the first target is the reference; a third target's disagreement names it", ctx do
      model = model!(ctx, :exact)

      targets = [
        Compare.target("a"),
        Compare.target("b"),
        Compare.target("c", %{at: %{1 => {:sync, 1}}})
      ]

      assert {:error, report} = Compare.run(model, targets, compare: [converge_within: 30])
      assert report.kind == :diverged
      assert report.variant == %{index: 2, name: "c"}
    end

    test "a second target's disagreement names it while a third agrees", ctx do
      model = model!(ctx, :exact)

      targets = [
        Compare.target("a"),
        Compare.target("b", %{at: %{1 => {:sync, 1}}}),
        Compare.target("c")
      ]

      assert {:error, report} = Compare.run(model, targets, compare: [converge_within: 30])
      assert report.variant == %{index: 1, name: "b"}
    end
  end

  describe "a using: that names no relation is a CompileError" do
    defp compile_using(using, extra \\ "") do
      name = "BadUsing#{System.unique_integer([:positive])}"

      Compare.compile("""
      defmodule #{inspect(Module.concat(__MODULE__, name))} do
        use PropertyDamage.Model.Projection

        @compare using: #{using}
        def observed(_s, _root), do: :value
      #{extra}
      end
      """)
    end

    # Every message names the observation, the using: term and the arity.
    defp assert_using_error(using, extra \\ "", expected) do
      assert {:error, message} = compile_using(using, extra)
      assert message =~ "@compare on observed/2"
      assert message =~ "has using: "
      # `__MODULE__` reads back as the projection's own name.
      assert message =~ String.replace(using, "{__MODULE__", "")

      for fragment <- List.wrap(expected) do
        assert message =~ fragment
      end

      message
    end

    for {label, using} <- [
          {"a string", ~S("exact")},
          {"a one-element tuple", "{Enum}"},
          {"a tuple whose function is not an atom", ~S({Enum, "count"})},
          {"args that are not a list", "{Enum, :count, 3}"}
        ] do
      test "an unknown form, #{label}, names the three forms" do
        assert_using_error(unquote(using), ["not a relation name", "{Mod, :fun, args}"])
      end
    end

    test "a function value names the form to write instead" do
      {:error, message} = compile_using("fn reference, variant -> reference == variant end")
      assert message =~ "@compare on observed/2"
      assert message =~ "a function value cannot be printed in a report or recorded"
      assert message =~ "`&fun/2` becomes `:fun`"
      assert message =~ "a relation"
    end

    test "a function value inside args names the form to write instead" do
      assert_using_error("{Enum, :count, [&Enum.count/1]}", [
        "function value &Enum.count/1",
        "`{Mod, :fun}`"
      ])
    end

    test "a missing local function" do
      assert_using_error(":close?", [
        "defines no close?/2",
        "a relation takes 2 arguments, close?(reference_value, variant_value)"
      ])
    end

    test "a local function of the wrong arity" do
      assert_using_error(":close?", "  def close?(a, b, c), do: a == b and c", [
        "defines no close?/2 (it defines close?/3)",
        "takes 2 arguments"
      ])
    end

    test "a local function of the wrong arity for its args" do
      assert_using_error(
        "{__MODULE__, :close?, [1]}",
        "  defp close?(a, b), do: a == b",
        ["defines no close?/3 (it defines close?/2)", "with 1 args takes 3 arguments"]
      )
    end

    test "a remote module that does not export the function" do
      assert_using_error("{Enum, :to_list}", [
        "Enum does not export to_list/2 (it defines to_list/1)",
        "takes 2 arguments"
      ])
    end

    test "a remote module that does not exist" do
      assert_using_error("{PropertyDamage.NoSuchRelations, :close?}", [
        "PropertyDamage.NoSuchRelations cannot be loaded",
        "takes 2 arguments"
      ])
    end

    test "__compares__/0 records the using: term as written" do
      assert {:ok, [projection | _]} =
               compile_using("{PropertyDamage.Test.Compare, :same_settled?}")

      assert projection.__compares__() == [
               %{
                 name: :observed,
                 schedule: %{roots: :all, end: false},
                 using: {PropertyDamage.Test.Compare, :same_settled?}
               }
             ]
    end
  end

  describe "an observation or a predicate that raises" do
    test "an observation that raises is a check failure in the variant producing the value",
         ctx do
      {elapsed, result} =
        Compare.timed(fn -> Compare.run(model!(ctx, :raising_observation), targets(0)) end)

      assert {:error, report} = result
      # The run ends at once; the default bound of 5 s is never waited.
      assert elapsed < 2_000
      assert report.kind == :check_failed
      assert report.variant == %{index: 1, name: "b"}
      assert Failure.name(report.failure_reason) == key(ctx, :raising_observation)

      assert %RuntimeError{message: "observation exploded"} =
               Failure.detail(report.failure_reason)
    end

    test "a predicate that raises is a check failure in the non-reference variant", ctx do
      {elapsed, result} =
        Compare.timed(fn -> Compare.run(model!(ctx, :raising_predicate), targets(0)) end)

      assert {:error, report} = result
      assert elapsed < 2_000
      assert report.kind == :check_failed
      assert report.variant == %{index: 1, name: "b"}
      assert Failure.name(report.failure_reason) == key(ctx, :raising_predicate)
      assert %ArgumentError{message: "predicate exploded"} = Failure.detail(report.failure_reason)
    end
  end
end
