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
end
