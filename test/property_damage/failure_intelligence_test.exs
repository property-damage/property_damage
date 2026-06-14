defmodule PropertyDamage.FailureIntelligenceTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureIntelligence
  alias PropertyDamage.FailureIntelligence.{Fingerprint, Patterns, Similarity}
  alias PropertyDamage.FailureReport

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defmodule TestCommand.CreateAccount do
    defstruct [:account_ref, :initial_balance, :currency]
  end

  defmodule TestCommand.CreditAccount do
    defstruct [:account_ref, :amount, :currency]
  end

  defmodule TestCommand.DebitAccount do
    defstruct [:account_ref, :amount, :currency]
  end

  defmodule TestEvent.AccountCreated do
    defstruct [:account_ref, :balance, :currency]
  end

  defmodule TestEvent.AccountCredited do
    defstruct [:account_ref, :amount, :new_balance]
  end

  defmodule TestEvent.AccountDebited do
    defstruct [:account_ref, :amount, :new_balance]
  end

  def create_failure_report(opts \\ []) do
    %FailureReport{
      seed: Keyword.get(opts, :seed, 12_345),
      failure_type: Keyword.get(opts, :failure_type, :check_failed),
      check_name: Keyword.get(opts, :check_name, :balance_non_negative),
      failure_message: Keyword.get(opts, :message, "Balance -100 is negative"),
      shrunk_sequence:
        Keyword.get(opts, :sequence, %{
          commands: [
            %TestCommand.CreateAccount{
              account_ref: "acc_1",
              initial_balance: 100,
              currency: "USD"
            },
            %TestCommand.DebitAccount{account_ref: "acc_1", amount: 200, currency: "USD"}
          ]
        }),
      command_at_failure:
        Keyword.get(
          opts,
          :command,
          %TestCommand.DebitAccount{account_ref: "acc_1", amount: 200, currency: "USD"}
        ),
      events_at_failure:
        Keyword.get(opts, :events, [
          %TestEvent.AccountDebited{account_ref: "acc_1", amount: 200, new_balance: -100}
        ]),
      state_at_failure: Keyword.get(opts, :state, %{accounts: %{"acc_1" => %{balance: -100}}}),
      model: Keyword.get(opts, :model, nil),
      adapter: Keyword.get(opts, :adapter, nil)
    }
  end

  def create_similar_failure(base, changes \\ []) do
    base
    |> Map.merge(Map.new(changes))
  end

  # ============================================================================
  # Fingerprint Tests
  # ============================================================================

  describe "Fingerprint.from_failure_report/1" do
    test "extracts failure type" do
      report = create_failure_report(failure_type: :invariant_violated)
      fp = Fingerprint.from_failure_report(report)

      assert fp.failure_type == :invariant_violated
    end

    test "extracts check name" do
      report = create_failure_report(check_name: :currency_consistency)
      fp = Fingerprint.from_failure_report(report)

      assert fp.check_name == :currency_consistency
    end

    test "extracts command type" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      assert fp.command_type == TestCommand.DebitAccount
    end

    test "extracts command shape with field types" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      assert fp.command_shape.account_ref == :string
      assert fp.command_shape.amount == :integer
      assert fp.command_shape.currency == :string
    end

    test "extracts event types" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      assert TestEvent.AccountDebited in fp.event_types
    end

    test "extracts sequence length" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      assert fp.sequence_length == 2
    end

    test "extracts sequence shape" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      assert length(fp.sequence_shape) == 2
      assert TestCommand.CreateAccount in fp.sequence_shape
      assert TestCommand.DebitAccount in fp.sequence_shape
    end

    test "extracts state keys" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      assert :accounts in fp.state_keys
    end

    test "categorizes error correctly" do
      check_failure = create_failure_report(failure_type: :check_failed)
      fp = Fingerprint.from_failure_report(check_failure)
      assert fp.error_category == :check_violation

      invariant = create_failure_report(failure_type: :invariant_violated)
      fp = Fingerprint.from_failure_report(invariant)
      assert fp.error_category == :invariant_violation

      precond = create_failure_report(failure_type: :precondition_failed)
      fp = Fingerprint.from_failure_report(precond)
      assert fp.error_category == :precondition_failure
    end

    test "extracts error pattern from message" do
      report = create_failure_report(message: "Balance -123 is negative in account acc_456")
      fp = Fingerprint.from_failure_report(report)

      # Numbers and refs should be normalized
      assert fp.error_pattern =~ "Balance"
      assert fp.error_pattern =~ "negative"
    end
  end

  describe "Fingerprint.hash/1" do
    test "generates consistent hash for same fingerprint" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      hash1 = Fingerprint.hash(fp)
      hash2 = Fingerprint.hash(fp)

      assert hash1 == hash2
    end

    test "generates different hashes for different fingerprints" do
      report1 = create_failure_report(check_name: :check_a)
      report2 = create_failure_report(check_name: :check_b)

      fp1 = Fingerprint.from_failure_report(report1)
      fp2 = Fingerprint.from_failure_report(report2)

      assert Fingerprint.hash(fp1) != Fingerprint.hash(fp2)
    end

    test "short_hash returns 8 characters" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      assert String.length(Fingerprint.short_hash(fp)) == 8
    end
  end

  # ============================================================================
  # Similarity Tests
  # ============================================================================

  describe "Similarity.score/2" do
    test "identical fingerprints have score 1.0" do
      report = create_failure_report()
      fp = Fingerprint.from_failure_report(report)

      score = Similarity.score(fp, fp)
      assert_in_delta score, 1.0, 0.0001
    end

    test "very different fingerprints have low score" do
      report1 =
        create_failure_report(
          failure_type: :check_failed,
          check_name: :balance_non_negative,
          command: %TestCommand.DebitAccount{account_ref: "acc_1", amount: 100, currency: "USD"}
        )

      report2 =
        create_failure_report(
          failure_type: :exception,
          check_name: nil,
          command: %TestCommand.CreateAccount{
            account_ref: "acc_2",
            initial_balance: 0,
            currency: "EUR"
          },
          events: []
        )

      fp1 = Fingerprint.from_failure_report(report1)
      fp2 = Fingerprint.from_failure_report(report2)

      score = Similarity.score(fp1, fp2)
      assert score < 0.5
    end

    test "similar fingerprints have high score" do
      # Same check failure, same command type, just different seed
      report1 = create_failure_report(seed: 111)
      report2 = create_failure_report(seed: 222)

      fp1 = Fingerprint.from_failure_report(report1)
      fp2 = Fingerprint.from_failure_report(report2)

      score = Similarity.score(fp1, fp2)
      assert score >= 0.9
    end
  end

  describe "Similarity.compare/2" do
    test "returns breakdown of similarity components" do
      report1 = create_failure_report()
      report2 = create_failure_report(seed: 999)

      fp1 = Fingerprint.from_failure_report(report1)
      fp2 = Fingerprint.from_failure_report(report2)

      comparison = Similarity.compare(fp1, fp2)

      assert Map.has_key?(comparison, :score)
      assert Map.has_key?(comparison, :breakdown)
      assert Map.has_key?(comparison, :is_similar)

      breakdown = comparison.breakdown
      assert Map.has_key?(breakdown, :failure_type)
      assert Map.has_key?(breakdown, :check_name)
      assert Map.has_key?(breakdown, :command_type)
    end

    test "is_similar reflects threshold comparison" do
      report1 = create_failure_report()
      report2 = create_failure_report(seed: 999)

      fp1 = Fingerprint.from_failure_report(report1)
      fp2 = Fingerprint.from_failure_report(report2)

      comparison = Similarity.compare(fp1, fp2)
      assert comparison.is_similar == true
    end
  end

  describe "Similarity.similar?/2" do
    test "returns true for similar fingerprints" do
      report1 = create_failure_report()
      report2 = create_failure_report(seed: 999)

      fp1 = Fingerprint.from_failure_report(report1)
      fp2 = Fingerprint.from_failure_report(report2)

      assert Similarity.similar?(fp1, fp2)
    end

    test "returns false for dissimilar fingerprints" do
      report1 = create_failure_report(failure_type: :check_failed, check_name: :check_a)
      report2 = create_failure_report(failure_type: :exception, check_name: nil, events: [])

      fp1 = Fingerprint.from_failure_report(report1)
      fp2 = Fingerprint.from_failure_report(report2)

      refute Similarity.similar?(fp1, fp2)
    end

    test "respects custom threshold" do
      report1 = create_failure_report()
      report2 = create_failure_report(check_name: :different_check)

      fp1 = Fingerprint.from_failure_report(report1)
      fp2 = Fingerprint.from_failure_report(report2)

      # May or may not be similar at 0.7, but definitely at 0.3
      assert Similarity.similar?(fp1, fp2, 0.3)
    end
  end

  describe "Similarity.find_similar/3" do
    test "finds similar fingerprints from list" do
      target = create_failure_report(seed: 111)

      others = [
        create_failure_report(seed: 222),
        create_failure_report(seed: 333),
        create_failure_report(failure_type: :exception, check_name: nil, events: [])
      ]

      target_fp = Fingerprint.from_failure_report(target)
      other_fps = Enum.map(others, &Fingerprint.from_failure_report/1)

      results = Similarity.find_similar(target_fp, other_fps)

      # Should find the two similar ones, not the exception
      assert length(results) >= 2
    end

    test "respects limit option" do
      target = create_failure_report(seed: 111)
      others = for i <- 1..10, do: create_failure_report(seed: 200 + i)

      target_fp = Fingerprint.from_failure_report(target)
      other_fps = Enum.map(others, &Fingerprint.from_failure_report/1)

      results = Similarity.find_similar(target_fp, other_fps, limit: 3)

      assert length(results) == 3
    end
  end

  # ============================================================================
  # Patterns Tests
  # ============================================================================

  describe "Patterns.cluster_failures/2" do
    test "clusters similar failures together" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222),
        create_failure_report(seed: 333),
        create_failure_report(failure_type: :exception, check_name: nil, events: [])
      ]

      clusters = Patterns.cluster_failures(failures)

      # Should have at least 2 clusters: one for check failures, one for exception
      assert clusters != []
    end

    test "returns cluster with size and representative" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222)
      ]

      clusters = Patterns.cluster_failures(failures)

      assert clusters != []
      cluster = hd(clusters)

      assert Map.has_key?(cluster, :id)
      assert Map.has_key?(cluster, :fingerprints)
      assert Map.has_key?(cluster, :representative)
      assert Map.has_key?(cluster, :size)
      assert Map.has_key?(cluster, :pattern)
    end
  end

  describe "Patterns.analyze/2" do
    test "returns analysis structure" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222),
        create_failure_report(seed: 333)
      ]

      analysis = Patterns.analyze(failures)

      assert Map.has_key?(analysis, :clusters)
      assert Map.has_key?(analysis, :singleton_count)
      assert Map.has_key?(analysis, :total_failures)
      assert Map.has_key?(analysis, :most_common_pattern)
      assert Map.has_key?(analysis, :pattern_summary)
    end

    test "generates pattern summary" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222)
      ]

      analysis = Patterns.analyze(failures)

      assert is_binary(analysis.pattern_summary)
      assert analysis.pattern_summary =~ "failures"
    end

    test "handles empty failure list" do
      analysis = Patterns.analyze([])

      assert analysis.total_failures == 0
      assert analysis.pattern_summary =~ "No failures"
    end
  end

  describe "Patterns.extract_common_traits/1" do
    test "finds common values across fingerprints" do
      failures = [
        create_failure_report(seed: 111, check_name: :same_check),
        create_failure_report(seed: 222, check_name: :same_check)
      ]

      fingerprints = Enum.map(failures, &Fingerprint.from_failure_report/1)
      traits = Patterns.extract_common_traits(fingerprints)

      assert traits.check_name == :same_check
    end

    test "returns nil for non-common values" do
      failures = [
        create_failure_report(check_name: :check_a),
        create_failure_report(check_name: :check_b)
      ]

      fingerprints = Enum.map(failures, &Fingerprint.from_failure_report/1)
      traits = Patterns.extract_common_traits(fingerprints)

      assert traits.check_name == nil
    end
  end

  # ============================================================================
  # Main API Tests
  # ============================================================================

  describe "FailureIntelligence.fingerprint/1" do
    test "creates fingerprint from failure report" do
      report = create_failure_report()
      fp = FailureIntelligence.fingerprint(report)

      assert %Fingerprint{} = fp
    end
  end

  describe "FailureIntelligence.fingerprint_hash/1" do
    test "returns short hash for failure" do
      report = create_failure_report()
      hash = FailureIntelligence.fingerprint_hash(report)

      assert is_binary(hash)
      assert String.length(hash) == 8
    end
  end

  describe "FailureIntelligence.similarity_score/2" do
    test "returns score between 0 and 1" do
      report1 = create_failure_report(seed: 111)
      report2 = create_failure_report(seed: 222)

      score = FailureIntelligence.similarity_score(report1, report2)

      assert is_float(score)
      assert score >= 0.0
      assert score <= 1.0
    end
  end

  describe "FailureIntelligence.similar?/2" do
    test "detects similar failures" do
      report1 = create_failure_report(seed: 111)
      report2 = create_failure_report(seed: 222)

      assert FailureIntelligence.similar?(report1, report2)
    end

    test "detects dissimilar failures" do
      report1 = create_failure_report(failure_type: :check_failed, check_name: :check_a)
      report2 = create_failure_report(failure_type: :exception, check_name: nil, events: [])

      refute FailureIntelligence.similar?(report1, report2)
    end
  end

  describe "FailureIntelligence.compare/2" do
    test "returns detailed comparison" do
      report1 = create_failure_report()
      report2 = create_failure_report(seed: 999)

      comparison = FailureIntelligence.compare(report1, report2)

      assert Map.has_key?(comparison, :score)
      assert Map.has_key?(comparison, :breakdown)
      assert Map.has_key?(comparison, :is_similar)
    end
  end

  describe "FailureIntelligence.find_similar/3" do
    test "finds similar failures from list" do
      target = create_failure_report(seed: 111)

      failures = [
        create_failure_report(seed: 222),
        create_failure_report(seed: 333),
        create_failure_report(failure_type: :exception, check_name: nil, events: [])
      ]

      results = FailureIntelligence.find_similar(target, failures)

      assert is_list(results)
      # Each result is {failure, score}
      Enum.each(results, fn {failure, score} ->
        assert %FailureReport{} = failure
        assert is_float(score)
      end)
    end
  end

  describe "FailureIntelligence.analyze/2" do
    test "analyzes failures and returns patterns" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222),
        create_failure_report(seed: 333)
      ]

      analysis = FailureIntelligence.analyze(failures)

      assert Map.has_key?(analysis, :clusters)
      assert Map.has_key?(analysis, :pattern_summary)
    end
  end

  describe "FailureIntelligence.cluster/2" do
    test "clusters failures by similarity" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222)
      ]

      clusters = FailureIntelligence.cluster(failures)

      assert is_list(clusters)
    end
  end

  describe "FailureIntelligence.summary/1" do
    test "returns summary string" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222)
      ]

      summary = FailureIntelligence.summary(failures)

      assert is_binary(summary)
      assert summary =~ "failure"
    end
  end

  describe "FailureIntelligence.find_duplicates/1" do
    test "finds highly similar failures" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222),
        create_failure_report(seed: 333)
      ]

      duplicates = FailureIntelligence.find_duplicates(failures)

      assert is_list(duplicates)
      # Each duplicate is {f1, f2, score}
      Enum.each(duplicates, fn {f1, f2, score} ->
        assert %FailureReport{} = f1
        assert %FailureReport{} = f2
        assert score >= 0.90
      end)
    end
  end

  describe "FailureIntelligence.group_by_fingerprint/1" do
    test "groups failures by fingerprint hash" do
      failures = [
        create_failure_report(seed: 111),
        create_failure_report(seed: 222),
        create_failure_report(failure_type: :exception, check_name: nil, events: [])
      ]

      groups = FailureIntelligence.group_by_fingerprint(failures)

      assert is_map(groups)
      # Each group has failures with same fingerprint hash
      Enum.each(groups, fn {hash, group} ->
        assert is_binary(hash)
        assert is_list(group)
      end)
    end
  end

  # ============================================================================
  # Verification Tests
  # ============================================================================

  describe "FailureIntelligence.Verification" do
    alias PropertyDamage.FailureIntelligence.Verification

    test "format_result generates readable output" do
      result = %{
        status: :verified,
        original_seed: 12_345,
        original_passes: true,
        variations_run: 10,
        variations_passed: 10,
        variations_failed: 0,
        failed_variations: [],
        similar_failures: [],
        confidence: 1.0,
        summary: "Fix verified!"
      }

      output = Verification.format_result(result)

      assert output =~ "verified"
      assert output =~ "12345"
      assert output =~ "100"
    end

    test "format_result shows status icon" do
      verified = %{
        status: :verified,
        original_seed: 1,
        original_passes: true,
        variations_run: 1,
        variations_passed: 1,
        variations_failed: 0,
        failed_variations: [],
        similar_failures: [],
        confidence: 1.0,
        summary: ""
      }

      assert Verification.format_result(verified) =~ "✓"

      failing = %{verified | status: :still_failing}
      assert Verification.format_result(failing) =~ "✗"

      partial = %{verified | status: :partially_fixed}
      assert Verification.format_result(partial) =~ "⚠"

      flaky = %{verified | status: :flaky}
      assert Verification.format_result(flaky) =~ "?"
    end
  end
end
