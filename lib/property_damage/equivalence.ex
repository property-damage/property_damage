defmodule PropertyDamage.Equivalence do
  @moduledoc """
  Builds and applies `using:` predicates.

  A predicate decides whether two values agree. It is a 2-arity function,
  called `using.(left, right)`: on `@compare` with the reference's value and a
  variant's value, on `stutter:` with a command's original events and its retry
  events. Its return is a verdict, read by `PropertyDamage.Verdict` with the
  grammar a `@check` and an `@eventually` predicate share (DR-052):

    * a truthy value: the values agree;
    * `false` or `nil`: they disagree, and the mismatch holds both values;
    * `{:fail, "text"}`: they disagree with that message;
    * `{:fail, exception}`: they disagree with that exception.

  A bare exception struct or an `{:error, _}` tuple is not a verdict: it is a
  disagreement whose message says so. A raise in the predicate fails the
  variant that was compared. Without `using:`, values agree under `==/2`.

  A verdict is a final value, never a boolean: `&&`, `||` and `!` see a
  `{:fail, _}` as truthy. `left == right or {:fail, "reason"}` is the shortest
  reasoned predicate.

  Three helpers compose with `|>`:

    * `by_key/1` lifts a 1-arity key function into a predicate that compares
      the two keys and, when they differ, keeps them in the mismatch;
    * `normalize/1` strips identifier and timestamp keys and unwraps
      `{:ok, _}` and `{:error, _}`;
    * `drop_keys/2` removes the given keys at every depth.

  For example:

      import PropertyDamage.Equivalence

      @compare using: by_key(fn v -> v |> normalize() |> drop_keys([:fees]) end)
      def totals(state, _root), do: state.totals
  """

  alias PropertyDamage.ComparisonMismatch

  @typedoc "A `using:` predicate."
  @type predicate :: (term(), term() -> term())

  # Keys whose values usually differ between two systems or two runs.
  @noise_keys [
    :id,
    :inserted_at,
    :updated_at,
    :created_at,
    :timestamp,
    :uuid,
    :request_id,
    :correlation_id
  ]

  @doc """
  Lift the key function `key` into a predicate that compares `key.(left)`
  with `key.(right)` under `==/2`.

  The predicate returns `true` when the keys are equal and otherwise
  `{:fail, %PropertyDamage.ComparisonMismatch{}}` holding the two keys, so a
  report shows the values as the key function saw them.
  """
  @spec by_key((term() -> term())) :: predicate()
  def by_key(key) when is_function(key, 1) do
    fn left, right ->
      {left_key, right_key} = {key.(left), key.(right)}
      left_key == right_key or {:fail, %ComparisonMismatch{left: left_key, right: right_key}}
    end
  end

  @doc """
  Agree when `reference` and `variant` differ by at most `tolerance`, a
  non-negative number.

  Two numbers agree when `abs(reference - variant) <= tolerance`. Maps,
  lists and tuples agree when they have the same keys or length and their
  elements agree under the same rule; any other pair of values agrees under
  `==/2`. A tolerance is a relation, not an equality, so it belongs in
  `using:` (DR-051), named with its tolerance:

      @compare using: {PropertyDamage.Equivalence, :within, [0.01]}
      def net(state, _root), do: state.net

  Returns `true`, or `{:fail, %PropertyDamage.ComparisonMismatch{}}` holding
  both values, the reference first.

  ## Examples

      iex> PropertyDamage.Equivalence.within(10.0, 10.004, 0.01)
      true

      iex> PropertyDamage.Equivalence.within(%{net: 1.0, cur: "EUR"}, %{net: 1.002, cur: "EUR"}, 0.01)
      true

      iex> {:fail, mismatch} = PropertyDamage.Equivalence.within(10.0, 10.5, 0.01)
      iex> {mismatch.left, mismatch.right}
      {10.0, 10.5}
      iex> Exception.message(mismatch)
      "the values differ by more than 0.01"
  """
  @spec within(term(), term(), number()) :: true | {:fail, ComparisonMismatch.t()}
  def within(reference, variant, tolerance) when is_number(tolerance) and tolerance >= 0 do
    close?(reference, variant, tolerance) or
      {:fail,
       %ComparisonMismatch{
         left: reference,
         right: variant,
         message: "the values differ by more than #{tolerance}"
       }}
  end

  defp close?(left, right, tolerance) when is_number(left) and is_number(right),
    do: abs(left - right) <= tolerance

  defp close?(left, right, tolerance) when is_list(left) and is_list(right),
    do: length(left) == length(right) and all_close?(Enum.zip(left, right), tolerance)

  defp close?(left, right, tolerance)
       when is_tuple(left) and is_tuple(right) and tuple_size(left) == tuple_size(right),
       do: close?(Tuple.to_list(left), Tuple.to_list(right), tolerance)

  defp close?(%module{} = left, %module{} = right, tolerance),
    do: close?(Map.from_struct(left), Map.from_struct(right), tolerance)

  defp close?(left, right, tolerance)
       when is_map(left) and is_map(right) and not is_struct(left) and not is_struct(right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, value} ->
        Map.has_key?(right, key) and close?(value, Map.fetch!(right, key), tolerance)
      end)
  end

  defp close?(left, right, _tolerance), do: left == right

  defp all_close?(pairs, tolerance),
    do: Enum.all?(pairs, fn {left, right} -> close?(left, right, tolerance) end)

  @doc """
  Strip the identifier and timestamp keys (`#{Enum.map_join(@noise_keys, ", ", &inspect/1)}`)
  from every map and struct in `value`, at every depth, and unwrap a
  top-level `{:ok, value}` or `{:error, reason}`.
  """
  @spec normalize(term()) :: term()
  def normalize({:ok, value}), do: strip(value)
  def normalize({:error, reason}), do: strip(reason)
  def normalize(value), do: strip(value)

  defp strip(value), do: drop_keys(value, @noise_keys)

  @doc """
  Remove `keys` from every map and struct in `value`, at every depth: inside
  lists, tuples, map values and struct fields.

  A struct keeps its type; a dropped field reads `nil`.
  """
  @spec drop_keys(term(), [term()]) :: term()
  def drop_keys(%module{} = struct, keys) do
    fields = struct |> Map.from_struct() |> drop_map_keys(keys)
    struct(module, fields)
  end

  def drop_keys(map, keys) when is_map(map), do: drop_map_keys(map, keys)
  def drop_keys(list, keys) when is_list(list), do: Enum.map(list, &drop_keys(&1, keys))

  def drop_keys(tuple, keys) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&drop_keys(&1, keys)) |> List.to_tuple()
  end

  def drop_keys(value, _keys), do: value

  defp drop_map_keys(map, keys) do
    map
    |> Map.drop(keys)
    |> Map.new(fn {key, value} -> {key, drop_keys(value, keys)} end)
  end
end
