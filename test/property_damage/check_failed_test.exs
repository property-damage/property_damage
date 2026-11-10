defmodule PropertyDamage.CheckFailedTest do
  use ExUnit.Case, async: true

  test "fail!/2 raises CheckFailed carrying the message and data" do
    error =
      assert_raise PropertyDamage.CheckFailed, fn ->
        PropertyDamage.fail!("balance is negative", balance: -50)
      end

    assert error.message == "balance is negative"
    assert error.data == %{balance: -50}
  end

  test "the message lists data keys in sorted order whatever order the atoms were created in" do
    # Atoms are created in reverse alphabetical order: a small map prints its keys by atom creation.
    later = String.to_atom("check_failed_sorted_b")
    earlier = String.to_atom("check_failed_sorted_a")

    inner = %{
      String.to_atom("check_failed_sorted_d") => 1,
      String.to_atom("check_failed_sorted_c") => 2
    }

    message =
      Exception.message(%PropertyDamage.CheckFailed{
        message: "bad",
        data: %{later => 1, earlier => inner}
      })

    assert message ==
             "bad: %{check_failed_sorted_a: %{check_failed_sorted_c: 2, check_failed_sorted_d: 1}, check_failed_sorted_b: 1}"
  end
end
