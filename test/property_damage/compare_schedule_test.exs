defmodule PropertyDamage.CompareScheduleTest do
  # A projection function marked `@compare` is a boundary observation: the
  # comparison evaluates it at the root boundaries its `every:` schedule names
  # and compares each variant's value with the reference's. These tests pin the
  # schedule vocabulary, the final boundary and the one-target case.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Sequence, Shrinker}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.{Pay, Read}

  @ns inspect(__MODULE__)

  @header """
    use PropertyDamage.Model.Projection
    alias PropertyDamage.Test.Compare.{Paid, Pay, Read, Settled}

    @impl true
    def init, do: %{unsettled: %{}, settled: 0, paid: 0}

    @impl true
    def apply(s, %Paid{n: n, amount: a}), do: %{s | unsettled: Map.put(s.unsettled, n, a), paid: s.paid + 1}
    def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
    def apply(s, _), do: s
  """

  @sources %{
    forms: """
    defmodule #{@ns}.Forms do
    #{@header}
      # No every: (only using:) means every root boundary.
      @compare using: &Kernel.==/2
      def plain(s, _root), do: s.paid

      @compare every: 1
      def every_one(s, _root), do: s.paid

      @compare every: 2
      def every_two(s, _root), do: s.paid

      @compare every: {2, Pay}
      def every_second_pay(s, _root), do: s.paid

      @compare every: Read
      def reads(s, _root), do: s.paid

      @compare every: [Read, Pay]
      def both(s, _root), do: s.paid

      @compare every: [Read, :end]
      def reads_and_end(s, _root), do: s.paid

      @compare every: [Pay, :end]
      def pays_and_end(s, _root), do: s.paid

      @compare every: :end
      def at_end(s, _root), do: s.paid
    end
    """,
    roots: """
    defmodule #{@ns}.Roots do
    #{@header}
      @compare every: Pay
      def at_root(s, root), do: %{root: root, settled: s.settled}
    end
    """,
    end_only: """
    defmodule #{@ns}.EndOnly do
    #{@header}
      @compare every: :end
      def totals(s, _root), do: %{settled: s.settled}
    end
    """,
    final: """
    defmodule #{@ns}.Final do
    #{@header}
      @compare every: :end
      def settled(s, _root), do: s.settled

      @eventually after: Paid, timeout: {2_000, :milliseconds}, interval: {10, :milliseconds}
      def settles(_s, %Paid{n: n}) do
        fn s -> not Map.has_key?(s.unsettled, n) end
      end
    end
    """,
    boom: """
    defmodule #{@ns}.Boom do
    #{@header}
      @compare every: 1
      def boom(_s, _root), do: raise("a @compare function ran in a one-target run")
    end
    """
  }

  setup_all do
    compiled = Compare.compile_all(@sources)

    models =
      Map.new(
        [
          forms: {[Module.concat(__MODULE__, Forms)], [Read, Pay, Read, Pay]},
          roots: {[Module.concat(__MODULE__, Roots)], :pay},
          end_only: {[Module.concat(__MODULE__, EndOnly)], :pay},
          final: {[Module.concat(__MODULE__, Final)], [Pay]},
          boom: {[Module.concat(__MODULE__, Boom)], :pay}
        ],
        fn {name, {projections, commands}} ->
          module = Module.concat([__MODULE__, "Model", Macro.camelize(Atom.to_string(name))])
          {name, Compare.define_model!(module, projections, commands)}
        end
      )

    {:ok, compiled: compiled, models: models}
  end

  defp model!(ctx, name) do
    Compare.fixture!(ctx.compiled, name)
    Map.fetch!(ctx.models, name)
  end

  describe "every: vocabulary" do
    test "each accepted every: form compares at the boundaries it names", ctx do
      model = model!(ctx, :forms)
      forms = Compare.fixture!(ctx.compiled, :forms)

      # The sequence is Read, Pay, Read, Pay: four roots, the last a Pay.
      assert {:ok, stats} =
               Compare.run(model, [Compare.target("a"), Compare.target("b")], max_commands: 4)

      compared = fn name -> Compare.counts(stats, {forms, name}).compared_at end

      # No every: means every root boundary, the last included.
      assert compared.(:plain) == 4
      assert compared.(:every_one) == 4
      # Every second boundary: roots 1 and 3.
      assert compared.(:every_two) == 2
      # Every second Pay root: root 3 only.
      assert compared.(:every_second_pay) == 1
      # A module schedule is not compared at the final boundary unless the
      # last root is one of its modules.
      assert compared.(:reads) == 2
      assert compared.(:both) == 4
      assert compared.(:reads_and_end) == 3
      # The last root is a Pay and :end names it too: compared once there.
      assert compared.(:pays_and_end) == 2
      assert compared.(:at_end) == 1
    end

    for {label, opts} <- [
          {"every: :command", "every: :command"},
          {"every: :event", "every: :event"},
          {"a bare unknown atom (every: :ends)", "every: :ends"},
          {"at: :teardown", "at: :teardown"},
          {"an unknown option (window: 5)", "window: 5"}
        ] do
      test "#{label} is a compile error naming @compare and its own vocabulary" do
        name = "Rejected#{System.unique_integer([:positive])}"

        source = """
        defmodule #{@ns}.#{name} do
          use PropertyDamage.Model.Projection

          @impl true
          def init, do: %{}

          @impl true
          def apply(s, _), do: s

          @compare #{unquote(opts)}
          def observed(_s, _root), do: :value
        end
        """

        assert {:error, message} = Compare.compile(source)
        assert message =~ "@compare"
        # @compare's vocabulary includes :end, which @check's does not.
        assert message =~ ":end"
        refute message =~ "expected :command, :event"
      end
    end
  end

  describe "arguments" do
    test "an observation receives the projection state and the root command", ctx do
      model = model!(ctx, :roots)
      roots = Compare.fixture!(ctx.compiled, :roots)

      assert {:error, report} =
               Compare.run(
                 model,
                 [Compare.target("a"), Compare.target("b", %{at: %{1 => {:sync, 1}}})],
                 compare: [converge_within: 50]
               )

      assert report.kind == :diverged
      assert Failure.name(report.failure_reason) == {roots, :at_root}

      divergence = report.failure_reason.type
      reference = Map.fetch!(divergence, :reference_value)
      variant = Map.fetch!(divergence, :variant_value)

      assert %Pay{n: 1} = reference.root
      assert reference.root == Map.fetch!(divergence, :command)
      assert variant.root == reference.root
      assert variant.settled == reference.settled + 1
    end
  end

  describe "the final boundary" do
    test ":end is the last root of the shrunk sequence", ctx do
      model = model!(ctx, :end_only)
      end_only = Compare.fixture!(ctx.compiled, :end_only)

      assert {:error, report} =
               Compare.run(
                 model,
                 [Compare.target("a"), Compare.target("b", %{at: %{5 => {:sync, 1}}})],
                 max_commands: 12,
                 shrink: true,
                 compare: [converge_within: 30]
               )

      assert report.kind == :diverged
      assert Failure.name(report.failure_reason) == {end_only, :totals}

      assert Shrinker.failure_signature(report.failure_reason, report.variant.index) ==
               {:diverged, {end_only, :totals}, 1}

      shrunk = Sequence.to_list(FailureReport.shrunk_sequence(report))
      assert length(Sequence.to_list(report.original_sequence)) == 12
      assert length(shrunk) < 12
      assert Enum.any?(shrunk, &match?(%Pay{n: 5}, &1))
      # Compared only at the end, so the failure is at the shrunk sequence's
      # last root.
      assert report.failed_at_index == length(shrunk) - 1
    end

    test "is compared after the variant finalized: an event delivered meanwhile is seen", ctx do
      # The variant settles 150 ms after its only root; its @eventually check
      # holds finalization until the settlement arrives. Compared before
      # finalization, the values would still differ when the 50 ms bound
      # expires.
      model = model!(ctx, :final)

      assert {:ok, _stats} =
               Compare.run(
                 model,
                 [Compare.target("a"), Compare.target("b", %{at: %{0 => {:after_ms, 150}}})],
                 compare: [converge_within: 50]
               )
    end
  end

  describe "one target" do
    test "never calls an observation and reads its counters as 0", ctx do
      model = model!(ctx, :boom)
      boom = Compare.fixture!(ctx.compiled, :boom)

      assert {:ok, stats} = Compare.run(model, [Compare.target("a")])

      assert Compare.field(stats, :compare_counts) == %{
               {boom, :boom} => %{compared_at: 0, waited_at: 0, waited_ms: 0}
             }
    end
  end
end
