defmodule PropertyDamage.Corpus.FireLog do
  @moduledoc """
  A record of when a seeded bug's path ran.

  The harness starts one log per seed and hands it to the system. A system
  calls `started/1` when a fresh instance of it starts and `fired/1` each time
  its buggy path executes. The harness then reads whether the bug fired,
  without relying on the shape of the shrunk plan.
  """

  use Agent

  @type t :: pid()

  @doc "Starts an empty log, linked to the caller."
  @spec start_link() :: {:ok, t()}
  def start_link, do: Agent.start_link(fn -> %{instances: 0, fires: %{}} end)

  @doc "Stops the log."
  @spec stop(t()) :: :ok
  def stop(log), do: Agent.stop(log)

  @doc "Records that a system instance started; returns its instance number."
  @spec started(t() | nil) :: non_neg_integer()
  def started(nil), do: 0

  def started(log) do
    Agent.get_and_update(log, fn state ->
      number = state.instances + 1
      {number, %{state | instances: number}}
    end)
  end

  @doc "Records that the buggy path ran in system instance `instance`."
  @spec fired(t() | nil, non_neg_integer()) :: :ok
  def fired(nil, _instance), do: :ok

  def fired(log, instance) do
    Agent.update(log, fn state ->
      %{state | fires: Map.update(state.fires, instance, 1, &(&1 + 1))}
    end)
  end

  @doc "How many times the buggy path ran across every instance."
  @spec total(t()) :: non_neg_integer()
  def total(log), do: Agent.get(log, fn state -> state.fires |> Map.values() |> Enum.sum() end)

  @doc "Whether the buggy path ran in the most recently started instance."
  @spec fired_in_last_instance?(t()) :: boolean()
  def fired_in_last_instance?(log) do
    Agent.get(log, fn state -> Map.has_key?(state.fires, state.instances) end)
  end
end
