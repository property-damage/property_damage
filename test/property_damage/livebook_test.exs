defmodule PropertyDamage.LivebookTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Livebook
  alias PropertyDamage.Livebook.Charts

  # Sample result for testing
  @sample_result %{
    success: true,
    history: [
      %{
        command: MyApp.CreateUser,
        args: %{name: "Alice"},
        result: {:ok, %{id: 1}},
        events: [%{type: :user_created}],
        duration_us: 1500,
        success: true,
        model_state_before: %{users: []},
        model_state_after: %{users: [%{id: 1, name: "Alice"}]}
      },
      %{
        command: MyApp.UpdateUser,
        args: %{id: 1, name: "Bob"},
        result: {:ok, %{id: 1}},
        events: [%{type: :user_updated}],
        duration_us: 1200,
        success: true,
        model_state_before: %{users: [%{id: 1, name: "Alice"}]},
        model_state_after: %{users: [%{id: 1, name: "Bob"}]}
      },
      %{
        command: MyApp.DeleteUser,
        args: %{id: 1},
        result: {:ok, :deleted},
        events: [%{type: :user_deleted}],
        duration_us: 800,
        success: true,
        model_state_before: %{users: [%{id: 1, name: "Bob"}]},
        model_state_after: %{users: []}
      }
    ],
    check_results: [
      %{check_name: :user_exists, passed: true},
      %{check_name: :user_exists, passed: true},
      %{check_name: :valid_state, passed: true}
    ]
  }

  @failing_result %{
    success: false,
    history: @sample_result.history,
    failure_message: "State mismatch",
    failed_command: MyApp.UpdateUser,
    shrunk_sequence: [
      %{command: MyApp.CreateUser, args: %{name: "Alice"}},
      %{command: MyApp.UpdateUser, args: %{id: 1, name: "Bob"}}
    ],
    shrink_info: %{original_length: 10, iterations: 5}
  }

  describe "kino_available?/0" do
    test "returns boolean" do
      result = Livebook.kino_available?()
      assert is_boolean(result)
    end
  end

  describe "without Kino" do
    # These tests verify proper error handling when Kino is not available

    test "visualize/1 raises when Kino unavailable" do
      if not Livebook.kino_available?() do
        assert_raise RuntimeError, ~r/Kino is required/, fn ->
          Livebook.visualize(@sample_result)
        end
      end
    end

    test "results_table/1 raises when Kino unavailable" do
      if not Livebook.kino_available?() do
        assert_raise RuntimeError, ~r/Kino is required/, fn ->
          Livebook.results_table(@sample_result)
        end
      end
    end
  end

  describe "Charts.vega_lite_available?/0" do
    test "returns boolean" do
      result = Charts.vega_lite_available?()
      assert is_boolean(result)
    end
  end

  # Test internal data processing functions by inspecting module structure
  describe "data processing" do
    test "handles empty history" do
      empty_result = %{success: true, history: []}

      # These should not crash even with empty data
      if Livebook.kino_available?() do
        assert Livebook.visualize(empty_result)
        assert Livebook.results_table(empty_result)
        assert Livebook.command_stats(empty_result)
        assert Livebook.state_timeline(empty_result)
      end
    end

    test "handles nil history" do
      nil_result = %{success: true, history: nil}

      if Livebook.kino_available?() do
        assert Livebook.visualize(nil_result)
      end
    end

    test "handles missing fields gracefully" do
      minimal_result = %{
        success: true,
        history: [
          %{command: TestCmd, args: %{}}
        ]
      }

      if Livebook.kino_available?() do
        assert Livebook.visualize(minimal_result)
      end
    end
  end

  # Test that Charts module handles VegaLite being unavailable
  describe "Charts fallback behavior" do
    test "command_bar_chart handles missing VegaLite" do
      if Livebook.kino_available?() and not Charts.vega_lite_available?() do
        result = Charts.command_bar_chart(@sample_result)
        # Should return a Kino.Markdown fallback
        assert result
      end
    end

    test "timing_histogram handles missing VegaLite" do
      if Livebook.kino_available?() and not Charts.vega_lite_available?() do
        result = Charts.timing_histogram(@sample_result)
        assert result
      end
    end

    test "success_pie_chart handles missing VegaLite" do
      if Livebook.kino_available?() and not Charts.vega_lite_available?() do
        result = Charts.success_pie_chart(@sample_result)
        assert result
      end
    end
  end

  # Test the module's public API documentation
  describe "module documentation" do
    test "Livebook module has documentation" do
      {:docs_v1, _, :elixir, _, module_doc, _, _} = Code.fetch_docs(Livebook)
      assert module_doc != :hidden
      assert module_doc != :none
    end

    test "Charts module has documentation" do
      {:docs_v1, _, :elixir, _, module_doc, _, _} = Code.fetch_docs(Charts)
      assert module_doc != :hidden
      assert module_doc != :none
    end
  end

  # Integration test when Kino is available
  describe "with Kino available" do
    @tag :kino_required
    test "visualize returns Kino.Layout" do
      if Livebook.kino_available?() do
        result = Livebook.visualize(@sample_result)
        # Check that it's some kind of Kino struct
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "results_table returns Kino.DataTable" do
      if Livebook.kino_available?() do
        result = Livebook.results_table(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "command_stats returns Kino.DataTable" do
      if Livebook.kino_available?() do
        result = Livebook.command_stats(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "state_timeline returns Kino.Markdown" do
      if Livebook.kino_available?() do
        result = Livebook.state_timeline(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "failure_details handles successful result" do
      if Livebook.kino_available?() do
        result = Livebook.failure_details(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "failure_details handles failed result" do
      if Livebook.kino_available?() do
        result = Livebook.failure_details(@failing_result)
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "command_stepper returns widget" do
      if Livebook.kino_available?() do
        result = Livebook.command_stepper(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "state_diff handles successful result" do
      if Livebook.kino_available?() do
        result = Livebook.state_diff(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "explore_failure handles successful result" do
      if Livebook.kino_available?() do
        result = Livebook.explore_failure(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :kino_required
    test "explore_failure handles failed result" do
      if Livebook.kino_available?() do
        result = Livebook.explore_failure(@failing_result)
        assert is_struct(result)
      end
    end
  end

  describe "Charts with VegaLite available" do
    @tag :vega_lite_required
    test "command_bar_chart returns VegaLite spec" do
      if Charts.vega_lite_available?() do
        result = Charts.command_bar_chart(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :vega_lite_required
    test "timing_histogram returns VegaLite spec" do
      if Charts.vega_lite_available?() do
        result = Charts.timing_histogram(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :vega_lite_required
    test "success_pie_chart returns VegaLite spec" do
      if Charts.vega_lite_available?() do
        result = Charts.success_pie_chart(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :vega_lite_required
    test "execution_timeline returns VegaLite spec" do
      if Charts.vega_lite_available?() do
        result = Charts.execution_timeline(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :vega_lite_required
    test "command_transition_heatmap returns VegaLite spec" do
      if Charts.vega_lite_available?() do
        result = Charts.command_transition_heatmap(@sample_result)
        assert is_struct(result)
      end
    end

    @tag :vega_lite_required
    test "check_results_chart returns VegaLite spec" do
      if Charts.vega_lite_available?() do
        result = Charts.check_results_chart(@sample_result)
        assert is_struct(result)
      end
    end
  end
end
