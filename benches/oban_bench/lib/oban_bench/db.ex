defmodule ObanBench.DB do
  @moduledoc "Small DB helpers shared by the worker, adapter and pollers."

  alias ObanBench.Repo

  @doc "Atomically add one to the counter named `name`, creating it at 1."
  def increment(name) do
    Repo.query!(
      "INSERT INTO counters (name, value) VALUES ($1, 1) " <>
        "ON CONFLICT (name) DO UPDATE SET value = counters.value + 1",
      [name]
    )

    :ok
  end

  @doc "Current value of the counter named `name`, or 0 if it does not exist."
  def value(name) do
    case Repo.query!("SELECT value FROM counters WHERE name = $1", [name]) do
      %{rows: [[v]]} -> v
      %{rows: []} -> 0
    end
  end

  @doc "Lifecycle state of an Oban job by id (\"completed\", \"discarded\", ...)."
  def job_state(job_id) do
    case Repo.query!("SELECT state FROM oban_jobs WHERE id = $1", [job_id]) do
      %{rows: [[state]]} -> state
      %{rows: []} -> nil
    end
  end
end
