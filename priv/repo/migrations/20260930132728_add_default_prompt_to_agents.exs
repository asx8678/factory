defmodule Factory.Repo.Migrations.AddDefaultPromptToAgents do
  use Ecto.Migration

  # The prompt Factory last gave a standard workflow's agent (Factory.Workflows): while
  # the agent's prompt is still that one, a newer version replaces it at startup.
  def change do
    alter table(:agents) do
      add :default_prompt, :text
    end
  end
end
