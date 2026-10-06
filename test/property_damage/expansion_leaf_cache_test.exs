defmodule PropertyDamage.ExpansionLeafCacheTest do
  # A leaf module is validated the first time a process realizes it, and the
  # result is kept for the rest of that process. A failed validation is never
  # kept as a pass: the next realization validates the module again and fails
  # the same way. Each validation emits
  # `[:property_damage, :expansion, :leaf_validated]`, so the test counts them.
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.{Broken, Credit, Refund}

  @event [:property_damage, :expansion, :leaf_validated]

  setup do
    test_pid = self()
    handler = "leaf-cache-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, _measurements, metadata, _config ->
          # Only the validations this test's own process performs.
          if self() == test_pid, do: send(test_pid, {:leaf_validated, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp model!(name, expansions) do
    X.define_model!(Module.concat(ExpansionLeafCache, name),
      commands: [Refund],
      expansions: [{Refund, expansions}]
    )
  end

  defp run(model) do
    PropertyDamage.run(
      model: model,
      targets: [X.target("solo", nil)],
      compare: [converge_within: 30],
      max_runs: 1,
      max_commands: 4,
      seed: 1,
      shrink: false,
      validate: false
    )
  end

  defp validations do
    receive do
      {:leaf_validated, metadata} -> [{metadata.module, metadata.result} | validations()]
    after
      0 -> []
    end
  end

  test "a valid leaf module is validated once across two productions in one process" do
    model = model!(Valid, &X.refund_rewrite/2)

    assert {:ok, _stats} = run(model)
    assert {:ok, _stats} = run(model)

    assert validations() == [{Credit, :ok}]
  end

  test "a failing leaf module is validated, and fails, at every production" do
    model = model!(Failing, fn _refund, _state -> [[Broken]] end)

    first = X.outcome(fn -> run(model) end)
    second = X.outcome(fn -> run(model) end)

    for {status, text} <- [first, second] do
      assert status == :raised
      assert text =~ "Broken"
      assert text =~ "generator/1"
    end

    assert validations() == [{Broken, :error}, {Broken, :error}]
  end
end
