defmodule PropertyDamage.Sequence.Validator do
  @moduledoc false
  # Validates a sequence of roots: each root's `when:` against the state the
  # roots before it leave. It reads commands/0 as the list of roots on
  # purpose: a shrink candidate is a list of roots, and a leaf of an
  # expansion is checked when the expansion is realized for the candidate
  # (PropertyDamage.Expansion), where a failed leaf precondition makes its
  # root run as itself.

  alias PropertyDamage.{Generator, Model}
  alias PropertyDamage.Sequence
  alias PropertyDamage.Sequence.Position

  @doc """
  Check if a sequence is valid according to the model's preconditions.

  Walks the roots of `sequence.prefix` as generation does:
  1. Start from the state the sequence's setup commands leave
  2. For each root, check the module's `when:` option against the current state
  3. Fold the root and the events the model's simulator returns for it into
     the state, with the placeholders the sequence's registry links to the
     root's position, so a state keyed by an id the system mints keeps one key
     per id

  ## Parameters

  - `sequence` - The `%PropertyDamage.Sequence{}` to validate: its `setup`,
    `prefix` and `registry`. A `nil` registry (a hand-built sequence) folds
    the simulated events unlinked
  - `model` - Model module defining state projection and command wiring
  - `opts` - `:external_markers`, as for `Generator.generate_sequence/2`
    (default `[]`)

  ## Returns

  - `true` - All roots pass their preconditions
  - `false` - At least one root fails its precondition

  ## Example

      sequence =
        Sequence.linear([
          %CreateItem{name: "A", quantity: 1},
          %ViewItem{item_ref: ref}  # Requires items to exist
        ])

      # Invalid because ViewItem runs before any items exist
      Validator.valid_sequence?(sequence, MyModel)
      # => false
  """
  @spec valid_sequence?(Sequence.t(), module(), keyword()) :: boolean()
  def valid_sequence?(%Sequence{} = sequence, model, opts \\ []) do
    # The model's spec table carries each command's `when:` as listed.
    table = Model.spec_table(model)

    state = Generator.setup_state(model, sequence, opts)

    sequence.prefix
    |> Enum.with_index()
    |> Enum.reduce_while(state, fn {root, index}, state ->
      position = Position.prefix(index)

      if precondition_passes?(table, root, state) do
        {:cont, Generator.simulate_root(model, root, position, state, sequence.registry, opts)}
      else
        {:halt, :invalid}
      end
    end)
    |> Kernel.!=(:invalid)
  end

  defp precondition_passes?(table, command, state) do
    case table |> Model.spec_for(command) |> Map.get(:when) do
      nil -> true
      pred when is_function(pred, 1) -> pred.(state)
    end
  end
end
