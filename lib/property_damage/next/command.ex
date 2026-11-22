defmodule PropertyDamage.Next.Command do
  @moduledoc """
  What a command module gets from `use PropertyDamage.Next.Command`.

  A command module defines a struct and a `generator/2` callback. PD calls
  `generator(state, opts)` at each draw of the command, with the predicted
  state and the spec's `command_opts`, and expects a map from field name to
  generator. PD draws each field the map names under its own journal key
  and builds the struct with `struct!/2`; every other field keeps its
  default. The default `generator/2` returns `%{}`.

  `use` imports `PropertyDamage.Next.Gen` (StreamData's generator names,
  three of them answered with PD's descriptions), `from/2` and
  `PropertyDamage.mint_per_run/1`.

      defmodule Refund do
        use PropertyDamage.Next.Command

        defstruct [:payment, :amount]

        def generator(state, opts) do
          share = Keyword.get(opts, :max_share, 1.0)

          %{
            payment: member_of(Map.keys(state.payments)),
            amount: from(:payment, fn p -> integer(1..max(floor(state.payments[p] * share), 1)) end)
          }
        end
      end
  """

  alias PropertyDamage.Next.From

  @doc "The fields this command draws, as a map from field name to generator."
  @callback generator(state :: term(), opts :: keyword()) :: map()

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.Next.Command

      import PropertyDamage.Next.Gen
      import PropertyDamage.Next.Command, only: [from: 2]
      import PropertyDamage, only: [mint_per_run: 1]

      def generator(_state, _opts), do: %{}
      defoverridable generator: 2
    end
  end

  @doc """
  Marks a field whose generator depends on other drawn fields.

  With one field, `fun` receives that field's drawn value; with a list, a
  map of exactly the listed fields. `fun` returns a generator, never
  another `from/2`. PD calls it at the draw, after drawing the fields it
  names; nothing runs when `from/2` is called.
  """
  @spec from(atom() | [atom()], (term() -> term())) :: From.t()
  def from(field, fun) when is_atom(field) and is_function(fun, 1),
    do: %From{fields: field, fun: fun}

  def from([_ | _] = fields, fun) when is_function(fun, 1) do
    if Enum.all?(fields, &is_atom/1),
      do: %From{fields: fields, fun: fun},
      else: raise(ArgumentError, "from/2 takes field names (atoms), got: #{inspect(fields)}")
  end

  @doc "Whether `module` is a command module: one that uses `PropertyDamage.Next.Command`."
  @spec command_module?(module()) :: boolean()
  def command_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      __MODULE__ in (module.module_info(:attributes)
                     |> Keyword.get_values(:behaviour)
                     |> List.flatten())
  end

  def command_module?(_other), do: false
end
