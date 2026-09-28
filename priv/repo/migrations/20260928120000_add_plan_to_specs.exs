defmodule Factory.Repo.Migrations.AddPlanToSpecs do
  use Ecto.Migration

  def change do
    alter table(:specs) do
      add :project_dir, :string
      add :plan, :map, null: false, default: %{}
    end
  end
end
