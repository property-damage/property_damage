defmodule ObanBench.Repo.Migrations.AppliedLedger do
  use Ecto.Migration

  # Idempotency ledger for the retry exactly-once bench: one row per job id that
  # has already had its effect applied. The faithful worker consults it so a
  # retried job increments the counter only once.
  def up do
    create_if_not_exists table(:applied, primary_key: false) do
      add(:job_id, :bigint, primary_key: true)
    end
  end

  def down do
    drop_if_exists(table(:applied))
  end
end
