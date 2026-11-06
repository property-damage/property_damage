defmodule PropertyDamage.FailureIntelligenceEndToEndTest do
  # Drives FailureIntelligence over the reports of real failing campaigns: one
  # ledger defect found under several seeds, and a different defect (an adapter
  # crash) found under one.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureIntelligence, as: FI
  alias PropertyDamage.FailureIntelligence.Verification
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.Gauntlet, as: G

  @bug {:double_debit_from, 5}
  @seeds [7, 11, 23, 99]

  setup_all do
    drift = for seed <- @seeds, do: failure(G.Model, @bug, seed)
    %{drift: drift, crash: failure(G.Model, :crash, 7)}
  end

  defp failure(model, bug, seed) do
    {:error, %FailureReport{} = report} = G.run(model, bug, seed: seed)
    report
  end

  describe "find_similar/3" do
    test "keeps the reports of the same defect and drops the other defect",
         %{drift: [target | others] = drift, crash: crash} do
      found = FI.find_similar(target, drift ++ [crash])

      assert length(found) == length(drift)
      assert Enum.all?(found, fn {_report, score} -> score >= 0.99 end)
      refute Enum.any?(found, fn {report, _score} -> report == crash end)
      assert Enum.all?(others, fn other -> Enum.any?(found, &(elem(&1, 0) == other)) end)
    end

    test "scores the other defect below the threshold", %{drift: [target | _], crash: crash} do
      score = FI.similarity_score(target, crash)

      assert score < 0.70
      refute FI.similar?(target, crash)
      assert FI.similar?(target, crash, 0.3)
      assert [{^crash, ^score}] = FI.find_similar(target, [crash], threshold: 0.3)
    end

    test "reports why the other defect differs", %{drift: [target | _], crash: crash} do
      %{is_similar: false, breakdown: breakdown} = FI.compare(target, crash)

      assert breakdown.failure_type == 0.0
      assert breakdown.check_name == 0.0
      assert breakdown.command_type == 1.0
    end

    test "limits the results", %{drift: [target | _] = drift} do
      assert [_one, _two] = FI.find_similar(target, drift, limit: 2)
    end
  end

  describe "fingerprint_hash/1" do
    test "is the same for one defect found under different seeds", %{drift: drift} do
      assert [hash] = drift |> Enum.map(&FI.fingerprint_hash/1) |> Enum.uniq()
      assert hash =~ ~r/\A[0-9a-f]{8}\z/
    end

    test "differs for another defect", %{drift: [target | _], crash: crash} do
      refute FI.fingerprint_hash(target) == FI.fingerprint_hash(crash)
    end

    test "records the check, the trigger command and the seed", %{drift: [target | _]} do
      fingerprint = FI.fingerprint(target)

      assert fingerprint.seed == 7
      assert fingerprint.failure_type == :check_failed
      assert fingerprint.check_name == :balance_matches_ledger
      assert fingerprint.command_type == G.Commands.Withdraw
    end
  end

  describe "cluster/2" do
    test "groups one defect together and sets the other apart", %{drift: drift, crash: crash} do
      clusters = FI.cluster(drift ++ [crash])

      assert clusters |> Enum.map(& &1.size) |> Enum.sort() == [1, length(drift)]
    end
  end

  describe "verify_fix/3" do
    test "verifies a fix against the correct adapter", %{drift: [target | _]} do
      result =
        FI.verify_fix(target, G.Model,
          targets: [{G.Adapter, config: %{bug: :off}}],
          max_variations: 4
        )

      assert result.status == :verified
      assert result.original_passes
      assert result.original_seed == 7
      assert result.variations_run == 4
      assert result.variations_passed == 4
      assert result.variations_failed == 0
      assert result.failed_variations == []
      assert result.confidence == 1.0
    end

    test "reports the buggy adapter as still failing", %{drift: [target | _]} do
      result =
        FI.verify_fix(target, G.Model,
          targets: [{G.Adapter, config: %{bug: @bug}}],
          max_variations: 4
        )

      assert result.status == :still_failing
      refute result.original_passes
      assert result.variations_failed == 4
      assert result.summary == "Fix NOT verified. Original failure still reproduces."
    end

    test "collects the reports of the variations that still fail", %{drift: [target | _]} do
      result =
        FI.verify_fix(target, G.Model,
          targets: [{G.Adapter, config: %{bug: @bug}}],
          max_variations: 3
        )

      assert length(result.similar_failures) == 3
      assert Enum.all?(result.similar_failures, &FI.similar?(&1, target))
    end
  end

  describe "analyze/2 and verify_cluster/3" do
    test "finds one pattern in the reports of one defect", %{drift: drift, crash: crash} do
      analysis = FI.analyze(drift ++ [crash])

      assert [%{size: 4}] = analysis.clusters
      assert analysis.pattern_summary =~ "balance_matches_ledger"
    end

    test "marks the cluster fixed against the correct adapter", %{drift: drift} do
      [cluster] = FI.cluster(drift)

      result =
        Verification.verify_cluster(cluster, G.Model,
          targets: [{G.Adapter, config: %{bug: :off}}]
        )

      assert result.status == :fully_fixed
      assert result.fixed == 4
      assert result.remaining == 0
    end

    test "keeps the cluster open against the buggy adapter", %{drift: drift} do
      [cluster] = FI.cluster(drift)

      result =
        Verification.verify_cluster(cluster, G.Model,
          targets: [{G.Adapter, config: %{bug: @bug}}]
        )

      assert result.status == :not_fixed
      assert result.fixed == 0
      assert result.remaining == 4
    end
  end
end
