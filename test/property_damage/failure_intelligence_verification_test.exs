defmodule PropertyDamage.FailureIntelligenceVerificationTest do
  # Fix verification replays the shrunk sequence of a report and compares the
  # failure signature, so its verdict does not depend on what the model
  # generates. The generation switch is global state, hence `async: false`.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureIntelligence, as: FI
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.FI.{SwitchAdapter, SwitchModel, SwitchOp}
  alias PropertyDamage.Test.Gauntlet, as: G

  @bug {:double_debit_from, 5}

  setup do
    on_exit(&SwitchOp.reset_amounts/0)
  end

  test "a fix that changes generation does not hide a failing shrunk sequence" do
    config = %{bug_at_most: 50}

    {:error, %FailureReport{replay: replay} = report} =
      PropertyDamage.run(
        model: SwitchModel,
        targets: [{SwitchAdapter, config: config}],
        seed: 3,
        max_runs: 30,
        replay_dir: false,
        verbose: false
      )

    assert is_map(replay)

    # The seed now draws only passing plans; the shrunk sequence still fails.
    SwitchOp.set_amounts(:high)

    assert {:ok, _stats} =
             PropertyDamage.run(
               model: SwitchModel,
               targets: [{SwitchAdapter, config: config}],
               seed: report.seed,
               max_runs: 1,
               replay_dir: false,
               verbose: false
             )

    result = FI.verify_fix(report, SwitchModel, targets: [{SwitchAdapter, config: config}])

    assert result.status == :still_failing
  end

  describe "verify_fix/3 on a ledger failure" do
    setup do
      {:error, %FailureReport{} = report} = G.run(G.Model, @bug, seed: 7, replay_dir: false)
      %{report: report}
    end

    test "a replay that fails with another signature is reported as a different failure",
         %{report: report} do
      result =
        FI.verify_fix(report, G.Model, targets: [{G.Adapter, config: %{bug: :crash}}])

      assert result.status == :different_failure
      assert result.new_signature != result.signature
    end

    test "the same defect recurs with an equal signature", %{report: report} do
      result =
        FI.verify_fix(report, G.Model, targets: [{G.Adapter, config: %{bug: @bug}}])

      assert result.status == :still_failing
      assert result.signature == report.replay.failure.signature
    end

    test "a report without a replay artifact is refused", %{report: report} do
      assert FI.verify_fix(%{report | replay: nil}, G.Model,
               targets: [{G.Adapter, config: %{bug: :off}}]
             ) == {:error, :no_replay_artifact}
    end
  end
end
