defmodule PropertyDamage.Next.Gen do
  @moduledoc """
  Generators for command fields, under StreamData's names.

  Three functions return a description of a draw instead of a generator:
  `integer/1`, `member_of/1` and `boolean/0`. A description holds the kind
  of draw and its domain and draws nothing; PD's engine draws it at a slot.
  Because the engine reads the domain before it draws, it can tell whether a
  stored value still fits when the domain moves on replay.

  Every other public StreamData generator function is exported here under
  the same name and arity. It calls StreamData and tags the result as
  delegated: `%Gen{kind: :delegated, domain: %StreamData{}}`. Before it
  calls StreamData, it converts every description and delegated value in
  its arguments to a StreamData generator, also inside lists, tuples, maps
  and keyword lists, and in what a function argument returns (as `bind/2`'s
  does). A description inside a combinator is therefore drawn by StreamData.

  A command module imports this module through `use
  PropertyDamage.Next.Command`, so its generator map reads the same as one
  written with StreamData.
  """

  @enforce_keys [:kind, :domain]
  defstruct [:kind, :domain]

  @typedoc "The kind of draw: an integer, a member of a list, or a StreamData generator."
  @type kind :: :integer | :member | :delegated

  @type t :: %__MODULE__{kind: kind(), domain: Range.t() | list() | StreamData.t()}

  # StreamData's public functions that build no generator.
  @not_generators [check_all: 3, __call__: 3, __reduce__: 3, __struct__: 0, __struct__: 1]

  # The names this module answers with a description.
  @descriptions [integer: 1, member_of: 1, boolean: 0]

  @delegated StreamData.__info__(:functions) -- (@not_generators ++ @descriptions)

  @doc """
  Describes an integer draw over `range`, which must have a step of 1 and
  hold at least one integer. Any other argument raises `ArgumentError`, as
  StreamData refuses an argument that is not a range.
  """
  @spec integer(Range.t()) :: t()
  def integer(%Range{first: first, last: last, step: 1} = range) when first <= last,
    do: %__MODULE__{kind: :integer, domain: range}

  def integer(%Range{} = range) do
    raise ArgumentError,
          "integer/1 describes a draw over a range with a step of 1 that holds at least " <>
            "one integer, got: #{inspect(range)}"
  end

  def integer(other) do
    raise ArgumentError, "integer/1 describes a draw over a range, got: #{inspect(other)}"
  end

  @doc """
  Describes a draw of one member of `enumerable`, which must not be empty.

  An enumerable that is not a list is turned into a list first, so the
  engine can record the drawn member's index.
  """
  @spec member_of(Enumerable.t()) :: t()
  def member_of([_ | _] = list), do: %__MODULE__{kind: :member, domain: list}

  def member_of([]) do
    raise ArgumentError, "member_of/1 needs at least one member to draw from, got: []"
  end

  def member_of(enumerable), do: enumerable |> Enum.to_list() |> member_of()

  @doc "Describes a draw of `false` or `true`, as a member draw."
  @spec boolean() :: t()
  def boolean, do: %__MODULE__{kind: :member, domain: [false, true]}

  for {name, arity} <- @delegated do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc """
    Calls `StreamData.#{name}/#{arity}` with descriptions in its arguments
    converted to StreamData generators, and tags the result as delegated.
    """
    def unquote(name)(unquote_splicing(args)) do
      delegate(unquote(name), unquote(args))
    end
  end

  @doc """
  Converts a generator to a StreamData generator.

  A description becomes the StreamData generator of the same domain, a
  delegated value gives back its StreamData generator, and a `%StreamData{}`
  is returned unchanged. An atom stays an atom and a tuple has each of its
  elements converted, since StreamData takes both as generators.
  """
  @spec to_stream_data(t() | StreamData.t() | atom() | tuple()) ::
          StreamData.t() | atom() | tuple()
  def to_stream_data(%__MODULE__{kind: :integer, domain: range}), do: StreamData.integer(range)
  def to_stream_data(%__MODULE__{kind: :member, domain: list}), do: StreamData.member_of(list)
  def to_stream_data(%__MODULE__{kind: :delegated, domain: generator}), do: generator
  def to_stream_data(%StreamData{} = generator), do: generator
  def to_stream_data(atom) when is_atom(atom), do: atom

  def to_stream_data(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&to_stream_data/1) |> List.to_tuple()

  def to_stream_data(other) do
    raise ArgumentError,
          "expected a generator (a description, a %StreamData{}, an atom or a tuple of " <>
            "generators), got: #{inspect(other)}"
  end

  defp delegate(name, args) do
    generator = apply(StreamData, name, Enum.map(args, &convert/1))
    %__MODULE__{kind: :delegated, domain: generator}
  end

  # Replaces every description and delegated value inside an argument with
  # its StreamData generator. Structs other than these two are left alone,
  # since their fields are data, not generators.
  defp convert(%__MODULE__{} = gen), do: to_stream_data(gen)
  defp convert(%StreamData{} = generator), do: generator
  defp convert(%_{} = struct), do: struct
  defp convert(%{} = map), do: Map.new(map, fn {key, value} -> {convert(key), convert(value)} end)
  defp convert(list) when is_list(list), do: convert_list(list)

  defp convert(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&convert/1) |> List.to_tuple()

  defp convert(fun) when is_function(fun, 0), do: fn -> convert(fun.()) end
  defp convert(fun) when is_function(fun, 1), do: fn a -> convert(fun.(a)) end
  defp convert(fun) when is_function(fun, 2), do: fn a, b -> convert(fun.(a, b)) end
  defp convert(other), do: other

  # Walks a list that may be improper, keeping its tail.
  defp convert_list([head | tail]), do: [convert(head) | convert_list(tail)]
  defp convert_list([]), do: []
  defp convert_list(tail), do: convert(tail)
end
