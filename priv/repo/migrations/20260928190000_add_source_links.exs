defmodule Factory.Repo.Migrations.AddSourceLinks do
  use Ecto.Migration

  # Data sources become cards on the canvas, attached to agents by arrows: only the
  # agents a source is attached to get it in their prompt. Existing sources line up
  # left of the agents, attached to none until the person draws the arrows.
  def change do
    alter table(:data_sources) do
      add :x, :float, null: false, default: 0.0
      add :y, :float, null: false, default: 0.0
    end

    create table(:source_links) do
      add :source_id, references(:data_sources, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:source_links, [:source_id, :agent_id])
    create index(:source_links, [:agent_id])

    execute(
      """
      UPDATE data_sources d SET
        x = COALESCE((SELECT min(a.x) FROM agents a WHERE a.workflow_id = d.workflow_id), 0) - 320,
        y = COALESCE((SELECT min(a.y) FROM agents a WHERE a.workflow_id = d.workflow_id), 0)
            + 110 * (SELECT count(*) FROM data_sources e WHERE e.workflow_id = d.workflow_id AND e.id < d.id)
      """,
      ""
    )
  end
end
