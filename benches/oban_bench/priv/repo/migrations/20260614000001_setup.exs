defmodule ObanBench.Repo.Migrations.Setup do
  use Ecto.Migration

  def up do
    Oban.Migration.up()

    # The async work's side effect: a per-name counter the workers increment.
    create_if_not_exists table(:counters, primary_key: false) do
      add(:name, :text, primary_key: true)
      add(:value, :bigint, null: false, default: 0)
    end
  end

  def down do
    drop_if_exists(table(:counters))
    Oban.Migration.down(version: 1)
  end
end
