defmodule PropertyDamage.Provenance do
  @moduledoc """
  Value provenance classification (DR-034 §4), derived structurally at
  consumption time. Nothing is stored per value; the comparator (DR-035) calls
  these to separate correlation noise from behavioral signal.

  Three classes:
  - `:plan_generated` - a pure function of the effective seed.
  - `:run_scoped` - minted via `PropertyDamage.mint_per_run/1`; a function of
    nonce/epoch.
  - `:server_resolved` - produced by the SUT (captured via `external()` or just
    observed in output).

  Interpretation contract for the comparator: a cross-run difference in a
  `:run_scoped` value is expected (a correlation id, never suspicious); in a
  `:server_resolved` value it is an observed behavioral difference (the
  subject); in a `:plan_generated` value it is a comparability violation
  (different plans).
  """

  alias PropertyDamage.{External, Mint, Placeholder, RunTrace, Sequence}

  @type class :: :plan_generated | :run_scoped | :server_resolved

  @doc """
  Classify a command field from its value in the **plan** (DR-034 §4).

  A mint marker → `:run_scoped`; a placeholder (filled from SUT output) →
  `:server_resolved`; anything else → `:plan_generated`. Pass the *plan* value
  (the symbolic command), not the resolved one.
  """
  @spec command_field(term()) :: class()
  def command_field(%Mint{}), do: :run_scoped
  def command_field(%Placeholder{}), do: :server_resolved
  def command_field(_), do: :plan_generated

  @doc """
  Classify an event field (DR-034 §4).

  A path declared `external()` on the event module → `:server_resolved` by
  definition; a value that is a member of this run's minted-value set → a
  `:run_scoped` echo (the SUT reflecting a correlation id back; value-membership
  is sound because minted kinds are high-entropy); everything else is observed
  SUT output, treated as `:server_resolved`. Event fields are never
  `:plan_generated`.
  """
  @spec event_field(module(), [term()], term(), MapSet.t()) :: class()
  def event_field(event_module, path, value, minted_set) do
    cond do
      path in external_paths(event_module) -> :server_resolved
      MapSet.member?(minted_set, value) -> :run_scoped
      true -> :server_resolved
    end
  end

  @doc """
  The set of concrete client-minted values in a run.

  Correlates each plan command's mint-marked field paths with the resolved value
  at that path in the trace's `executed` command. Used to recognize minted
  echoes in event fields by value.
  """
  @spec minted_value_set(RunTrace.t()) :: MapSet.t()
  def minted_value_set(%RunTrace{plan: nil}), do: MapSet.new()

  def minted_value_set(%RunTrace{plan: %Sequence{} = plan, executed: executed}) do
    plan
    |> Sequence.indexed()
    |> Enum.flat_map(fn {position, _idx, plan_command} ->
      case Map.get(executed, position) do
        nil ->
          []

        exec_command ->
          plan_command
          |> mint_paths()
          |> Enum.map(&External.get_at_path(exec_command, &1))
      end
    end)
    |> MapSet.new()
  end

  @doc "The field paths in `value` that hold an unresolved mint marker."
  @spec mint_paths(term()) :: [[term()]]
  def mint_paths(value), do: value |> collect_mint_paths([], []) |> Enum.reverse()

  defp collect_mint_paths(%Mint{}, rpath, acc), do: [Enum.reverse(rpath) | acc]
  defp collect_mint_paths(%Placeholder{}, _rpath, acc), do: acc

  defp collect_mint_paths(%{__struct__: _} = struct, rpath, acc) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(acc, fn {k, v}, a -> collect_mint_paths(v, [k | rpath], a) end)
  end

  defp collect_mint_paths(map, rpath, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {k, v}, a -> collect_mint_paths(v, [k | rpath], a) end)
  end

  defp collect_mint_paths(list, rpath, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {v, i}, a -> collect_mint_paths(v, [i | rpath], a) end)
  end

  defp collect_mint_paths(_other, _rpath, acc), do: acc

  # External.external_paths/1 reads the module's struct defaults for external()
  # sentinels; degrade to [] for a module that has none / is unavailable.
  defp external_paths(module) do
    External.external_paths(module)
  rescue
    _ -> []
  end
end
