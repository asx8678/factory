defmodule Factory.Repo.Migrations.AddWebToAgents do
  use Ecto.Migration

  # An agent that only reads asks before it fetches a web page (Factory.Kiro.Session);
  # one with `web` set searches the web without asking, like the troubleshooting
  # workflow's Fact Checker.
  def change do
    alter table(:agents) do
      add :web, :boolean, null: false, default: false
    end
  end
end
