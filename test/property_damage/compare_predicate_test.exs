defmodule PropertyDamage.ComparePredicateTest do
  # `using:` decides whether a variant's value agrees with the reference's.
  # It is any expression that evaluates to a 2-arity function inside the
  # projection module, called `using.(reference_value, variant_value)` for
  # each non-reference variant.
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
      @compare using: &PropertyDamage.Test.Compare.same_settled?/2
      def totals(s, _root), do: #{@value}
    end
    """,
    private: """
    defmodule #{@ns}.Private do
    #{@header}
      @compare using: &within_one/2
      def totals(s, _root), do: #{@value}

      defp within_one(reference, variant) do
        if abs(reference.settled - variant.settled) <= 1,
          do: :match,
          else: {:mismatch, "settled differs by more than one"}
      end
    end
    """,
    inline: """
    defmodule #{@ns}.Inline do
    #{@header}
      @compare using: fn reference, variant -> reference.settled == variant.settled end
      def totals(s, _root), do: #{@value}
    end
    """,
    composed: """
    defmodule #{@ns}.Composed do
    #{@header}
      import PropertyDamage.Equivalence

      @compare using: by_key(fn v -> v |> normalize() |> drop_keys([:fees]) end)
      def totals(s, _root), do: #{@value}
    end
    """,
    kept_exception: """
    defmodule #{@ns}.KeptException do
    #{@header}
      @compare using: fn reference, variant ->
                 if reference.settled == variant.settled,
                   do: :match,
                   else: {:mismatch, %ArgumentError{message: "settled disagrees"}}
               end
      def totals(s, _root), do: #{@value}
    end
    """,
    positional: """
    defmodule #{@ns}.Positional do
    #{@header}
      @compare using: fn reference, variant ->
                 reference.settled == variant.settled or
                   {:mismatch,
                    "reference=" <> Integer.to_string(reference.settled) <>
                      " variant=" <> Integer.to_string(variant.settled)}
               end
      def totals(s, _root), do: #{@value}
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
    raising_predicate: """
    defmodule #{@ns}.RaisingPredicate do
    #{@header}
      @compare using: fn _reference, _variant -> raise ArgumentError, "predicate exploded" end
      def totals(s, _root), do: %{settled: s.settled}
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

  describe "the four ways to write using:" do
    test "a remote capture compiles and decides agreement", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :remote), targets(0))

      {reference, variant, mismatch} = diverge!(ctx, :remote, 5)
      # `false` becomes a mismatch holding both values, reference first.
      assert Compare.mismatch?(mismatch)
      assert mismatch.left == reference
      assert mismatch.right == variant
      assert variant.settled == reference.settled + 5
    end

    test "a capture of a private function of the projection compiles and decides agreement",
         ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :private), targets(0))
      assert {:ok, _stats} = Compare.run(model!(ctx, :private), targets(1))

      {_reference, _variant, mismatch} = diverge!(ctx, :private, 5)
      # A string becomes a mismatch with that message.
      assert Compare.mismatch?(mismatch)
      assert mismatch.message == "settled differs by more than one"
      assert Exception.message(mismatch) == "settled differs by more than one"
    end

    test "an inline fn compiles and decides agreement", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :inline), targets(0))

      {reference, variant, mismatch} = diverge!(ctx, :inline, 5)
      assert Compare.mismatch?(mismatch)
      assert {mismatch.left, mismatch.right} == {reference, variant}
    end

    test "a by_key composition with a closure compiles and keeps the normalized diff", ctx do
      assert {:ok, _stats} = Compare.run(model!(ctx, :composed), targets(0))

      {reference, variant, mismatch} = diverge!(ctx, :composed, 5)
      assert Compare.mismatch?(mismatch)
      # The key function's values: ids stripped, fees dropped.
      assert mismatch.left == %{settled: reference.settled}
      assert mismatch.right == %{settled: variant.settled}
    end
  end

  describe "what using: returns" do
    test "{:mismatch, exception} keeps that exception as the mismatch", ctx do
      {_reference, _variant, mismatch} = diverge!(ctx, :kept_exception, 5)
      assert %ArgumentError{message: "settled disagrees"} = mismatch
    end

    test "using: receives the reference value first and the variant value second", ctx do
      {reference, variant, mismatch} = diverge!(ctx, :positional, 5)

      assert Exception.message(mismatch) ==
               "reference=#{reference.settled} variant=#{variant.settled}"
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

  describe "a using: that is not a 2-arity function" do
    for {label, using} <- [
          {"an atom", ":exact"},
          {"a 1-arity fn", "fn value -> value end"},
          {"a 3-arity capture", "&Enum.at/3"}
        ] do
      test "#{label} is rejected at compile time or before any adapter setup" do
        name = "BadUsing#{System.unique_integer([:positive])}"
        projection = Module.concat(__MODULE__, name)

        source = """
        defmodule #{inspect(projection)} do
          use PropertyDamage.Model.Projection

          @impl true
          def init, do: %{}

          @impl true
          def apply(s, _), do: s

          @compare using: #{unquote(using)}
          def observed(_s, _root), do: :value
        end
        """

        case Compare.compile(source) do
          {:error, message} ->
            assert message =~ "@compare"
            assert message =~ "using:"

          {:ok, _modules} ->
            model =
              Compare.define_model!(Module.concat([__MODULE__, "Model", name]), [projection])

            error =
              Compare.raised(fn ->
                Compare.run(model, [Compare.target("a"), Compare.target("b")])
              end)

            assert Exception.message(error) =~ "@compare"
            assert Exception.message(error) =~ "using:"
            refute_received {:setup, _name}
        end
      end
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
