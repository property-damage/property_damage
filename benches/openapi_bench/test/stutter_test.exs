defmodule OpenapiBench.StutterTest do
  @moduledoc """
  Exercises `PropertyDamage`'s stutter (idempotency) testing against the bench's
  non-idempotent `POST /values` create endpoint.

  The pairing is the non-vacuity proof, mirroring the seeded-bug pattern:

    * **Caught (bug live)**: with `idempotency_bug` set, the SUT ignores the
      `Idempotency-Key`, so a stutter retry double-creates (a new id) and the
      framework flags an idempotency violation. This proves stutter actually
      fires and detects a real retry-unsafety.

    * **Control (no false positive)**: with the flag clear, the SUT honors the
      key and a retry returns the original id, so the *same* stutter config
      produces no violation. Coverage confirms `CreateValue` really was
      generated and executed, so the green is not vacuous.
  """
  use ExUnit.Case, async: false

  alias OpenapiBench.Idempotency.Adapter
  alias OpenapiBench.Idempotency.Commands.CreateValue
  alias OpenapiBench.Idempotency.Model
  alias OpenapiBench.Server

  @moduletag timeout: 120_000

  # probability 1.0 => every CreateValue is stuttered; strict => retry events
  # must equal the first execution's exactly.
  @stutter [
    probability: 1.0,
    max_repeats: 1,
    delay_ms: 0,
    commands: [CreateValue],
    comparison: :strict
  ]

  test "stutter catches the double-create when the SUT ignores the idempotency key" do
    assert {:error, report} =
             PropertyDamage.run(
               model: Model,
               adapter: Adapter,
               adapter_config: %{base_url: Server.base_url(), idempotency_bug: true},
               stutter: @stutter,
               max_commands: 10,
               max_runs: 20,
               seed: 1,
               verbose: false
             )

    assert PropertyDamage.FailureReport.idempotency_failure?(report),
           "expected an idempotency violation, got #{inspect(PropertyDamage.FailureReport.failure_type(report))}"

    # The violation must record more than one attempt (the retry actually ran).
    assert length(PropertyDamage.FailureReport.idempotency_violation(report).attempts) >= 2
  end

  test "stutter passes when the SUT honors the idempotency key (no false positive)" do
    assert {:ok, stats} =
             PropertyDamage.run(
               model: Model,
               adapter: Adapter,
               adapter_config: %{base_url: Server.base_url(), idempotency_bug: false},
               stutter: Keyword.put(@stutter, :max_repeats, 2),
               coverage: true,
               max_commands: 10,
               max_runs: 20,
               seed: 1,
               verbose: false
             )

    # Prove the run was not vacuously green: CreateValue was generated and run.
    coverage = stats.coverage
    assert PropertyDamage.Coverage.command_coverage(coverage) == 100.0
    assert Map.get(coverage.command_counts, CreateValue, 0) > 0
  end
end
