defmodule Factory.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  # Agents now belong to named workflows. The standard ones (key "feature", "bug", …)
  # are created by the app; agents made before this move into "My workflow", which
  # plain chats keep using.
  def change do
    create table(:workflows) do
      add :name, :string, null: false
      add :key, :string
      add :description, :text, null: false, default: ""
      add :current, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflows, [:key])

    alter table(:agents) do
      add :workflow_id, references(:workflows, on_delete: :delete_all)
    end

    create index(:agents, [:workflow_id])

    execute(
      """
      WITH mine AS (
        INSERT INTO workflows (name, description, current, inserted_at, updated_at)
        SELECT 'My workflow', 'The agents you made before workflows had names.', true, now(), now()
        WHERE EXISTS (SELECT 1 FROM agents)
        RETURNING id
      )
      UPDATE agents SET workflow_id = (SELECT id FROM mine) WHERE workflow_id IS NULL
      """,
      ""
    )
  end
end
