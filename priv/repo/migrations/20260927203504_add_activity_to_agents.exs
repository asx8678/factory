defmodule Factory.Repo.Migrations.AddActivityToAgents do
  use Ecto.Migration

  # What the agent is doing right now, e.g. "Task 2: Add login form". Set by the run engine.
  def change do
    alter table(:agents) do
      add :activity, :string
    end
  end
end
