defmodule Factory.Repo.Migrations.CreateAgentsAndLinks do
  use Ecto.Migration

  def change do
    create table(:agents) do
      add :name, :string, null: false
      add :role, :string, null: false, default: ""
      add :model, :string, null: false, default: "claude-sonnet-5"
      add :status, :string, null: false, default: "idle"
      add :x, :float, null: false, default: 0.0
      add :y, :float, null: false, default: 0.0

      timestamps(type: :utc_datetime)
    end

    create table(:links) do
      add :source_id, references(:agents, on_delete: :delete_all), null: false
      add :target_id, references(:agents, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:links, [:source_id, :target_id])
    create index(:links, [:target_id])
  end
end
