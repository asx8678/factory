defmodule Factory.Repo.Migrations.CreateDataSources do
  use Ecto.Migration

  # Outside material a workflow's agents work from: repositories, folders,
  # instruction files, meta indexes. See Factory.Sources.
  def change do
    create table(:data_sources) do
      add :workflow_id, references(:workflows, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :name, :string, null: false
      add :config, :map, null: false, default: %{}
      add :content, :text, null: false, default: ""
      add :enabled, :boolean, null: false, default: true
      add :status, :string, null: false, default: "ready"
      add :error, :text
      add :synced_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:data_sources, [:workflow_id])
  end
end
