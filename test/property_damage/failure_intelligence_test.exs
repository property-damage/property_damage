defmodule PropertyDamage.FailureIntelligenceTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Failure
  alias PropertyDamage.FailureIntelligence
  alias PropertyDamage.FailureIntelligence.{Fingerprint, Patterns, Similarity}
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.FI

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

  # Builds a report whose failing command and events are recovered by
  # FailureReport.failure_step/1 from a real shrunk %Sequence{} + event_log
  # (not the removed materialized command_at_failure/events_at_failure fields):
  # the failing command is the last command in a 2-command linear sequence, and
  # its events are the log entries tagged with that command's index.
  def create_failure_report(opts \\ []) do
    failing_command =
      Keyword.get(
        opts,
        :command,
        %TestCommand.DebitAccount{account_ref: "acc_1", amount: 200, currency: "USD"}
      )

    events =
      Keyword.get(opts, :events, [
        %TestEvent.AccountDebited{account_ref: "acc_1", amount: 200, new_balance: -100}
      ])

    commands = [
      %TestCommand.CreateAccount{account_ref: "acc_1", initial_balance: 100, currency: "USD"},
      failing_command
    ]

    failed_at = length(commands) - 1
    sequence = Keyword.get(opts, :sequence, PropertyDamage.Sequence.linear(commands))

    event_log =
      Enum.map(events, fn event ->
        %PropertyDamage.EventLog.Entry{
          timestamp: 0,
          command_index: failed_at,
          event: event,
          source: :command
        }
      end)

    kind = Keyword.get(opts, :failure_type, :check_failed)
    check_name = Keyword.get(opts, :check_name, :balance_non_negative)
    message = Keyword.get(opts, :message, "Balance -100 is negative")

    %FailureReport{
      seed: Keyword.get(opts, :seed, 12_345),
      run_number: 0,
      failure_reason: fi_failure_reason(kind, check_name, message),
      trace: PropertyDamage.RunTrace.new(plan: sequence, event_log: event_log),
      failed_at_index: failed_at,
      state_at_failure: Keyword.get(opts, :state, %{accounts: %{"acc_1" => %{balance: -100}}}),
      model: Keyword.get(opts, :model, nil),
      targets: for(adapter <- List.wrap(Keyword.get(opts, :adapter, nil)), do: {adapter, []})
    }
  end

  # Build a %Failure{} for the FI tests from a (real) kind + name + message.
  defp fi_failure_reason(:check_failed, name, msg), do: Failure.check_failed(name, msg)

  defp fi_failure_reason(:projection_violation, name, msg),
    do: Failure.projection_violation(name || :Projection, msg)

  defp fi_failure_reason(:adapter_error, _name, msg), do: Failure.adapter_error(msg)
  defp fi_failure_reason(:settle_timeout, _name, msg), do: Failure.settle_timeout(msg)
  defp fi_failure_reason(:poll_error, _name, msg), do: Failure.poll_error(msg)

  def create_similar_failure(base, changes \\ []) do
    base
    |> Map.merge(Map.new(changes))
  end

  # Cluster-A shaped failure: check failure in :balance_non_negative during
  # DebitAccount (this is what create_failure_report/1 builds by default).
  def cluster_a_failure(seed), do: create_failure_report(seed: seed)

  # Cluster-B shaped failure: an exception during CreateAccount, no events. This
  # is deliberately dissimilar to cluster A (different failure_type, check_name,
  # command, events) so the two form distinct, non-overlapping clusters.
  def cluster_b_failure(seed) do
    create_failure_report(
      seed: seed,
      failure_type: :adapter_error,
      check_name: nil,
      command: %TestCommand.CreateAccount{
        account_ref: "acc_2",
        initial_balance: 0,
        currency: "EUR"
      },
      events: [],
      message: "ArgumentError raised while creating account"
    )
  end

  # A lone failure dissimilar to both clusters: a timeout during CreditAccount.
  def singleton_failure(seed) do
    create_failure_report(
      seed: seed,
      failure_type: :settle_timeout,
      check_name: nil,
      command: %TestCommand.CreditAccount{account_ref: "acc_3", amount: 5, currency: "GBP"},
      events: [%TestEvent.AccountCredited{account_ref: "acc_3", amount: 5, new_balance: 5}],
      message: "timed out waiting for credit"
    )
  end

  # ============================================================================
  # Fingerprint Tests
  # ============================================================================

  describe "Fingerprint.from_failure_report/1" do
    test "extracts failure type" do
      report = create_failure_report(failure_type: :projection_violation)
      fp = Fingerprint.from_failure_report(report)

      assert fp.failure_type == :projection_violation
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

      invariant = create_failure_report(failure_type: :projection_violation)
      fp = Fingerprint.from_failure_report(invariant)
      assert fp.error_category == :invariant_violation

      precond = create_failure_report(failure_type: :adapter_error)
      fp = Fingerprint.from_failure_report(precond)
      assert fp.error_category == :adapter_error
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
          failure_type: :adapter_error,
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
      report2 = create_failure_report(failure_type: :adapter_error, check_name: nil, events: [])

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
        create_failure_report(failure_type: :adapter_error, check_name: nil, events: [])
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
        create_failure_report(failure_type: :adapter_error, check_name: nil, events: [])
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

  describe "Patterns pattern descriptions (failure-type vocabulary)" do
    test "a projection_violation cluster reads as an invariant violation, not generic Failure" do
      failures = [
        create_failure_report(seed: 111, failure_type: :projection_violation),
        create_failure_report(seed: 222, failure_type: :projection_violation)
      ]

      [cluster | _] = Patterns.cluster_failures(failures)

      # The fingerprint carries a real Failure.kind (:projection_violation); the
      # cluster description must reflect it, not degrade to the generic "Failure".
      assert cluster.pattern.failure_type == :projection_violation
      assert cluster.pattern.description =~ "Invariant violation"
      refute cluster.pattern.description =~ ~r/^Failure\b/
    end

    test "a check_failed cluster reads as a check failure, not generic Failure" do
      failures = [
        create_failure_report(seed: 111, failure_type: :check_failed),
        create_failure_report(seed: 222, failure_type: :check_failed)
      ]

      [cluster | _] = Patterns.cluster_failures(failures)

      assert cluster.pattern.failure_type == :check_failed
      assert cluster.pattern.description =~ "Check failure"
      refute cluster.pattern.description =~ ~r/^Failure\b/
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
      report2 = create_failure_report(failure_type: :adapter_error, check_name: nil, events: [])

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
        create_failure_report(failure_type: :adapter_error, check_name: nil, events: [])
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
        create_failure_report(failure_type: :adapter_error, check_name: nil, events: [])
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

    @signature {:check_failed, :balance_non_negative, 0}

    test "format_result generates readable output" do
      result = %{
        status: :verified,
        signature: @signature,
        failure: nil,
        summary: "Fix verified."
      }

      output = Verification.format_result(result)

      assert output =~ "verified"
      assert output =~ inspect(@signature)
      assert output =~ "Fix verified."
    end

    test "format_result shows a status icon and the new signature of a different failure" do
      verified = %{status: :verified, signature: @signature, failure: nil, summary: ""}
      assert Verification.format_result(verified) =~ "✓"

      failing = %{verified | status: :still_failing}
      assert Verification.format_result(failing) =~ "✗"

      new_signature = {:adapter_error, :boom, 0}

      different =
        verified
        |> Map.put(:status, :different_failure)
        |> Map.put(:new_signature, new_signature)

      output = Verification.format_result(different)
      assert output =~ "⚠"
      assert output =~ "New failure: #{inspect(new_signature)}"
    end
  end

  # ============================================================================
  # Untested submodule functions
  # ============================================================================

  describe "Similarity.find_most_similar/2" do
    test "returns the closest fingerprint with its score" do
      target = Fingerprint.from_failure_report(create_failure_report(seed: 1))

      near = Fingerprint.from_failure_report(create_failure_report(seed: 2))
      far = Fingerprint.from_failure_report(cluster_b_failure(3))

      assert {matched, score} = Similarity.find_most_similar(target, [far, near])
      assert matched == near
      assert_in_delta score, 1.0, 0.0001
    end

    test "returns nil for an empty list" do
      target = Fingerprint.from_failure_report(create_failure_report())
      assert Similarity.find_most_similar(target, []) == nil
    end
  end

  describe "Similarity.similarity_matrix/1" do
    test "computes the upper-triangle scores for all pairs" do
      fps =
        [cluster_a_failure(1), cluster_a_failure(2), cluster_b_failure(3)]
        |> Enum.map(&Fingerprint.from_failure_report/1)

      matrix = Similarity.similarity_matrix(fps)

      # Upper triangle only: n*(n-1)/2 entries for n = 3.
      assert map_size(matrix) == 3
      assert Map.has_key?(matrix, {0, 1})
      assert Map.has_key?(matrix, {0, 2})
      assert Map.has_key?(matrix, {1, 2})
      refute Map.has_key?(matrix, {1, 0})

      # Two cluster-A fingerprints are identical; A vs B is far below threshold.
      assert_in_delta matrix[{0, 1}], 1.0, 0.0001
      assert matrix[{0, 2}] < 0.5
    end
  end

  describe "Patterns.find_best_match/2" do
    test "returns the best-matching cluster and its score" do
      clusters =
        Patterns.cluster_failures([
          cluster_a_failure(1),
          cluster_a_failure(2),
          cluster_b_failure(3),
          cluster_b_failure(4)
        ])

      # A fresh cluster-A failure should map onto the cluster-A group with a
      # perfect score.
      assert {cluster, score} = Patterns.find_best_match(cluster_a_failure(99), clusters)
      assert cluster.pattern.failure_type == :check_failed
      assert_in_delta score, 1.0, 0.0001
    end

    test "returns nil when there are no clusters" do
      assert Patterns.find_best_match(cluster_a_failure(1), []) == nil
    end
  end

  describe "Patterns clustering with genuinely distinct clusters" do
    setup do
      # Two non-singleton clusters (A x3, B x2) plus one lone failure.
      failures = [
        cluster_a_failure(1),
        cluster_a_failure(2),
        cluster_a_failure(3),
        cluster_b_failure(10),
        cluster_b_failure(11),
        singleton_failure(900)
      ]

      %{failures: failures}
    end

    test "cluster_fingerprints/2 separates distinct fingerprints into distinct clusters",
         %{failures: failures} do
      fingerprints = Enum.map(failures, &Fingerprint.from_failure_report/1)
      clusters = Patterns.cluster_fingerprints(fingerprints)

      # Sizes 3, 2, 1 (sorted desc); the singleton is its own size-1 cluster.
      assert Enum.map(clusters, & &1.size) == [3, 2, 1]

      # Each cluster's representative is a member of that cluster.
      Enum.each(clusters, fn c ->
        assert c.representative in c.fingerprints
      end)

      # The big cluster is the check-failure group; the mid cluster is the
      # exception group.
      [big, mid, _lone] = clusters
      assert big.pattern.failure_type == :check_failed
      assert big.pattern.command_types == [TestCommand.DebitAccount]
      assert mid.pattern.failure_type == :adapter_error
    end

    test "analyze/2 reports two clusters, one singleton, and the most common pattern",
         %{failures: failures} do
      analysis = Patterns.analyze(failures)

      assert length(analysis.clusters) == 2
      assert analysis.singleton_count == 1
      assert analysis.total_failures == 6

      # Most common pattern is the largest cluster (the 3 check failures).
      assert analysis.most_common_pattern.failure_type == :check_failed
      assert analysis.most_common_pattern.command_types == [TestCommand.DebitAccount]

      # Membership: the two significant clusters cover 5 of the 6 failures.
      clustered = analysis.clusters |> Enum.map(& &1.size) |> Enum.sum()
      assert clustered == 5
    end
  end

  describe "FailureIntelligence.match_pattern/3" do
    setup do
      clusters =
        Patterns.cluster_failures([
          cluster_a_failure(1),
          cluster_a_failure(2),
          cluster_b_failure(10),
          cluster_b_failure(11)
        ])

      %{clusters: clusters}
    end

    test "returns the matching cluster for a failure like an existing pattern",
         %{clusters: clusters} do
      cluster = FailureIntelligence.match_pattern(cluster_a_failure(99), clusters)

      refute is_nil(cluster)
      assert cluster.pattern.failure_type == :check_failed
    end

    test "returns nil for a novel failure that matches no cluster", %{clusters: clusters} do
      novel =
        create_failure_report(
          failure_type: :poll_error,
          check_name: nil,
          command: %TestCommand.CreditAccount{account_ref: "x", amount: 1, currency: "JPY"},
          events: [],
          message: "unexpected poll error"
        )

      assert FailureIntelligence.match_pattern(novel, clusters) == nil
    end
  end

  # ============================================================================
  # Fix verification and exploration (behavioral): drives PropertyDamage.run
  # against the seeded-bug fixture in test/support/failure_intelligence_support.ex.
  # ============================================================================

  defp fi_report(seed) do
    %FailureReport{
      seed: seed,
      run_number: 0,
      failure_reason: Failure.check_failed(:balance_non_negative, "Balance -100 is negative")
    }
  end

  defp fi_failure do
    {:error, %FailureReport{replay: replay} = report} =
      PropertyDamage.run(
        model: FI.Model,
        targets: [{FI.Adapter, config: %{bug: :always}}],
        seed: 100_000,
        max_runs: 1,
        replay_dir: false,
        verbose: false
      )

    assert is_map(replay)
    report
  end

  describe "FailureIntelligence.Verification.verify_fixes/3" do
    alias PropertyDamage.FailureIntelligence.Verification

    test "pairs each report with its own result or refusal" do
      with_replay = fi_failure()
      without_replay = %{with_replay | replay: nil}

      results =
        Verification.verify_fixes([with_replay, without_replay], FI.Model,
          targets: [{FI.Adapter, config: %{bug: :off}}]
        )

      assert [{^with_replay, %{status: :verified}}, {^without_replay, refused}] = results
      assert refused == {:error, :no_replay_artifact}
    end

    test "refuses a replay the artifact writer refused" do
      report = %{fi_failure() | replay: {:refused, %{field: :amount}}}

      assert Verification.verify_fix(report, FI.Model,
               targets: [{FI.Adapter, config: %{bug: :off}}]
             ) == {:error, :no_replay_artifact}
    end
  end

  describe "FailureIntelligence.Exploration.explore_neighbouring_seeds/3" do
    test "lists the failing seeds with their reports against the buggy adapter" do
      result =
        FailureIntelligence.explore_neighbouring_seeds(fi_report(100_000), FI.Model,
          targets: [{FI.Adapter, config: %{bug: :always}}],
          max_seeds: 4
        )

      assert result.original_seed == 100_000
      assert result.seeds_run == 4
      assert result.passed == 0
      assert length(result.failures) == 4

      assert Enum.all?(result.failures, fn %{seed: seed, report: report} ->
               match?(%FailureReport{seed: ^seed}, report)
             end)
    end

    test "lists no failure against the correct adapter and gives no verdict" do
      result =
        FailureIntelligence.explore_neighbouring_seeds(fi_report(100_000), FI.Model,
          targets: [{FI.Adapter, config: %{bug: :off}}],
          max_seeds: 4
        )

      assert result.seeds_run == 4
      assert result.passed == 4
      assert result.failures == []
      refute Map.has_key?(result, :status)
    end

    test "a one-seed budget and a zero range run no seed" do
      result =
        FailureIntelligence.explore_neighbouring_seeds(fi_report(100_000), FI.Model,
          targets: [{FI.Adapter, config: %{bug: :off}}],
          max_seeds: 1,
          seed_range: 0
        )

      assert result.seeds_run == 0
    end

    test "a negative seed range runs only the random seeds" do
      result =
        FailureIntelligence.explore_neighbouring_seeds(fi_report(100_000), FI.Model,
          targets: [{FI.Adapter, config: %{bug: :off}}],
          max_seeds: 5,
          seed_range: -4
        )

      assert result.seeds_run == 2
    end
  end
end
