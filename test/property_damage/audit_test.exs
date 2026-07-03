defmodule PropertyDamage.AuditTest do
  @moduledoc """
  DR-037: generation is a pure function of the seed, and `PropertyDamage.audit/2`
  proves it. Failing-first fixtures (impure generator / impure `with:`) return
  `{:error, ...}`; pure models — including `external()`- and `mint_per_run`-using
  ones — return `:ok`, guarding the DR-036/DR-034 determinism foundation.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.Audit

  alias PropertyDamage.Test.Audit.{
    ImpureGeneratorModel,
    ImpureSelectionModel,
    MintModel
  }

  alias PropertyDamage.Test.{FullModel, LinkModel}

  describe "impurity is caught (failing-first)" do
    test "an impure generator makes audit return an error" do
      assert {:error, %{seed: seed, divergence: divergence}} =
               Audit.run(ImpureGeneratorModel, seeds: 20, max_commands: 5)

      assert is_integer(seed)
      # The impure field is named and the message is actionable.
      assert divergence.position == {:prefix, 0}
      assert Map.has_key?(divergence.fields, :nonce)
      assert divergence.message =~ "nonce"
      assert divergence.message =~ "guides/deterministic_generation.md"
    end

    test "an impure `with:` override (changed selection args) is caught" do
      assert {:error, %{divergence: divergence}} =
               Audit.run(ImpureSelectionModel, seeds: 20, max_commands: 5)

      assert Map.has_key?(divergence.fields, :amount)
      assert divergence.message =~ "guides/deterministic_generation.md"
    end

    test "PropertyDamage.audit/2 is the public entry and agrees" do
      assert {:error, _} = PropertyDamage.audit(ImpureGeneratorModel, seeds: 5, max_commands: 5)
    end
  end

  describe "pure models pass" do
    test "a plain pure model is :ok" do
      assert :ok = Audit.run(FullModel, seeds: 50, max_commands: 15)
    end

    test "an external()/ref-using model is :ok (raw equality is honest post-DR-036)" do
      assert :ok = Audit.run(LinkModel, seeds: 50, max_commands: 15)
    end

    test "a mint_per_run-using model is :ok (markers are position-stamped, DR-034)" do
      assert :ok = Audit.run(MintModel, seeds: 50, max_commands: 10)
    end
  end

  describe "branching generation is audited" do
    test "a pure model passes under branching opts" do
      assert :ok =
               Audit.run(LinkModel,
                 seeds: 50,
                 max_commands: 20,
                 branching: [branch_probability: 0.5, max_branches: 3]
               )
    end

    test "an impure model is caught under branching opts" do
      assert {:error, _} =
               Audit.run(ImpureGeneratorModel,
                 seeds: 20,
                 max_commands: 20,
                 branching: [branch_probability: 0.5]
               )
    end
  end

  describe "seed selection" do
    test "accepts an explicit deterministic list of seeds" do
      assert :ok = Audit.run(FullModel, seeds: [1, 7, 42, 999], max_commands: 10)
    end

    test "an explicit seed list is honored on the error path too" do
      assert {:error, %{seed: seed}} =
               Audit.run(ImpureGeneratorModel, seeds: [123], max_commands: 5)

      assert seed == 123
    end

    test "defaults to a decent spread when :seeds is omitted" do
      # Just assert it runs to completion with the default count.
      assert :ok = Audit.run(FullModel)
    end
  end

  describe "localize/2" do
    alias PropertyDamage.Sequence
    alias PropertyDamage.Test.Audit.Commands.Stable

    test "reports a structural divergence when command counts differ" do
      cmd = %Stable{amount: 1}
      seq1 = Sequence.linear([cmd, cmd])
      seq2 = Sequence.linear([cmd])

      divergence = Audit.localize(seq1, seq2)

      assert divergence.structural
      assert divergence.message =~ "different sequence structure"
    end
  end
end
