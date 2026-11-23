defmodule PropertyDamage.Next.AssignCounts do
  @moduledoc false
  # The assign counts of one search: per target (the adapter module),
  # command module and key, how many executed steps set the assign and how
  # many times a port acknowledged it. The counts live in a public ETS table
  # so that a port acknowledging from a process other than the one that runs
  # the step still counts.

  @type row :: %{
          command: module(),
          key: atom(),
          set: non_neg_integer(),
          acknowledged: non_neg_integer()
        }

  @spec new() :: :ets.tid()
  def new, do: :ets.new(__MODULE__, [:set, :public])

  @spec delete(:ets.tid()) :: true
  def delete(table), do: :ets.delete(table)

  @doc "Counts one executed step that set `key`."
  @spec record_set(:ets.tid(), module(), module(), atom()) :: :ok
  def record_set(table, target, command, key), do: bump(table, {:set, target, command, key})

  @doc "Counts one acknowledgment of `key` at a step of `command`."
  @spec record_acknowledged(:ets.tid(), module(), module(), atom()) :: :ok
  def record_acknowledged(table, target, command, key),
    do: bump(table, {:acknowledged, target, command, key})

  defp bump(table, key) do
    :ets.update_counter(table, key, 1, {key, 0})
    :ok
  end

  @doc """
  The counts as `%{target => [row]}`, rows sorted by command and key. A
  key appears once something set it.
  """
  @spec rows(:ets.tid()) :: %{module() => [row()]}
  def rows(table) do
    counts = :ets.tab2list(table)

    counts
    |> Enum.flat_map(fn
      {{:set, target, command, key}, set} -> [{target, command, key, set}]
      {{:acknowledged, _target, _command, _key}, _count} -> []
    end)
    |> Enum.sort()
    |> Enum.group_by(&elem(&1, 0), fn {target, command, key, set} ->
      acknowledged =
        case :ets.lookup(table, {:acknowledged, target, command, key}) do
          [{_, count}] -> count
          [] -> 0
        end

      %{command: command, key: key, set: set, acknowledged: acknowledged}
    end)
  end
end
