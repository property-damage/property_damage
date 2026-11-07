defmodule PropertyDamage.FailureSimilarityExactTest do
  # A failure is exactly as similar to itself as a score can say: 1.0, so a
  # threshold of 1.0 accepts a failure and itself. The weights do not add up
  # to exactly 1.0 in binary floats, and the plain weighted sum of an
  # identical pair came to 0.9999999999999999.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureIntelligence, as: FI
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.Gauntlet, as: G

  defp failure(bug, seed) do
    {:error, %FailureReport{} = report} = G.run(G.Model, bug, seed: seed)
    report
  end

  test "a failing report scores exactly 1.0 against itself" do
    report = failure({:double_debit_from, 5}, 7)

    assert FI.similarity_score(report, report) == 1.0
    assert FI.similar?(report, report, 1.0)
  end

  test "two different failures score below 1.0" do
    report = failure({:double_debit_from, 5}, 7)
    crash = failure(:crash, 7)

    assert FI.similarity_score(report, crash) < 1.0
    refute FI.similar?(report, crash, 1.0)
  end
end
