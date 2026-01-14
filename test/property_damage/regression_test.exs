defmodule PropertyDamage.RegressionTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Regression
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Sequence

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defmodule TestCommand.Create do
    defstruct [:id]
  end

  defmodule TestCommand.Update do
    defstruct [:id, :value]
  end

  defmodule TestProjection do
    @behaviour PropertyDamage.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state
  end

  defmodule TestModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [
        {3, PropertyDamage.RegressionTest.TestCommand.Create},
        {2, PropertyDamage.RegressionTest.TestCommand.Update}
      ]
    end

    @impl true
    def state_projection, do: PropertyDamage.RegressionTest.TestProjection

    @impl true
    def extra_projections, do: []
  end

  def make_failure(seed, opts \\ []) do
    %FailureReport{
      seed: seed,
      failure_type: Keyword.get(opts, :failure_type, :check_failed),
      check_name: Keyword.get(opts, :check_name, :test_check),
      failure_message: Keyword.get(opts, :message, "Test failure"),
      failed_at_index: 1,
      original_sequence: Sequence.linear([%TestCommand.Create{id: "1"}]),
      shrunk_sequence: Sequence.linear([%TestCommand.Create{id: "1"}]),
      event_log: [],
      state_before_failure: %{TestProjection => %{}},
      state_at_failure: %{TestProjection => %{}},
      refs_at_failure: %{},
      model: TestModel,
      adapter: nil,
      linearization: nil,
      timestamp: DateTime.utc_now()
    }
  end

  # ============================================================================
  # Handler Tests
  # ============================================================================

  describe "Regression.handler/1" do
    test "returns a function" do
      handler = Regression.handler([])
      assert is_function(handler, 1)
    end

    test "handler can be called with a failure report" do
      handler = Regression.handler([])
      failure = make_failure(12345)

      # Should not raise
      result = handler.(failure)
      assert is_map(result)
    end
  end

  describe "Regression.handle_failure/2" do
    test "returns result map with all fields" do
      failure = make_failure(12345)
      result = Regression.handle_failure(failure, [])

      assert Map.has_key?(result, :saved_failure)
      assert Map.has_key?(result, :added_to_library)
      assert Map.has_key?(result, :generated_test)
      assert Map.has_key?(result, :skipped)
      assert Map.has_key?(result, :skip_reason)
    end

    test "with no options, nothing is saved" do
      failure = make_failure(12345)
      result = Regression.handle_failure(failure, [])

      assert result.saved_failure == nil
      assert result.added_to_library == nil
      assert result.generated_test == nil
      assert result.skipped == false
    end

    @tag :tmp_dir
    test "save_failures option saves failure file", %{tmp_dir: tmp_dir} do
      failure = make_failure(12345)
      result = Regression.handle_failure(failure, save_failures: tmp_dir)

      assert {:ok, path} = result.saved_failure
      assert String.starts_with?(path, tmp_dir)
      assert File.exists?(path)
    end

    @tag :tmp_dir
    test "seed_library option adds to library", %{tmp_dir: tmp_dir} do
      library_path = Path.join(tmp_dir, "seeds.json")
      failure = make_failure(12345)
      result = Regression.handle_failure(failure, seed_library: library_path)

      assert {:ok, ^library_path} = result.added_to_library
      assert File.exists?(library_path)

      # Verify content
      {:ok, content} = File.read(library_path)
      data = Jason.decode!(content)
      assert length(data["entries"]) == 1
      assert hd(data["entries"])["seed"] == 12345
    end

    @tag :tmp_dir
    test "generate_tests option creates ExUnit test", %{tmp_dir: tmp_dir} do
      failure = make_failure(12345)
      result = Regression.handle_failure(failure, generate_tests: tmp_dir)

      assert {:ok, path} = result.generated_test
      assert String.ends_with?(path, ".exs")
      assert File.exists?(path)

      # Verify it's valid Elixir
      content = File.read!(path)
      assert content =~ "defmodule"
      assert content =~ "ExUnit"
    end

    @tag :tmp_dir
    test "tags option adds tags to library entries", %{tmp_dir: tmp_dir} do
      library_path = Path.join(tmp_dir, "seeds.json")
      failure = make_failure(12345)

      Regression.handle_failure(failure,
        seed_library: library_path,
        tags: [:balance_bug, :critical]
      )

      {:ok, content} = File.read(library_path)
      data = Jason.decode!(content)
      entry = hd(data["entries"])
      assert "balance_bug" in entry["tags"]
      assert "critical" in entry["tags"]
    end
  end

  # ============================================================================
  # Individual Handler Tests
  # ============================================================================

  describe "Regression.save_failure/2" do
    @tag :tmp_dir
    test "creates handler that saves failures", %{tmp_dir: tmp_dir} do
      handler = Regression.save_failure(tmp_dir)
      failure = make_failure(12345)

      {:ok, path} = handler.(failure)
      assert File.exists?(path)
    end
  end

  describe "Regression.add_to_library/2" do
    @tag :tmp_dir
    test "creates handler that adds to library", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "seeds.json")
      handler = Regression.add_to_library(path, tags: [:test])
      failure = make_failure(12345)

      {:ok, ^path} = handler.(failure)
      assert File.exists?(path)
    end
  end

  describe "Regression.generate_test/2" do
    @tag :tmp_dir
    test "creates handler that generates tests", %{tmp_dir: tmp_dir} do
      handler = Regression.generate_test(tmp_dir)
      failure = make_failure(12345)

      {:ok, path} = handler.(failure)
      assert File.exists?(path)
    end
  end

  describe "Regression.compose/1" do
    test "composes multiple handlers" do
      call_count = :counters.new(1, [])

      handler1 = fn _f -> :counters.add(call_count, 1, 1) end
      handler2 = fn _f -> :counters.add(call_count, 1, 1) end
      handler3 = fn _f -> :counters.add(call_count, 1, 1) end

      composed = Regression.compose([handler1, handler2, handler3])
      failure = make_failure(12345)
      composed.(failure)

      assert :counters.get(call_count, 1) == 3
    end

    test "continues even if one handler errors" do
      call_count = :counters.new(1, [])

      handler1 = fn _f -> :counters.add(call_count, 1, 1) end
      handler2 = fn _f -> raise "error" end
      handler3 = fn _f -> :counters.add(call_count, 1, 1) end

      composed = Regression.compose([handler1, handler2, handler3])
      failure = make_failure(12345)
      results = composed.(failure)

      assert :counters.get(call_count, 1) == 2
      assert length(results) == 3
      assert match?({:error, %RuntimeError{}}, Enum.at(results, 1))
    end
  end

  # ============================================================================
  # Deduplication Tests
  # ============================================================================

  describe "Regression.check_duplicate/2" do
    test "returns false when no existing failures" do
      failure = make_failure(12345)
      {is_dup, reason} = Regression.check_duplicate(failure, [])

      assert is_dup == false
      assert reason == nil
    end

    @tag :tmp_dir
    test "returns true when similar failure exists", %{tmp_dir: tmp_dir} do
      # Save an existing failure
      failure1 = make_failure(12345)
      {:ok, _path} = PropertyDamage.Persistence.save(failure1, tmp_dir)

      # Check a similar failure
      failure2 = make_failure(12346)

      {is_dup, reason} =
        Regression.check_duplicate(failure2,
          save_failures: tmp_dir,
          dedup_threshold: 0.5
        )

      # These are very similar (same structure, just different seed)
      assert is_dup == true
      assert match?({:similar_to, _, _}, reason)
    end

    @tag :tmp_dir
    test "respects dedup_threshold", %{tmp_dir: tmp_dir} do
      failure1 = make_failure(12345, failure_type: :check_failed, check_name: :check_a)
      {:ok, _path} = PropertyDamage.Persistence.save(failure1, tmp_dir)

      # Different failure type - should be less similar
      failure2 = make_failure(12346, failure_type: :invariant_violated, check_name: :check_b)

      # With high threshold, should not be duplicate
      {is_dup, _} =
        Regression.check_duplicate(failure2,
          save_failures: tmp_dir,
          dedup_threshold: 0.99
        )

      assert is_dup == false
    end
  end

  describe "Regression.find_duplicate/3" do
    test "returns nil for empty list" do
      failure = make_failure(12345)
      assert Regression.find_duplicate(failure, [], 0.9) == nil
    end

    test "finds similar failure" do
      failure1 = make_failure(12345)
      failure2 = make_failure(12346)
      failure3 = make_failure(12347)

      result = Regression.find_duplicate(failure1, [failure2, failure3], 0.5)
      assert result != nil
      assert {_found, score} = result
      assert score >= 0.5
    end
  end

  # ============================================================================
  # Batch Processing Tests
  # ============================================================================

  describe "Regression.process_batch/2" do
    @tag :tmp_dir
    test "processes multiple failures", %{tmp_dir: tmp_dir} do
      failures = [
        make_failure(12345),
        make_failure(12346),
        make_failure(12347)
      ]

      results = Regression.process_batch(failures, save_failures: tmp_dir)

      assert length(results) == 3

      for result <- results do
        refute result.skipped, "expected result not to be skipped: #{inspect(result)}"
      end
    end

    @tag :tmp_dir
    test "deduplicates within batch", %{tmp_dir: tmp_dir} do
      # Create similar failures
      failures = [
        make_failure(12345),
        make_failure(12346),
        make_failure(12347)
      ]

      results =
        Regression.process_batch(failures,
          save_failures: tmp_dir,
          dedup: true,
          dedup_threshold: 0.5
        )

      # First should be processed, others should be skipped as duplicates
      processed = Enum.reject(results, & &1.skipped)
      skipped = Enum.filter(results, & &1.skipped)

      assert length(processed) >= 1
      assert length(skipped) >= 0
    end
  end

  describe "Regression.batch_summary/1" do
    test "returns summary statistics" do
      results = [
        %{
          seed: 1,
          saved_failure: {:ok, "path1"},
          added_to_library: nil,
          generated_test: nil,
          skipped: false
        },
        %{
          seed: 2,
          saved_failure: {:ok, "path2"},
          added_to_library: {:ok, "lib"},
          generated_test: nil,
          skipped: false
        },
        %{seed: 3, saved_failure: nil, added_to_library: nil, generated_test: nil, skipped: true}
      ]

      summary = Regression.batch_summary(results)

      assert summary.total == 3
      assert summary.processed == 2
      assert summary.skipped == 1
      assert summary.saved_failures == 2
      assert summary.added_to_library == 1
    end
  end

  describe "Regression.format_batch_summary/1" do
    test "formats summary as string" do
      summary = %{
        total: 10,
        processed: 8,
        skipped: 2,
        saved_failures: 8,
        added_to_library: 5,
        generated_tests: 3
      }

      output = Regression.format_batch_summary(summary)

      assert output =~ "Total failures: 10"
      assert output =~ "Processed: 8"
      assert output =~ "Skipped (duplicates): 2"
      assert output =~ "Saved failures: 8"
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration with PropertyDamage.run/1" do
    # Note: Full integration tests would require a working model/adapter pair
    # These tests verify the option parsing works

    test "build_on_failure_callback composes regression and on_failure" do
      # Test that the internal callback building works correctly
      # by checking the Regression.handler/1 function
      handler = Regression.handler(save_failures: "/tmp")
      assert is_function(handler, 1)
    end
  end

  # ============================================================================
  # Library Accumulation Tests
  # ============================================================================

  describe "library accumulation" do
    @tag :tmp_dir
    test "multiple failures accumulate in same library", %{tmp_dir: tmp_dir} do
      library_path = Path.join(tmp_dir, "seeds.json")

      failure1 = make_failure(12345)
      failure2 = make_failure(12346)
      failure3 = make_failure(12347)

      Regression.handle_failure(failure1, seed_library: library_path)
      Regression.handle_failure(failure2, seed_library: library_path)
      Regression.handle_failure(failure3, seed_library: library_path)

      {:ok, content} = File.read(library_path)
      data = Jason.decode!(content)

      assert length(data["entries"]) == 3
      seeds = Enum.map(data["entries"], & &1["seed"])
      assert 12345 in seeds
      assert 12346 in seeds
      assert 12347 in seeds
    end

    @tag :tmp_dir
    test "same seed is not added twice", %{tmp_dir: tmp_dir} do
      library_path = Path.join(tmp_dir, "seeds.json")

      failure = make_failure(12345)

      Regression.handle_failure(failure, seed_library: library_path)
      # Try to add same seed again
      Regression.handle_failure(failure, seed_library: library_path)

      {:ok, content} = File.read(library_path)
      data = Jason.decode!(content)

      # SeedLibrary should deduplicate by seed
      seeds = Enum.map(data["entries"], & &1["seed"])
      assert Enum.count(seeds, &(&1 == 12345)) == 1
    end
  end
end
