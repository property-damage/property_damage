defmodule ObanBench.DB do
  @moduledoc """
  Small DB helpers shared by the worker, adapter and pollers.

  The `logged_*` helpers and `insert_job/1` and `cancel_job/1` log each call
  and its answer under the calling step (`PropertyDamage.log/2`), so a failure
  report shows what each command did to the database. They need a log scope,
  so only adapter callbacks call them. The worker and the resource pollers run
  in processes that have no scope and call the plain helpers.
  """

  require PropertyDamage

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

  @doc """
  Increment `name` at most once per `job_id`, via the `applied` ledger. The
  first call for a given job inserts the ledger row and increments; later calls
  (a retry of the same job) hit the conflict and skip. This is how the faithful
  retry worker stays idempotent across attempts.
  """
  def increment_once(name, job_id) do
    case Repo.query!("INSERT INTO applied (job_id) VALUES ($1) ON CONFLICT DO NOTHING", [job_id]) do
      %{num_rows: 1} -> increment(name)
      %{num_rows: 0} -> :ok
    end
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

  @doc "`value/1`, logged under the calling step."
  def logged_value(name) do
    value = value(name)
    log_read("counter value", value, "name=#{name}")
    value
  end

  @doc "`job_state/1`, logged under the calling step."
  def logged_job_state(job_id) do
    state = job_state(job_id)
    log_read("job state", state, "id=#{job_id}")
    state
  end

  # The line carries the value read and nothing that changes between polls,
  # so a probe that re-reads an unchanged value prints identical lines.
  defp log_read(what, value, id) do
    PropertyDamage.log("query #{what} -> #{inspect(value)}  #{id}", tags: [:sql])
  end

  @doc """
  Insert an Oban job from `changeset` and log the outcome under the calling step.

  Returns what `Oban.insert/1` returns. A job that Oban's `unique` option
  deduplicated logs as `conflict`, with the id of the job it matched.
  """
  def insert_job(changeset) do
    result = Oban.insert(changeset)

    case result do
      {:ok, job} ->
        outcome = if job.conflict?, do: "conflict", else: "ok"

        details =
          [queue: job.queue, state: job.state, args: job.args, max_attempts: job.max_attempts] ++
            if job.state == "scheduled", do: [scheduled_at: job.scheduled_at], else: []

        PropertyDamage.log(
          "insert #{job.worker} job -> #{outcome}  id=#{job.id}\njob:\n" <>
            indent(inspect(details, pretty: true)),
          tags: [:oban]
        )

      {:error, reason} ->
        PropertyDamage.log(
          "insert #{changeset.changes[:worker]} job -> error\nerror:\n" <>
            indent(inspect(reason, pretty: true)),
          tags: [:oban]
        )
    end

    result
  end

  @doc "Cancel the Oban job `job_id` and log the call under the calling step."
  def cancel_job(job_id) do
    result = Oban.cancel_job(job_id)
    PropertyDamage.log("cancel job -> #{inspect(result)}  id=#{job_id}", tags: [:oban])
    result
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
end
