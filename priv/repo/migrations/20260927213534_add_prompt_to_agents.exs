defmodule Factory.Repo.Migrations.AddPromptToAgents do
  use Ecto.Migration

  # The agent's context: instructions sent to Kiro at the start of each session.
  def change do
    alter table(:agents) do
      add :prompt, :text, null: false, default: ""
    end
  end
end
