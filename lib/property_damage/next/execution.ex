defmodule PropertyDamage.Next.Execution do
  @moduledoc false
  # Executes one plan against the system under test: the adapter's setup,
  # one `execute/3` per step in slot order, the checks after each step, and
  # the adapter's teardown.
  #
  # Before a step reaches the adapter, its command and assigns are made
  # concrete. A placeholder becomes the value the system minted: the field at
  # the placeholder's path in the real event at its index, among the events
  # its step returned. A mint marker becomes a value derived from a nonce
  # drawn once per execution and from the marker's stamp, the step and
  # field generation drew it for, so every step that holds one marker sends
  # one value, and every execution, a replay of the same journal included,
  # sends values no earlier execution sent. A marker without a stamp is
  # given one from where it sits in the step. The adapter receives neither
  # kind of marker, nor a step, a slot or a journal key.
  #
  # The execution stops at the first step that fails: the adapter answers
  # `{:error, reason}`, raises, exits or throws, a check fails, or a value
  # cannot be made concrete.

  require Logger

  alias PropertyDamage.Mint

  alias PropertyDamage.Next.{
    AcknowledgedIgnoredAssignError,
    AcknowledgedUnsetAssignError,
    AssignCounts,
    Checks,
    Placeholder,
    Plan,
    Runtime,
    Step
  }

  @type reason ::
          {:check, atom(), String.t()} | {:adapter_error, term()} | {:raise, Exception.t()}

  @doc """
  Executes `plan`. Returns `:ok`, or `{:error, step_key, reason}` for the
  first failing step; a failing setup has `nil` as its step key.

  Options: `:ignored` lists the assign keys the adapter's target ignores
  (default `[]`), and `:counts` is an `AssignCounts` table that receives the
  assigns the steps set and the adapter acknowledges (default `nil`: none
  counted). The adapter's acknowledgments are checked either way, and the
  two errors they can raise leave this function as raises.
  """
  @spec run(Plan.t(), module(), term(), [module()], keyword()) ::
          :ok | {:error, term(), reason()}
  def run(%Plan{steps: steps}, adapter, config, projections, opts \\ []) do
    checks = Checks.init(projections)

    case setup(adapter, config) do
      {:ok, context} ->
        run = %{
          adapter: adapter,
          context: context,
          nonce: nonce(),
          events: %{},
          checks: checks,
          ignored: Keyword.get(opts, :ignored, []),
          counts: Keyword.get(opts, :counts)
        }

        try do
          execute(steps, run)
        after
          teardown(adapter, context)
        end

      {:error, reason} ->
        {:error, nil, reason}
    end
  end

  defp nonce, do: 8 |> :crypto.strong_rand_bytes() |> :binary.decode_unsigned()

  # --- The adapter's lifecycle

  defp setup(adapter, config) do
    case adapter.setup(config, %Runtime{}) do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, {:adapter_error, reason}}
      other -> {:error, {:raise, bad_return(adapter, "setup/2", "{:ok, context}", other)}}
    end
  rescue
    exception -> {:error, {:raise, exception}}
  catch
    kind, reason -> {:error, {:raise, caught(kind, reason)}}
  end

  # Teardown is best effort: a teardown that fails is logged and never
  # changes the result of the execution.
  defp teardown(adapter, context) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :teardown, 1),
      do: adapter.teardown(context)

    :ok
  rescue
    exception -> log_teardown(adapter, Exception.message(exception))
  catch
    kind, reason -> log_teardown(adapter, Exception.message(caught(kind, reason)))
  end

  defp log_teardown(adapter, message) do
    Logger.warning("#{inspect(adapter)}.teardown/1 failed: #{message}")
    :ok
  end

  # --- The steps

  defp execute([], _run), do: :ok

  defp execute([%Step{key: key} = step | rest], run) do
    case execute_step(step, run) do
      {:ok, run} -> execute(rest, run)
      {:error, reason} -> {:error, key, reason}
    end
  end

  defp execute_step(%Step{key: key, command: command, assigns: assigns}, run) do
    command = concrete(command, key, [:command], run)
    assigns = concrete(assigns, key, [:assigns], run)

    scope = scope(run, command, assigns)

    with {:ok, events} <- Runtime.with_step(scope, fn -> call(run, command, assigns) end),
         {:ok, checks} <- Checks.step(run.checks, command, events) do
      {:ok, %{run | events: Map.put(run.events, key, events), checks: checks}}
    end
  rescue
    # Misuse of an acknowledgment is not a failure of the system under test.
    exception in [AcknowledgedUnsetAssignError, AcknowledgedIgnoredAssignError] ->
      reraise exception, __STACKTRACE__

    exception ->
      {:error, {:raise, exception}}
  catch
    kind, reason -> {:error, {:raise, caught(kind, reason)}}
  end

  # The running step as `Runtime.ack/2` sees it, with the step's set
  # assigns counted: an assign is set when its drawn value is truthy.
  defp scope(run, command, assigns) do
    module = command.__struct__
    set = for {key, value} <- assigns, value, do: key

    if run.counts,
      do: Enum.each(set, &AssignCounts.record_set(run.counts, run.adapter, module, &1))

    %{
      target: run.adapter,
      command: module,
      set: set,
      ignored: run.ignored,
      counts: run.counts
    }
  end

  defp call(%{adapter: adapter, context: context}, command, assigns) do
    case adapter.execute(command, assigns, context) do
      {:ok, events} when is_list(events) -> {:ok, events}
      {:error, reason} -> {:error, {:adapter_error, reason}}
      other -> raise bad_return(adapter, "execute/3", "{:ok, events}", other)
    end
  end

  defp bad_return(adapter, function, expected, got) do
    %ArgumentError{
      message:
        "#{inspect(adapter)}.#{function} must return #{expected} or {:error, reason}, " <>
          "got: #{inspect(got)}"
    }
  end

  # An exit or a throw out of user code, as an exception.
  defp caught(kind, reason), do: %ErlangError{original: {kind, reason}}

  # --- Concrete values

  # `path` is where the term sits in the step, innermost first.
  defp concrete(%Placeholder{} = placeholder, _key, _path, run),
    do: resolve(placeholder, run.events)

  defp concrete(%Mint{position: nil} = marker, key, path, run),
    do: marker |> Mint.reify(key, Enum.reverse(path)) |> Mint.resolve(run.nonce, 0)

  defp concrete(%Mint{} = marker, _key, _path, run), do: Mint.resolve(marker, run.nonce, 0)

  defp concrete(%_{} = struct, key, path, run) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(struct, fn {field, value}, acc ->
      Map.put(acc, field, concrete(value, key, [field | path], run))
    end)
  end

  defp concrete(%{} = map, key, path, run) do
    Map.new(map, fn {k, v} ->
      {concrete(k, key, [{:key, k} | path], run), concrete(v, key, [k | path], run)}
    end)
  end

  defp concrete(list, key, path, run) when is_list(list),
    do: concrete_list(list, 0, key, path, run)

  defp concrete(tuple, key, path, run) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> concrete_list(0, key, path, run)
    |> List.to_tuple()
  end

  defp concrete(other, _key, _path, _run), do: other

  defp concrete_list([head | tail], position, key, path, run) do
    [
      concrete(head, key, [position | path], run)
      | concrete_list(tail, position + 1, key, path, run)
    ]
  end

  defp concrete_list(tail, _position, _key, _path, _run), do: tail

  defp resolve(%Placeholder{step: step, event_index: index, path: path}, events) do
    with {:ok, step_events} <- Map.fetch(events, step),
         {:ok, event} <- at(step_events, index),
         {:ok, value} <- dig(event, path) do
      value
    else
      :error ->
        raise ArgumentError,
              "a value the system under test was predicted to mint is missing from its " <>
                "answer: step #{inspect(step)}, event #{index}, field path #{inspect(path)}"
    end
  end

  defp dig(value, []), do: {:ok, value}

  defp dig(%{} = map, [field | rest]) do
    with {:ok, inner} <- Map.fetch(map, field), do: dig(inner, rest)
  end

  defp dig(list, [position | rest]) when is_list(list) and is_integer(position) do
    with {:ok, inner} <- at(list, position), do: dig(inner, rest)
  end

  defp dig(_value, _path), do: :error

  defp at(list, index) when is_list(list) and index >= 0 and index < length(list),
    do: {:ok, Enum.at(list, index)}

  defp at(_list, _index), do: :error
end
