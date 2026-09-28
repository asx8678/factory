defmodule Factory.Repo.Migrations.AddKiroRuntime do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      # nil = not connected; "kiro_v3" = kiro-cli acp --agent-engine v3
      add :runtime, :string
      add :kiro_mode, :string, null: false, default: "vibe"
      # Folder Kiro works in; nil uses the configured default workspace
      add :workdir, :string
    end

    alter table(:messages) do
      # Agent name for replies written by an agent; nil for the factory itself
      add :author, :string
      # e.g. %{"agent_id" => 3, "credits" => 0.06, "stop_reason" => "end_turn"}
      add :meta, :map, null: false, default: %{}
    end
  end
end
