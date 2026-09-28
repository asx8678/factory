defmodule Factory.Repo.Migrations.AddKindToAgents do
  use Ecto.Migration

  # What the agent is for (planner, coder, tester, ...); picks its icon.
  def change do
    alter table(:agents) do
      add :kind, :string, null: false, default: "general"
    end
  end
end
