defmodule Factory.Repo.Migrations.AddSessionToAgents do
  use Ecto.Migration

  # "own": the agent has its own Kiro session. "shared": it talks in the one shared session.
  def change do
    alter table(:agents) do
      add :session, :string, null: false, default: "own"
    end
  end
end
