defmodule Factory.Repo.Migrations.AddBaseSpecs do
  use Ecto.Migration

  # Base specs are kept for every run (company rules, conventions); run specs are one run's
  # own. A workflow says which base specs its runs start with.
  def change do
    alter table(:specs) do
      add :kind, :string, null: false, default: "run"
    end

    create index(:specs, [:kind])

    alter table(:workflows) do
      add :base_spec_ids, {:array, :integer}, null: false, default: []
    end
  end
end
