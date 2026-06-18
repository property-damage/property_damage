defmodule PropertyDamage.Mutation.Operator do
  @moduledoc false

  @typedoc "A mutation specification"
  @type mutation :: %{
          type: atom(),
          operator: atom(),
          target: atom() | nil,
          original: term(),
          mutated: term(),
          description: String.t() | nil
        }

  @typedoc "Options passed to operators"
  @type opts :: keyword()

  @doc """
  Returns the operator's identifier atom.
  """
  @callback name() :: atom()

  @doc """
  Returns a human-readable description of what this operator does.
  """
  @callback description() :: String.t()

  @doc """
  Generates a list of mutations that can be applied to the given events.

  The operator examines the events and produces mutations that would
  test if the checks can detect various types of faults.

  ## Options

  - `:max_mutations` - Maximum number of mutations to generate (default: 10)
  - `:seed` - Random seed for deterministic mutation generation
  """
  @callback generate_mutations(events :: [struct()], opts :: opts()) :: [mutation()]

  @doc """
  Applies a mutation to events, returning the mutated events.

  This is called during test execution to inject the fault.
  """
  @callback apply_mutation(events :: [struct()], mutation :: mutation()) ::
              [struct()] | {:error, term()}

  @doc """
  Returns a human-readable description of a specific mutation.

  Used for reporting which mutations survived or were killed.
  """
  @callback describe_mutation(mutation :: mutation()) :: String.t()

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Returns all built-in mutation operators.
  """
  @spec built_in_operators() :: [module()]
  def built_in_operators do
    [
      PropertyDamage.Mutation.Operators.Value,
      PropertyDamage.Mutation.Operators.Omission,
      PropertyDamage.Mutation.Operators.Status,
      PropertyDamage.Mutation.Operators.Event,
      PropertyDamage.Mutation.Operators.Boundary
    ]
  end

  @doc """
  Returns operators by their name atoms.
  """
  @spec operators_by_name([atom()]) :: [module()]
  def operators_by_name(names) when is_list(names) do
    name_to_module = %{
      value: PropertyDamage.Mutation.Operators.Value,
      omission: PropertyDamage.Mutation.Operators.Omission,
      status: PropertyDamage.Mutation.Operators.Status,
      event: PropertyDamage.Mutation.Operators.Event,
      boundary: PropertyDamage.Mutation.Operators.Boundary
    }

    Enum.map(names, fn name ->
      Map.get(name_to_module, name) ||
        raise ArgumentError, "Unknown mutation operator: #{inspect(name)}"
    end)
  end

  @doc """
  Creates a mutation struct with standard fields.
  """
  @spec new_mutation(atom(), keyword()) :: mutation()
  def new_mutation(operator, fields) do
    %{
      type: Keyword.fetch!(fields, :type),
      operator: operator,
      target: Keyword.get(fields, :target),
      original: Keyword.get(fields, :original),
      mutated: Keyword.get(fields, :mutated),
      description: Keyword.get(fields, :description)
    }
  end
end
