defmodule KratosBench.InvariantsTest do
  @moduledoc """
  Non-vacuity: each flagship invariant is proven to *bite* by seeding a
  misbehaviour that only that invariant can catch (RED), paired with a control on
  the same seeds proving the unseeded bench stays green (no false positive).

  The bugs live in the mock's response or the adapter's login, not in the
  assertions, so the same projection that passes the control catches the seeded
  fault — the honest proof the invariants are real.

    * `reject_leaks`    — the mock lies and accepts a registration it should
      reject, so Kratos persists an identity the model does not expect.
      Caught by `:identity_set_faithful`.
    * `modify_ignored`  — the mock accepts a modify-registration without applying
      the role rewrite, so the identity persists without the expected trait.
      Caught by `:accepted_traits_faithful`.
    * `login_broken`    — the adapter logs in with the wrong password, so a known
      identity fails to authenticate. Caught by `:login_consistent`.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 600_000

  @seeds 1..8

  defp run(seed, overrides) do
    PropertyDamage.run(
      model: KratosBench.Model,
      adapter: KratosBench.Adapter,
      adapter_config: KratosBench.adapter_config(overrides),
      max_commands: 16,
      max_runs: 12,
      seed: seed,
      verbose: false
    )
  end

  # First seed whose run fails; nil if all pass.
  defp first_failure(overrides) do
    Enum.find_value(@seeds, fn seed ->
      case run(seed, overrides) do
        {:error, report} -> report
        {:ok, _} -> nil
      end
    end)
  end

  describe "identity_set_faithful (rejected registrations never create identities)" do
    test "RED: a leaking reject is caught" do
      report = first_failure(%{reject_leaks: true})
      assert report, "expected the reject_leaks bug to be caught on some seed"

      assert report.check_name == :identity_set,
             "expected identity-set assertion, got #{inspect(report.check_name)}"
    end

    test "control: no false positive without the bug" do
      for seed <- @seeds do
        assert {:ok, _} = run(seed, %{}), "seed #{seed} failed unexpectedly with no seeded bug"
      end
    end
  end

  describe "accepted_traits_faithful (mock's modify response dictates the traits)" do
    test "RED: an ignored trait rewrite is caught" do
      report = first_failure(%{modify_ignored: true})
      assert report, "expected the modify_ignored bug to be caught on some seed"

      assert report.check_name == :traits,
             "expected traits assertion, got #{inspect(report.check_name)}"
    end
  end

  describe "login_consistent (login outcomes match model state)" do
    test "RED: a broken login is caught" do
      report = first_failure(%{login_broken: true})
      assert report, "expected the login_broken bug to be caught on some seed"

      assert report.check_name == :login,
             "expected login assertion, got #{inspect(report.check_name)}"
    end
  end
end
