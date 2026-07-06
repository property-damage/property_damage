defmodule Mix.Tasks.Pd.AuditTest do
  # async: false because the task runs the "compile" Mix task and prints to
  # stdout, which we capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Audit

  # Success is exercised through `run/1` (returns normally). Failure is
  # exercised through `exec/1`, the halt-free seam: `run/1` only translates an
  # `:error` status into `System.halt/1`, so the decision logic is testable
  # in-process without killing the test runner (mirrors pd.validate).

  @pure "PropertyDamage.Test.LinkModel"
  @impure "PropertyDamage.Test.Audit.ImpureGeneratorModel"

  describe "success path" do
    test "prints header and AUDIT PASSED for a pure model" do
      output = capture_io(fn -> Audit.run([@pure, "--seeds", "20", "--max-commands", "15"]) end)

      assert output =~ "PropertyDamage Determinism Audit"
      assert output =~ "AUDIT PASSED"
    end

    test "reports branching mode when branching flags are given" do
      output =
        capture_io(fn ->
          Audit.run([@pure, "--seeds", "15", "--branching", "--branch-probability", "0.4"])
        end)

      assert output =~ "Mode:     branching"
      assert output =~ "AUDIT PASSED"
    end
  end

  describe "failure path (exec/1, no halt)" do
    test "returns :error and localizes the divergence for an impure model" do
      output =
        capture_io(fn ->
          assert Audit.exec([@impure, "--seeds", "20", "--max-commands", "5"]) == :error
        end)

      assert output =~ "AUDIT FAILED"
      assert output =~ "First diverging seed:"
      assert output =~ ":nonce"
      assert output =~ "guides/deterministic_generation.md"
    end

    test "returns :error for a nonexistent model" do
      output = capture_io(fn -> assert Audit.exec(["Nope.NoSuchModel"]) == :error end)
      assert output =~ "does not exist"
    end

    test "prints usage and returns :ok when given no model" do
      output = capture_io(fn -> assert Audit.exec([]) == :ok end)
      assert output =~ "Usage: mix pd.audit MODEL"
    end
  end

  describe "ANSI gating (I2)" do
    test "emits no ANSI escape bytes when IO.ANSI is disabled" do
      previous = Application.get_env(:elixir, :ansi_enabled)
      Application.put_env(:elixir, :ansi_enabled, false)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:elixir, :ansi_enabled)
        else
          Application.put_env(:elixir, :ansi_enabled, previous)
        end
      end)

      output = capture_io(fn -> Audit.run([@pure, "--seeds", "20", "--max-commands", "15"]) end)

      assert output =~ "AUDIT PASSED"
      refute output =~ "\e[", "task leaked ANSI escapes with color disabled"
    end
  end
end
