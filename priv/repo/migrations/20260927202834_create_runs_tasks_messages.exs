defmodule Factory.Repo.Migrations.CreateRunsTasksMessages do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :title, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :spec_files, {:array, :string}, null: false, default: []
      add :spec, :text

      timestamps(type: :utc_datetime)
    end

    create table(:tasks) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :ref, :string
      add :title, :string, null: false
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:run_id, :position])

    create table(:messages) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :body, :text, null: false, default: ""
      add :attachments, {:array, :string}, null: false, default: []
      add :actions, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:run_id, :id])
  end
end
