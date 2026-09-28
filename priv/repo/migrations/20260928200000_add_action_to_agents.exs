defmodule Factory.Repo.Migrations.AddActionToAgents do
  use Ecto.Migration

  # Actions are cards in a workflow like agents (kind "action"), placed between agents
  # or after them: commit and push, open a PR, update a ticket, send an email…
  # `action` holds %{"type" => …, "config" => %{…}}. See Factory.Actions.
  def change do
    alter table(:agents) do
      add :action, :map, null: false, default: %{}
    end
  end
end
