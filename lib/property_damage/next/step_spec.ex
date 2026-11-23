defmodule PropertyDamage.Next.StepSpec do
  @moduledoc """
  How PD draws one kind of step: what a model writes.

  A spec holds a command module (an atom; PD builds a struct of it only at
  a draw), a weight, an optional `when:` predicate on the predicted state,
  the options the module's `generator/2` reads (`command_opts`), the
  assigns for the ports, and command changes recorded by layers. PD sets
  `id` to the spec's position in the model's list, counted from 1, when it
  loads the model; a model never writes an id.

  A model builds its specs with `normalize/1` from a child-style list:

      StepSpec.normalize([
        {Pay, weight: 2},
        {Refund, weight: 3, when: &Refund.possible?/1, command_opts: [max_share: 0.5]},
        RefundedTotal
      ])

  Layers change specs with the verbs of this module and `transform/2`.
  A command change is recorded on the spec and applied at each draw, in the
  order it was recorded.
  """

  alias PropertyDamage.Next.{Command, GeneratorCheck}

  @enforce_keys [:command]
  defstruct [
    :command,
    :id,
    weight: 1,
    when: nil,
    command_opts: [],
    assigns: %{},
    changes: [],
    history: []
  ]

  @type change :: {:put, atom(), term()} | {:update, (map(), term() -> map())}

  @type t :: %__MODULE__{
          command: module(),
          id: pos_integer() | nil,
          weight: pos_integer(),
          when: (term() -> as_boolean(term())) | nil,
          command_opts: keyword(),
          assigns: %{atom() => term()},
          changes: [change()],
          history: [{function(), :changed | :unchanged}]
        }

  defmodule FromCommand do
    @moduledoc """
    An assign computed from the drawn command.

    `PropertyDamage.Next.StepSpec.assign_from_command/3` builds it. PD
    calls `fun` with the drawn command, after every other draw at the slot,
    and draws the generator it returns.
    """

    @enforce_keys [:fun]
    defstruct [:fun]

    @type t :: %__MODULE__{fun: (struct() -> term())}
  end

  @doc """
  Turns a child-style list into specs.

  `Module` is `{Module, []}`. In `{Module, keyword}` the keyword list holds
  PD's own keys, checked strictly: `weight`, `when` and `command_opts`. A
  `%StepSpec{}` is taken as it is. A module that does not use
  `PropertyDamage.Next.Command` is refused.
  """
  @spec normalize([module() | {module(), keyword()} | t()]) :: [t()]
  def normalize(entries) when is_list(entries), do: Enum.map(entries, &new/1)

  defp new(%__MODULE__{} = spec), do: spec
  defp new(module) when is_atom(module), do: new({module, []})

  defp new({module, keyword}) when is_atom(module) and is_list(keyword) do
    keyword = Keyword.validate!(keyword, weight: 1, when: nil, command_opts: [])
    weight!(keyword[:weight])
    when!(keyword[:when])
    command_opts!(keyword[:command_opts])
    struct!(__MODULE__, [command: command_module!(module)] ++ keyword)
  end

  defp new(other) do
    raise ArgumentError,
          "a step entry is a command module, {module, keyword} or a %StepSpec{}, got: " <>
            inspect(other)
  end

  # --- Assigns: data for the ports, one key per call.

  @doc """
  Sets the assign `key` to `generator`.

  The generator is drawn at each draw of the step under its own journal
  key. A mint marker is also accepted. A value that is not a generator
  raises here, naming the key.
  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = spec, key, generator) when is_atom(key) do
    accepted!(generator, "StepSpec.assign/3, key #{inspect(key)}")
    %{spec | assigns: Map.put(spec.assigns, key, generator)}
  end

  @doc "Sets each assign of `keyword`, as `assign/3` does."
  @spec merge_assigns(t(), keyword()) :: t()
  def merge_assigns(%__MODULE__{} = spec, keyword) when is_list(keyword),
    do: Enum.reduce(keyword, spec, fn {key, generator}, acc -> assign(acc, key, generator) end)

  @doc """
  Sets the assign `key` to a function of the drawn command.

  `fun` receives the drawn command and nothing else, and returns a
  generator. PD calls it at every draw, after every other draw at the slot.
  """
  @spec assign_from_command(t(), atom(), (struct() -> term())) :: t()
  def assign_from_command(%__MODULE__{} = spec, key, fun)
      when is_atom(key) and is_function(fun, 1),
      do: %{spec | assigns: Map.put(spec.assigns, key, %FromCommand{fun: fun})}

  # --- The command: changes recorded now, applied at each draw.

  @doc """
  Records that `field` of the command is drawn from `generator`.

  A field the command's struct does not have, or a value that is not a
  generator, raises here.
  """
  @spec put_command_field(t(), atom(), term()) :: t()
  def put_command_field(%__MODULE__{command: module} = spec, field, generator) do
    field!(module, field)
    accepted!(generator, "StepSpec.put_command_field/3, field #{inspect(field)}")
    record(spec, {:put, field, generator})
  end

  @doc "Records each field of `keyword`, as `put_command_field/3` does."
  @spec merge_command_fields(t(), keyword()) :: t()
  def merge_command_fields(%__MODULE__{} = spec, keyword) when is_list(keyword),
    do: Enum.reduce(keyword, spec, fn {field, gen}, acc -> put_command_field(acc, field, gen) end)

  @doc "Merges `keyword` into the options the command module's `generator/2` reads."
  @spec merge_command_opts(t(), keyword()) :: t()
  def merge_command_opts(%__MODULE__{} = spec, keyword) when is_list(keyword) do
    command_opts!(keyword)
    %{spec | command_opts: Keyword.merge(spec.command_opts, keyword)}
  end

  @doc """
  Records a change that reads the state, for what the other verbs cannot say.

  At each draw `fun` receives the map of field generators and the predicted
  state, and returns the new map.
  """
  @spec update_command(t(), (map(), term() -> map())) :: t()
  def update_command(%__MODULE__{} = spec, fun) when is_function(fun, 2),
    do: record(spec, {:update, fun})

  defp record(spec, change), do: %{spec | changes: spec.changes ++ [change]}

  # --- Layers

  @doc """
  Applies a layer, or each layer of a list in order, to every spec.

  A layer is a function from one spec to one spec; `specs` is a list of
  `%StepSpec{}` and anything else raises. A result that is not a
  `%StepSpec{}` raises, naming the function.

  A layer may match a spec on its command module, weight, `command_opts` or
  assigns. It never matches or replaces `when:`: a function has no usable
  identity to match on, and a replaced predicate would silently change which
  steps are eligible. A layer that returns a spec with a different `when:`
  raises, naming the function. A layer that changes no spec
  does not raise; each spec records every layer in its `history`, marked
  `:changed` or `:unchanged`, so a report can count the specs each layer
  changed.
  """
  @spec transform([t()], (t() -> t()) | [(t() -> t())]) :: [t()]
  def transform(specs, funs) when is_list(specs) and is_list(funs),
    do: Enum.reduce(funs, specs, &transform(&2, &1))

  def transform(specs, fun) when is_list(specs) and is_function(fun, 1) do
    Enum.each(specs, &spec!(&1, "the input of StepSpec.transform/2"))

    Enum.map(specs, fn spec ->
      spec |> fun.() |> spec!(fun) |> keeps_when!(spec, fun) |> note_layer(spec, fun)
    end)
  end

  defp keeps_when!(%__MODULE__{when: kept} = result, %__MODULE__{when: kept}, _fun), do: result

  defp keeps_when!(%__MODULE__{}, %__MODULE__{command: command}, fun) do
    raise ArgumentError,
          "the layer #{inspect(fun)} given to StepSpec.transform/2 changed the when: of the " <>
            "spec for #{inspect(command)}; a layer never changes when:"
  end

  defp note_layer(result, original, fun) do
    outcome = if unchanged?(result, original), do: :unchanged, else: :changed
    %{result | history: result.history ++ [{fun, outcome}]}
  end

  defp unchanged?(result, original), do: %{result | history: []} == %{original | history: []}

  # --- Checks

  defp spec!(%__MODULE__{} = spec, _source), do: spec

  defp spec!(other, fun) when is_function(fun) do
    raise ArgumentError,
          "the layer #{inspect(fun)} given to StepSpec.transform/2 returned " <>
            "#{inspect(other)}, not a %StepSpec{}"
  end

  defp spec!(other, source) do
    raise ArgumentError, "#{source} must be a list of %StepSpec{}, got: #{inspect(other)}"
  end

  defp command_module!(module) do
    if Command.command_module?(module) do
      module
    else
      raise ArgumentError,
            "#{inspect(module)} is not a command module: a step's command must " <>
              "use PropertyDamage.Next.Command"
    end
  end

  defp field!(module, field) do
    if is_atom(field) and field != :__struct__ and Map.has_key?(module.__struct__(), field) do
      field
    else
      raise ArgumentError,
            "#{inspect(module)} has no field #{inspect(field)}, so a layer cannot set it"
    end
  end

  defp accepted!(value, where) do
    if GeneratorCheck.accepted?(value), do: value, else: GeneratorCheck.refuse!(value, where)
  end

  defp weight!(weight) when is_integer(weight) and weight > 0, do: weight

  defp weight!(other),
    do: raise(ArgumentError, "a step's weight is a positive integer, got: #{inspect(other)}")

  defp when!(nil), do: nil
  defp when!(fun) when is_function(fun, 1), do: fun

  defp when!(other) do
    raise ArgumentError,
          "a step's when: is nil or a function of the predicted state, got: #{inspect(other)}"
  end

  defp command_opts!(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "command_opts is a keyword list, got: #{inspect(opts)}"
    end
  end
end
