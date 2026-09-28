defmodule Factory.Repo.Migrations.AddProgressToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      # How far the engine got through the workflow (see Factory.Engine).
      add :progress, :map, null: false, default: %{}
    end
  end
end
