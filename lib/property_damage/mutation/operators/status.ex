defmodule PropertyDamage.Mutation.Operators.Status do
  @moduledoc """
  Mutation operator that changes success/error outcomes.

  Tests whether checks properly handle error cases and validate
  expected success patterns.

  ## Mutation Types

  - `:success_to_error` - Change {:ok, events} to {:error, reason}
  - `:empty_events` - Change {:ok, events} to {:ok, []}
  - `:error_to_success` - Change {:error, reason} to {:ok, []}
  """

  @behaviour PropertyDamage.Mutation.Operator

  alias PropertyDamage.Mutation.Operator

  @impl true
  def name, do: :status

  @impl true
  def description, do: "Changes success/error outcomes to test error handling"

  @impl true
  def generate_mutations(events, opts \\ []) do
    max_mutations = Keyword.get(opts, :max_mutations, 10)

    # Status mutations apply to the entire response, not individual events
    mutations = [
      # Convert success to various error types
      Operator.new_mutation(:status,
        type: :success_to_error,
        target: :response,
        original: :ok,
        mutated: {:error, :internal_error},
        description: "Convert success to internal error"
      ),
      Operator.new_mutation(:status,
        type: :success_to_error,
        target: :response,
        original: :ok,
        mutated: {:error, :not_found},
        description: "Convert success to not found error"
      ),
      Operator.new_mutation(:status,
        type: :success_to_error,
        target: :response,
        original: :ok,
        mutated: {:error, :timeout},
        description: "Convert success to timeout error"
      ),
      # Return empty events (success but nothing happened)
      Operator.new_mutation(:status,
        type: :empty_events,
        target: :events,
        original: length(events),
        mutated: 0,
        description: "Return empty event list"
      )
    ]

    Enum.take(mutations, max_mutations)
  end

  @impl true
  def apply_mutation(_events, mutation) do
    case mutation.type do
      :success_to_error ->
        # Return error tuple instead of events
        # The runner will need to handle this specially
        {:error, elem(mutation.mutated, 1)}

      :empty_events ->
        # Return empty event list
        []

      :error_to_success ->
        # Return empty success
        []
    end
  end

  @impl true
  def describe_mutation(mutation) do
    case mutation.type do
      :success_to_error ->
        "Changed success to #{inspect(mutation.mutated)}"

      :empty_events ->
        "Returned empty events instead of #{mutation.original} events"

      :error_to_success ->
        "Changed error to success with empty events"
    end
  end
end
