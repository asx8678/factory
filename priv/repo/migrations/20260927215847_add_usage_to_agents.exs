defmodule Factory.Repo.Migrations.AddUsageToAgents do
  use Ecto.Migration

  # Running totals from Kiro, e.g.
  # %{"turns" => 12, "credits" => 0.84, "context_pct" => 1.9, "context_tokens" => 19000, "window" => 1_000_000}
  def change do
    alter table(:agents) do
      add :usage, :map, null: false, default: %{}
    end
  end
end
