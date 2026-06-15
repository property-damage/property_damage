defmodule PropertyDamage.LinearizationLoadOrderTest do
  # async: false on purpose — this test purges a module from the VM, so it must
  # not run concurrently with any other test.
  use ExUnit.Case, async: false

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Linearization

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.Events.ItemCreated
  alias PropertyDamage.Test.FailingModel
  alias PropertyDamage.Test.Projections.{FailingAssertion, ModelState}

  test "check resolves a model's simulator even when the module is not yet loaded" do
    # The flake reproduced deterministically: with the model purged from the VM,
    # function_exported?/3 returns false, so a naive simulator lookup yields nil
    # and check wrongly returns {:indeterminate, 0}. check must ensure the module
    # is loaded before probing it. (This is also a real latent bug: a user's
    # model need not be loaded at the moment check first touches it.)
    :code.purge(FailingModel)
    :code.delete(FailingModel)
    refute :erlang.function_exported(FailingModel, :simulator, 0)

    branch_commands = [
      [%CreateItem{name: "A", quantity: 60}],
      [%CreateItem{name: "B", quantity: 60}]
    ]

    branch_events = %{
      0 => [
        Entry.from_command(%ItemCreated{item_ref: nil, name: "A", quantity: 60}, 0, timestamp: 1)
      ],
      1 => [
        Entry.from_command(%ItemCreated{item_ref: nil, name: "B", quantity: 60}, 0, timestamp: 1)
      ]
    }

    projections = %{ModelState => ModelState.init(), FailingAssertion => FailingAssertion.init()}

    assert {:no_linearization, refutation} =
             Linearization.check(branch_commands, branch_events, projections, FailingModel)

    assert refutation.check_name == :quantity_limit
  end
end
