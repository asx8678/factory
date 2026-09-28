defmodule Factory.Repo.Migrations.CreateSpecs do
  use Ecto.Migration

  def change do
    create table(:specs) do
      add :name, :string, null: false
      add :requirements, :text, null: false, default: ""
      add :design, :text, null: false, default: ""
      add :tasks, :text, null: false, default: ""
      add :requirements_approved_at, :utc_datetime
      add :design_approved_at, :utc_datetime
      add :tasks_approved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    alter table(:runs) do
      add :spec_id, references(:specs, on_delete: :nilify_all)
    end

    create index(:runs, [:spec_id])
  end
end
