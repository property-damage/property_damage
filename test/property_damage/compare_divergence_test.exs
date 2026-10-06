defmodule PropertyDamage.CompareDivergenceTest do
  # Variants are compared only through their `@compare` observations, never by
  # the events their adapters returned. A divergence is identified by its kind,
  # its `@compare` key and its variant; the mismatch is detail. These tests pin
  # that identity through shrinking, reproduction and persistence.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Persistence, Sequence, Shrinker}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.Pay

  @ns inspect(__MODULE__)

  @header """
    use PropertyDamage.Model.Projection
    alias PropertyDamage.Test.Compare.{Paid, Settled}

    @impl true
    def init, do: %{unsettled: %{}, settled: 0, by: nil}

    @impl true
    def apply(s, %Paid{n: n, amount: a, by: by}), do: %{s | unsettled: Map.put(s.unsettled, n, a), by: by}
    def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
    def apply(s, _), do: s
  """

  @sources %{
    ledger: """
    defmodule #{@ns}.Ledger do
    #{@header}
      @compare every: 1
      def totals(s, _root) do
        if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
      end
    end
    """,
    tagged: """
    defmodule #{@ns}.Tagged do
    #{@header}
      @compare using: fn reference, variant ->
                 if reference == variant,
                   do: :match,
                   else: {:mismatch, "settled " <> inspect(reference) <> " vs " <> inspect(variant)}
               end
      def totals(s, _root), do: s.settled
    end
    """,
    raising: """
    defmodule #{@ns}.Raising do
    #{@header}
      @compare every: 1
      def totals(s, _root) do
        if s.by == "b", do: raise("observation exploded"), else: s.settled
      end
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

  defp b_at(n, mode), do: [Compare.target("a"), Compare.target("b", %{at: %{n => mode}})]

  describe "no event comparison" do
    test "targets whose events differ at every root pass when their observations agree", ctx do
      # Every Paid carries its target's name and "b" pays another fee, so no
      # root's events are equal across the two targets.
      targets = [Compare.target("a"), Compare.target("b", %{fee: 7})]

      assert {:ok, _stats} = Compare.run(model!(ctx, :ledger), targets, max_commands: 5)
    end
  end

  describe "a divergence" do
    test "carries the key, root, command, both values and the mismatch, and is named by the key",
         ctx do
      targets = [
        Compare.target("ledger-ref"),
        Compare.target("ledger-new", %{at: %{1 => {:sync, 1}}})
      ]

      assert {:error, report} =
               Compare.run(model!(ctx, :ledger), targets, compare: [converge_within: 50])

      key = key(ctx, :ledger)
      assert report.kind == :diverged
      assert report.variant == %{index: 1, name: "ledger-new"}
      assert Failure.kind(report.failure_reason) == :diverged
      assert Failure.name(report.failure_reason) == key
      assert Shrinker.failure_signature(report.failure_reason, 1) == {:diverged, key, 1}

      divergence = report.failure_reason.type
      assert Map.fetch!(divergence, :key) == key
      assert Map.fetch!(divergence, :root) == 1
      assert %Pay{n: 1} = Map.fetch!(divergence, :command)
      %{settled: settled} = Map.fetch!(divergence, :reference_value)
      assert Map.fetch!(divergence, :variant_value) == %{settled: settled + 1}
      assert Compare.mismatch?(Map.fetch!(divergence, :mismatch))

      text = Compare.text(report)
      assert text =~ "#{inspect(elem(key, 0))}.totals"
      assert text =~ "ledger-ref"
      assert text =~ "ledger-new"
    end

    test "the mismatch is detail: different mismatch texts at one key are one failure", ctx do
      [first, second] =
        for delta <- [1, 2] do
          assert {:error, report} =
                   Compare.run(model!(ctx, :tagged), b_at(1, {:sync, delta}),
                     compare: [converge_within: 30]
                   )

          report
        end

      mismatch = fn report -> Map.fetch!(report.failure_reason.type, :mismatch) end
      assert Exception.message(mismatch.(first)) != Exception.message(mismatch.(second))

      assert Shrinker.failure_signature(first.failure_reason, 1) ==
               Shrinker.failure_signature(second.failure_reason, 1)

      assert Shrinker.failure_signature(first.failure_reason, 1) ==
               {:diverged, key(ctx, :tagged), 1}
    end
  end

  describe "shrinking" do
    test "a divergence planted at root 7 of 12 shrinks to a failure at or before root 7", ctx do
      assert {:error, report} =
               Compare.run(model!(ctx, :ledger), b_at(7, {:sync, 1}),
                 max_commands: 12,
                 shrink: true,
                 compare: [converge_within: 30]
               )

      assert length(Sequence.to_list(report.original_sequence)) == 12
      assert report.kind == :diverged
      assert report.failed_at_index <= 7

      assert Shrinker.failure_signature(report.failure_reason, report.variant.index) ==
               {:diverged, key(ctx, :ledger), 1}

      shrunk = Sequence.to_list(FailureReport.shrunk_sequence(report))
      assert length(shrunk) <= 8
      assert Enum.any?(shrunk, &match?(%Pay{n: 7}, &1))
    end

    test "a root that did not converge at root 7 of 12 shrinks the same way", ctx do
      assert {:error, report} =
               Compare.run(model!(ctx, :ledger), b_at(7, :never),
                 max_commands: 12,
                 shrink: true,
                 compare: [converge_within: 30]
               )

      assert report.kind == :did_not_converge
      assert report.failed_at_index <= 7

      assert Shrinker.failure_signature(report.failure_reason, report.variant.index) ==
               {:did_not_converge, key(ctx, :ledger), 1}

      shrunk = Sequence.to_list(FailureReport.shrunk_sequence(report))
      assert length(shrunk) <= 8
    end
  end

  describe "reproduction" do
    test "shrinking and reproduction wait the run's bound, not the default", ctx do
      test_pid = self()

      {elapsed, result} =
        Compare.timed(fn ->
          Compare.run(model!(ctx, :ledger), b_at(1, :never),
            shrink: true,
            compare: [converge_within: 100],
            on_failure: fn report -> send(test_pid, {:on_failure, report}) end
          )
        end)

      assert {:error, report} = result
      assert report.kind == :did_not_converge
      # One re-run at the 5 s default would exceed this on its own.
      assert elapsed < 4_000

      assert_received {:on_failure, reported}
      assert reported.kind == :did_not_converge
      assert Map.fetch!(reported.failure_reason.type, :waited_ms) < 1_000

      assert FailureReport.reproduction_command(report) =~ "compare: [converge_within: 100]"
    end

    test "the reproduction command prints converge_within: only when it is not the default",
         ctx do
      for {bound, printed?} <- [{5_000, false}, {1_234, true}] do
        assert {:error, report} =
                 Compare.run(model!(ctx, :raising), b_at(1, :sync),
                   compare: [converge_within: bound]
                 )

        assert report.kind == :check_failed
        command = FailureReport.reproduction_command(report)

        if printed? do
          assert command =~ "compare: [converge_within: 1234]"
        else
          refute command =~ "converge_within"
        end
      end
    end
  end

  describe "persistence" do
    @tag :tmp_dir
    test "a report named by a {projection, function} key saves, loads and exports", %{
      tmp_dir: dir,
      compiled: compiled,
      models: models
    } do
      ctx = %{compiled: compiled, models: models}
      key = key(ctx, :ledger)

      for {mode, kind} <- [{{:sync, 1}, :diverged}, {:never, :did_not_converge}] do
        assert {:error, report} =
                 Compare.run(model!(ctx, :ledger), b_at(1, mode), compare: [converge_within: 30])

        assert report.kind == kind

        assert {:ok, path} = Persistence.save(report, Path.join(dir, Atom.to_string(kind)))
        assert File.exists?(path)
        assert {:ok, loaded} = Persistence.load(path)
        assert loaded.kind == kind
        assert Failure.name(loaded.failure_reason) == key

        decoded = report |> Persistence.export_json() |> Jason.decode!()
        assert decoded["kind"] == Atom.to_string(kind)
      end
    end
  end
end
