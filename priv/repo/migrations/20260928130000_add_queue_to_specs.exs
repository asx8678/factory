defmodule Factory.Repo.Migrations.AddQueueToSpecs do
  use Ecto.Migration

  def change do
    alter table(:specs) do
      add :queue, {:array, :string}, null: false, default: []
    end
  end
end
