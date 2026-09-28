defmodule Factory.Repo.Migrations.EnforceWorkflowAndRunInvariants do
  use Ecto.Migration

  def up do
    create index(:runs, [:status],
             where: "status IN ('queued', 'running')",
             name: :runs_active_status_index
           )

    alter table(:runs) do
      add :planner_generation, :uuid
    end
  end

  def down do
    alter table(:runs) do
      remove :planner_generation
    end

    drop index(:runs, [:status], name: :runs_active_status_index)
  end
end
