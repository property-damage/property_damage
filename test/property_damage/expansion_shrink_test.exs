defmodule PropertyDamage.ExpansionShrinkTest do
  # The shrinker works on roots: it deletes roots and simplifies root
  # arguments, and never draws a surviving root's expansion again. Each
  # candidate re-realizes every variant's leaves from the entry the root ran
  # before; a leaf whose precondition no longer holds makes that root run as
  # itself in that candidate ("identity, forced"). The reproduction and
  # `PropertyDamage.Replay` re-execute the concrete leaves of the report.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{FailureReport, Sequence, Shrinker}
  alias PropertyDamage.Test.ExpansionRun, as: X

  alias PropertyDamage.Test.ExpansionRun.{
    Authorize,
    Capture,
    Credit,
    Open,
    Pay,
    Refund,
    Totals
  }

  @max_commands 12

  defp model!(name, opts), do: X.define_model!(Module.concat(ExpansionB.Shrink, name), opts)

  # The model `name`, defined on first use.
  defp model_once!(name, opts) do
    module = Module.concat(ExpansionB.Shrink, name)
    if Code.ensure_loaded?(module), do: module, else: model!(name, opts)
  end

  defp run(model, targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: @max_commands,
          validate: false
        ],
        extra
      )
    )
  end

  # The reference draws its own expansions; "beta" credits one too much on
  # every Credit leaf, so only a Refund's rewrite exposes it.
  defp targets(recorder) do
    [X.target("alpha", recorder), X.target("beta", recorder, %{bug: :credit})]
  end

  # The first seed in 1..30 whose run fails, with its report and recorder.
  defp failing_run!(model) do
    Enum.find_value(1..30, fn seed ->
      recorder = start_recorder()

      case run(model, targets(recorder), seed: seed) do
        {:error, %FailureReport{} = report} -> {report, recorder}
        {:ok, _stats} -> nil
      end
    end) || flunk("no seed in 1..30 fails: the second variant never ran a Refund rewrite")
  end

  defp signature(report),
    do: Shrinker.failure_signature(report.failure_reason, report.variant.index)

  # `%{tag => [command]}`: the commands each root ran in one execution.
  defp ran(segment), do: Map.new(X.by_root(segment))

  defp shrunk(report), do: report |> FailureReport.shrunk_sequence() |> Sequence.to_list()

  defp expansions(report, name), do: report |> Map.fetch!(:expansions) |> Map.fetch!(name)

  describe "a divergence only a Refund rewrite exposes" do
    setup do
      model = model_once!(Divergence, expansions: [{Refund, &X.refund_two/2}])
      {report, recorder} = failing_run!(model)
      {:ok, report: report, entries: recorded(recorder)}
    end

    test "shrinks to a failure at or before its root with the same identity, still on the rewrite",
         %{report: report, entries: entries} do
      assert report.kind == :diverged
      assert report.variant == %{index: 1, name: "beta"}
      assert signature(report) == {:diverged, {Totals, :totals}, 1}

      original = Sequence.to_list(report.original_sequence)
      assert length(original) >= 10
      explored = entries |> X.segments("beta") |> hd() |> ran()

      root =
        Enum.find_index(original, fn command ->
          match?(%Refund{}, command) and
            X.modules(Map.get(explored, command.tag, [])) == [Credit, Credit]
        end)

      assert is_integer(root)
      assert report.failed_at_index <= root

      shrunk = shrunk(report)
      assert length(shrunk) < length(original)
      assert %Refund{tag: tag} = Enum.at(shrunk, report.failed_at_index)
      assert X.modules(explored[tag]) == [Credit, Credit]

      assert %{entry: "Refund[1]", leaves: [Credit, Credit]} =
               report |> expansions("beta") |> Enum.at(report.failed_at_index)
    end

    test "never draws a surviving root's expansion again", %{entries: entries} do
      for name <- ["alpha", "beta"] do
        [explored | later] = X.segments(entries, name)
        original = ran(explored)

        # The shrink attempts and the reproduction.
        assert length(later) >= 2

        for segment <- later, {tag, commands} <- X.by_root(segment) do
          assert Map.has_key?(original, tag)

          assert X.modules(commands) == X.modules(original[tag]),
                 "#{name} ran #{inspect(X.modules(commands))} where it first ran " <>
                   inspect(X.modules(original[tag]))

          # A leaf keeps the value its own draw gave it.
          if match?([%Credit{} | _], commands) do
            assert Enum.map(commands, & &1.memo) == Enum.map(original[tag], & &1.memo)
          end
        end
      end
    end

    test "re-realizes a simplified root's leaves through the same entry",
         %{report: report, entries: entries} do
      original = Map.new(Sequence.to_list(report.original_sequence), &{&1.tag, &1})
      shrunk = shrunk(report)
      roots = Map.new(shrunk, &{&1.tag, &1})
      reproduction = entries |> X.segments("beta") |> List.last()

      rewritten =
        for {tag, [%Credit{}, %Credit{}] = credits} <- X.by_root(reproduction) do
          assert Enum.map(credits, & &1.part) == [0, 1]
          assert credits |> Enum.map(& &1.amount) |> Enum.sum() == roots[tag].amount
          tag
        end

      assert rewritten != []

      # Argument shrinking simplified at least one Refund root.
      assert Enum.any?(shrunk, fn
               %Refund{tag: tag, amount: amount} -> amount < original[tag].amount
               _root -> false
             end)
    end
  end

  describe "a candidate whose carried entry fails a leaf precondition" do
    test "runs that root as itself, forced, and is tried" do
      model =
        model!(Fallback,
          commands: [Open, Pay, Refund, {Capture, when: &(&1.authorizing and &1.opened)}],
          expansions: [{Pay, &X.pay_rewrite/2}, {Refund, &X.refund_rewrite/2}]
        )

      # One Pay, after an Open (so its Capture leaf may run) and before a
      # Refund.
      seed =
        X.find_seed(model, 6, 1..5_000, fn roots ->
          case Enum.split_with(Enum.with_index(roots), &match?({%Pay{}, _}, &1)) do
            {[{_pay, p}], _others} ->
              roots |> Enum.take(p) |> Enum.any?(&match?(%Open{}, &1)) and
                roots |> Enum.drop(p + 1) |> Enum.any?(&match?(%Refund{}, &1))

            _ ->
              false
          end
        end) || flunk("no seed in 1..5000 generates the roots this test needs")

      recorder = start_recorder()

      targets = [
        X.target("alpha", recorder, %{}, expansion: :identity),
        X.target("beta", recorder, %{bug: :credit_after_payment})
      ]

      assert {:error, report} = run(model, targets, seed: seed, max_commands: 6)
      assert report.kind == :diverged
      assert report.variant == %{index: 1, name: "beta"}

      %Pay{tag: pay} =
        report.original_sequence |> Sequence.to_list() |> Enum.find(&match?(%Pay{}, &1))

      [explored | later] = recorder |> recorded() |> X.segments("beta")
      assert X.modules(ran(explored)[pay]) == [Authorize, Capture]

      # Deleting the Open withdrew the rewrite: an attempt ran Pay itself.
      assert Enum.any?(later, fn segment -> X.modules(Map.get(ran(segment), pay, [])) == [Pay] end)

      assert report |> shrunk() |> Enum.map(& &1.__struct__) == [Pay, Refund]

      assert [
               %{entry: :forced, leaves: [Pay]},
               %{entry: "Refund[0]", leaves: [Credit, Credit]}
             ] = expansions(report, "beta")

      forced = report |> Map.fetch!(:expansion_counts) |> Map.fetch!("beta") |> Map.fetch!(Pay)
      assert Map.fetch!(forced, :forced) >= 1
    end
  end

  describe "the reproduction and Replay" do
    test "re-execute the reference's concrete leaves from the report" do
      model = model!(Replay, expansions: [{Refund, &X.refund_rewrite/2}])
      {report, recorder} = failing_run!(model)

      [explored | _] = segments = recorder |> recorded() |> X.segments("alpha")
      reproduction = List.last(segments)
      original = ran(explored)

      assert Enum.any?(reproduction, &match?(%Credit{}, &1))

      for {tag, commands} <- X.by_root(reproduction) do
        assert X.modules(commands) == X.modules(original[tag])

        if match?([%Credit{} | _], commands) do
          assert Enum.map(commands, & &1.memo) == Enum.map(original[tag], & &1.memo)
        end
      end

      reported = report |> expansions("alpha") |> Enum.flat_map(& &1.leaves)
      assert reported == Enum.map(reproduction, & &1.__struct__)

      assert {:ok, _steps} = PropertyDamage.Replay.run(report)

      replayed = recorder |> recorded() |> X.segments("alpha") |> List.last()
      assert replayed == reproduction
    end
  end
end
