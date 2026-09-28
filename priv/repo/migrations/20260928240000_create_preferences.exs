defmodule Factory.Repo.Migrations.CreatePreferences do
  use Ecto.Migration

  # Things Factory remembers for you, e.g. the project folder picked last.
  def change do
    create table(:preferences, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end
  end
end
