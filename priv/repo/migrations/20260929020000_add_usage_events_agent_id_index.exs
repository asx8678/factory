defmodule Factory.Repo.Migrations.AddUsageEventsAgentIdIndex do
  use Ecto.Migration

  def change do
    create index(:usage_events, [:agent_id])
  end
end
