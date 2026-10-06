defmodule PropertyDamage.Equivalence do
  @moduledoc """
  Builds and applies `using:` predicates.

  A predicate decides whether two values agree. It is a 2-arity function,
  called `using.(left, right)`: on `@compare` with the reference's value and a
  variant's value, on `stutter:` with a command's original events and its retry
  events. It returns `:match` or `true` when the values agree, and `false`,
  `{:mismatch, "text"}` or `{:mismatch, exception}` when they do not. Without
  `using:`, values agree under `==/2`.

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
  @type predicate :: (term(), term() -> :match | boolean() | {:mismatch, term()})

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

  When the keys differ, the mismatch holds the two keys, so a report shows
  the values as the key function saw them.
  """
  @spec by_key((term() -> term())) :: predicate()
  def by_key(key) when is_function(key, 1) do
    fn left, right ->
      {left_key, right_key} = {key.(left), key.(right)}

      if left_key == right_key,
        do: :match,
        else: {:mismatch, %ComparisonMismatch{left: left_key, right: right_key}}
    end
  end

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

  @doc """
  Apply the predicate `using` to `left` and `right` and read its answer.

  Returns `:match`, or `{:mismatch, exception}`: `false` becomes a
  `PropertyDamage.ComparisonMismatch` holding both values, a string becomes one
  holding that message, and an exception is kept as it is. Any other answer is
  a mismatch whose message names the answer. A raise in the predicate is not
  caught.
  """
  @spec verdict(predicate(), term(), term()) :: :match | {:mismatch, Exception.t()}
  def verdict(using, left, right) do
    case using.(left, right) do
      answer when answer in [:match, true] ->
        :match

      false ->
        {:mismatch, %ComparisonMismatch{left: left, right: right}}

      {:mismatch, text} when is_binary(text) ->
        {:mismatch, %ComparisonMismatch{left: left, right: right, message: text}}

      {:mismatch, exception} when is_exception(exception) ->
        {:mismatch, exception}

      other ->
        message =
          "a using: predicate must return :match, a boolean or {:mismatch, detail}, " <>
            "got: #{inspect(other)}"

        {:mismatch, %ComparisonMismatch{left: left, right: right, message: message}}
    end
  end
end
