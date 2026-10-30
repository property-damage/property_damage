defmodule PropertyDamage.Docs do
  @moduledoc """
  Reads the docs and the source path of a model, projection, command or adapter.

  `fetch/1` returns a map with the module's `moduledoc`, the `file` it was
  compiled from, and, per function, the `doc` and the `line` of its first
  clause. A doc reads as a string, `false` for a hidden doc, or `nil` for a
  missing one. `fetch/1` tries three sources in order:

  1. the `__pd_docs__/0` function that `use PropertyDamage.Model`,
     `use PropertyDamage.Model.Projection`, `use PropertyDamage.Command` and
     `use PropertyDamage.Adapter` generate;
  2. the docs chunk of the module, read with `Code.fetch_docs/1`;
  3. nothing: it returns `:unavailable`.

  The macros capture the docs at compile time because a module compiled from
  a script has no docs chunk, so `Code.fetch_docs/1` finds nothing for it.
  The captured map includes private functions. It leaves out macros and names
  that start with `__`. It holds docs, lines and the file path, never source
  text.

  A module that uses more than one of the macros gets one `__pd_docs__/0`.
  The first `use` must come before every `def` and `defp` of the module,
  including those that another `use` defines, such as the defaults of
  `use GenServer`. The macros cannot see a function defined earlier, so they
  cannot know its doc, and such a function is a compile error. The error
  stands even when the module overrides that function later, because an
  override without a doc keeps the doc the macros never saw. So place
  `use GenServer`, or any other `use` that defines functions, after the first
  `use` of a macro. A macro, or a function whose name starts with `__`, may
  come first. A function that a later `@before_compile` injects is
  captured like one written in the module body.

  The captured moduledoc is the one set by the end of the module body, or by
  a `@before_compile` registered before `use`. A `@before_compile` registered
  after `use` that sets only `@moduledoc` is not seen, so the map keeps the
  earlier moduledoc. To capture it, set `@moduledoc` in the module body, or
  register that callback before `use`.

  Events are not captured, and neither is an adapter that declares
  `@behaviour PropertyDamage.Adapter` without `use`: both resolve through
  the docs chunk of their beam.
  """

  @type docs :: %{
          moduledoc: String.t() | false | nil,
          file: Path.t() | nil,
          functions: %{
            {atom(), arity()} => %{doc: String.t() | false | nil, line: pos_integer()}
          }
        }

  @doc """
  Returns the docs of `module`, or `:unavailable` when it has none to read.

  Tries `module.__pd_docs__/0`, then `Code.fetch_docs/1`. An atom that names
  no module is `:unavailable`. So is a module whose beam lost the captured map,
  for example to `:beam_lib.strip/1`, and has no docs chunk either.
  """
  @spec fetch(module()) :: {:ok, docs()} | :unavailable
  def fetch(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      case captured(module) do
        {:ok, docs} -> {:ok, docs}
        :error -> from_docs_chunk(module)
      end
    else
      :unavailable
    end
  end

  # The map that `__pd_docs__/0` reads from the beam, if the beam still holds
  # one of the documented shape.
  defp captured(module) do
    with true <- function_exported?(module, :__pd_docs__, 0),
         %{moduledoc: _, file: _, functions: functions} = docs
         when map_size(docs) == 3 and is_map(functions) <- module.__pd_docs__() do
      {:ok, docs}
    else
      _ -> :error
    end
  end

  defp from_docs_chunk(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _lang, _format, moduledoc, _meta, entries} ->
        functions =
          for {{:function, name, arity}, anno, _signature, doc, _meta} <- entries, into: %{} do
            {{name, arity}, %{doc: translate(doc), line: :erl_anno.line(anno)}}
          end

        {:ok, %{moduledoc: translate(moduledoc), file: source_file(module), functions: functions}}

      _ ->
        :unavailable
    end
  end

  defp translate(%{"en" => text}), do: text
  defp translate(:hidden), do: false
  defp translate(:none), do: nil
  defp translate(_other), do: nil

  defp source_file(module) do
    case module.module_info(:compile)[:source] do
      nil -> nil
      path -> to_string(path)
    end
  end

  @doc false
  # Injected by each `use` macro, which names itself as `declaration`. The
  # marker keeps a module that uses two of the macros from registering the
  # hooks, and defining `__pd_docs__/0`, twice. It also records where the
  # first `use` is and the functions defined before it, for the error about
  # those functions.
  #
  # The map lives in a persisted attribute that every definition rewrites, so
  # the beam holds the map as it stands when the module closes. A function
  # that a later `@before_compile` injects is captured this way too.
  defmacro hook(declaration) do
    line = __CALLER__.line

    quote do
      unless Module.has_attribute?(__MODULE__, :__pd_docs_hooked__) do
        Module.put_attribute(
          __MODULE__,
          :__pd_docs_hooked__,
          {unquote(declaration), __ENV__.file, unquote(line),
           PropertyDamage.Docs.__definitions__(__MODULE__)}
        )

        Module.put_attribute(__MODULE__, :__pd_docs_functions__, %{})
        Module.register_attribute(__MODULE__, :__pd_docs__, persist: true)
        Module.put_attribute(__MODULE__, :__pd_docs__, PropertyDamage.Docs.__docs__(__ENV__))
        @on_definition PropertyDamage.Docs
        @before_compile PropertyDamage.Docs
      end
    end
  end

  @doc false
  # The def and defp keys of the module so far that the map would hold.
  def __definitions__(module) do
    for kind <- [:def, :defp],
        {name, _arity} = key <- Module.definitions_in(module, kind),
        captured?(name),
        do: key
  end

  @doc false
  # The hook sees only the definitions made after it, so it cannot capture a
  # function defined before `use`. Runs when the module closes, so that one
  # error names every such function: those defined before the hook, those
  # that another `use` marked overridable, which `Module.definitions_in/2`
  # lists only once they are final, and any override of one, which the hook
  # saw but whose replaced doc it did not. The lower arities that default
  # arguments generate count as captured with their definition.
  def __reject_uncaptured__(module) do
    {declaration, file, line, earlier} = Module.get_attribute(module, :__pd_docs_hooked__)

    captured =
      for {{name, arity}, %{defaults: defaults, replaces_unseen?: false}} <-
            Module.get_attribute(module, :__pd_docs_functions__),
          covered <- (arity - defaults)..arity//1,
          into: MapSet.new(),
          do: {name, covered}

    uncaptured =
      module
      |> __definitions__()
      |> Enum.reject(&(&1 in captured))
      |> Enum.concat(earlier)
      |> Enum.uniq()

    if uncaptured != [] do
      names =
        uncaptured
        |> Enum.sort()
        |> Enum.map_join(", ", fn {name, arity} -> "#{name}/#{arity}" end)

      raise CompileError,
        file: file,
        line: line,
        description:
          "use #{inspect(declaration)} must come before the functions of the module, " <>
            "because the docs of a function defined earlier cannot be captured; " <>
            "move it above #{names}, which may come from another use placed above it"
    end

    :ok
  end

  defp captured?(name), do: not String.starts_with?(Atom.to_string(name), "__")

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body)
      when kind in [:def, :defp] do
    if captured?(name) do
      key = {name, length(args)}
      doc = pending_doc(env.module)
      impl? = pending_impl?(env.module)
      defaults = Enum.count(args, &match?({:\\, _meta, _arg_and_default}, &1))
      functions = Module.get_attribute(env.module, :__pd_docs_functions__)

      # A later clause, or a definition that replaces an overridable one, keeps
      # the latest non-nil doc, as the compiler does. The line is the first
      # clause of the definition the compiler holds, which an override resets.
      entry =
        case functions do
          %{^key => seen} ->
            %{
              seen
              | doc: if(is_nil(doc), do: seen.doc, else: doc),
                line: definition_line(env, key, seen.line),
                impl?: seen.impl? or impl?,
                defaults: max(seen.defaults, defaults)
            }

          # A first definition that is already overridable replaces one that
          # an earlier `use` made before the hook was registered.
          _ ->
            %{
              doc: doc,
              line: env.line,
              impl?: impl?,
              defaults: defaults,
              replaces_unseen?: Module.overridable?(env.module, key)
            }
        end

      Module.put_attribute(env.module, :__pd_docs_functions__, Map.put(functions, key, entry))
      Module.put_attribute(env.module, :__pd_docs__, __docs__(env))
    end

    :ok
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  @doc false
  # Rejects a function that escaped the hook, refreshes the map for a
  # moduledoc set after the last definition, and defines the function that
  # reads the map back from the beam. That function answers nil when the beam
  # holds no map, for example after `:beam_lib.strip/1`.
  defmacro __before_compile__(env) do
    __reject_uncaptured__(env.module)
    Module.put_attribute(env.module, :__pd_docs__, __docs__(env))

    quote do
      @doc false
      def __pd_docs__ do
        case Keyword.fetch(__MODULE__.__info__(:attributes), :__pd_docs__) do
          {:ok, [docs]} -> docs
          _absent_or_malformed -> nil
        end
      end
    end
  end

  @doc false
  # The map of the module so far, without the bookkeeping that builds it.
  @spec __docs__(Macro.Env.t()) :: docs()
  def __docs__(env) do
    functions =
      for {key, %{doc: doc, line: line, impl?: impl?}} <-
            Module.get_attribute(env.module, :__pd_docs_functions__),
          into: %{} do
        {key, %{doc: if(is_nil(doc) and impl?, do: false, else: doc), line: line}}
      end

    %{moduledoc: pending_moduledoc(env.module), file: env.file, functions: functions}
  end

  # `Module.overridable?/2` stays true on every clause of an override, so the
  # line comes from the definition itself rather than from the clause.
  defp definition_line(env, key, line) do
    if Module.overridable?(env.module, key) do
      {:v1, _kind, meta, _clauses} = Module.get_definition(env.module, key)
      Keyword.fetch!(meta, :line)
    else
      line
    end
  end

  defp pending_doc(module) do
    case Module.get_attribute(module, :doc) do
      {_line, doc} when is_binary(doc) or doc == false -> doc
      _ -> nil
    end
  end

  # The compiler records an `@impl` function without a doc as hidden.
  defp pending_impl?(module) do
    Module.get_attribute(module, :impl) not in [nil, false]
  end

  defp pending_moduledoc(module) do
    case Module.get_attribute(module, :moduledoc) do
      {_line, doc} when is_binary(doc) or doc == false -> doc
      _ -> nil
    end
  end
end
