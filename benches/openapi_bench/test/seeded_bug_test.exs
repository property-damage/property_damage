defmodule OpenapiBench.SeededBugTest do
  @moduledoc """
  Non-vacuity for the generated suite: with the SUT's `bug` flag set (PUT answers
  200 but silently drops the write), the UNMODIFIED generated client catches the
  read-consistency violation and shrinks it to the minimal `PutValue -> GetValue`
  on a single key. The faithful baseline (scaffold_run_test) staying green plus
  this failing proves the baseline's green is meaningful.

  Crucially the bug lives in the SUT, not in a hand-written lying adapter: the
  same generated adapter that passes the baseline finds the bug here. That is the
  canonical proof that the scaffold codegen drives the API for real.
  """
  use ExUnit.Case, async: false

  alias OpenapiBench.Generated.Adapter
  alias OpenapiBench.Generated.Commands.{GetValue, PutValue}
  alias OpenapiBench.Generated.Model
  alias OpenapiBench.Server

  @moduletag timeout: 120_000

  test "buggy SUT is caught and shrinks to PutValue -> GetValue on one key" do
    assert {:error, report} =
             PropertyDamage.run(
               model: Model,
               adapter: Adapter,
               adapter_config: %{base_url: Server.base_url(), bug: true},
               max_commands: 25,
               max_runs: 50,
               seed: 1,
               verbose: false
             )

    shrunk = PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report))

    assert [%PutValue{key: put_key}, %GetValue{key: get_key}] = shrunk,
           "expected minimal PutValue -> GetValue, got #{inspect(shrunk)}"

    assert put_key == get_key,
           "the write and the read must hit the same key to expose the dropped write"
  end

  test "the minimal repro is the shrinker's doing (shrink: false stays long)" do
    assert {:error, report} =
             PropertyDamage.run(
               model: Model,
               adapter: Adapter,
               adapter_config: %{base_url: Server.base_url(), bug: true},
               max_commands: 25,
               max_runs: 50,
               seed: 1,
               shrink: false,
               verbose: false
             )

    raw = PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report))

    assert length(raw) > 2,
           "without shrinking the discovered sequence should be long, got #{inspect(raw)}"
  end
end
