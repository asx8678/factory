defmodule Factory.Repo.Migrations.AddOverviewToSpecs do
  use Ecto.Migration

  # The main spec file, a new first step before requirements. Specs that already
  # exist count it as done, so their steps stay open.
  def change do
    alter table(:specs) do
      add :overview, :text, null: false, default: ""
      add :overview_approved_at, :utc_datetime
    end

    execute "UPDATE specs SET overview_approved_at = inserted_at", ""
  end
end
