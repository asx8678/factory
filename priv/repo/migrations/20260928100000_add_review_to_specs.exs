defmodule Factory.Repo.Migrations.AddReviewToSpecs do
  use Ecto.Migration

  def change do
    alter table(:specs) do
      add :review, :map, null: false, default: %{}
    end
  end
end
