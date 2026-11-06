defmodule PropertyDamage.MutationKillMessageTest do
  @moduledoc """
  A killed mutation reports the failure message of the report that killed it,
  not a placeholder such as "Unknown failure". The assertion is equality with
  `PropertyDamage.FailureReport.failure_message/1` of a run that applies the
  same mutation, so a message that only contains a substring does not pass.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, Mutation}
  alias PropertyDamage.Mutation.{MutatingAdapter, Operator}

  defmodule WellFormedItemCheck do
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.Events.ItemCreated

    @impl true
    def init, do: %{malformed: []}

    @impl true
    def apply(state, %ItemCreated{item_ref: ref} = event) when is_binary(ref) do
      if well_formed?(event),
        do: state,
        else: %{state | malformed: [event | state.malformed]}
    end

    def apply(state, _), do: state

    defp well_formed?(%ItemCreated{item_ref: ref, name: name, quantity: quantity}) do
      ref =~ ~r/\Aitem_\d+\z/ and is_binary(name) and name != "" and
        is_integer(quantity) and quantity > 0
    end

    @check every: PropertyDamage.Test.Commands.CreateItem
    def assert_items_well_formed(state, _cmd_or_event) do
      state.malformed == [] or
        PropertyDamage.fail!("kill message fixture: malformed ItemCreated",
          events: state.malformed
        )
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    alias PropertyDamage.Test.Commands.CreateItem
    alias PropertyDamage.Test.Events.ItemCreated
    alias PropertyDamage.Test.Projections.ModelState

    @impl true
    def commands, do: [CreateItem]

    @impl true
    def command_sequence_projection, do: ModelState

    @impl true
    def check_projections, do: [WellFormedItemCheck]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%CreateItem{name: name, quantity: quantity}, _state) do
      [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
    end
  end

  @adapter PropertyDamage.Test.TestAdapter

  # Runs the model once with the mutating adapter the runner builds for this
  # mutation, wired as the runner wires it.
  defp killing_report(%{command: command, operator: operator_name, mutation: mutation}) do
    [operator] = Operator.operators_by_name([operator_name])

    mutating_adapter =
      MutatingAdapter.new(
        inner_adapter: @adapter,
        target_command: command,
        mutation: mutation,
        operator: operator
      )

    PropertyDamage.run(
      model: Model,
      targets: [
        {MutatingAdapter, name: "TestAdapter", config: %{__mutating_adapter__: mutating_adapter}}
      ],
      max_runs: 1,
      max_commands: 20,
      seed: 20_261_106
    )
  end

  describe "Mutation.run/1 killed mutation message" do
    test "equals the failure message of the report that killed the mutation" do
      {:ok, report} =
        Mutation.run(
          model: Model,
          targets: [@adapter],
          operators: [:value],
          mutations_per_command: 2,
          max_runs: 1
        )

      assert [_ | _] = killed = report.killed_mutations

      for mutation <- killed do
        assert {:error, %FailureReport{} = failure} = killing_report(mutation)
        expected = FailureReport.failure_message(failure)

        assert is_binary(expected)
        assert expected =~ "kill message fixture: malformed ItemCreated"
        assert mutation.failure_message == expected
      end
    end
  end
end
