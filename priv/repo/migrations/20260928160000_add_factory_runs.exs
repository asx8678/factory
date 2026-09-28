defmodule Factory.Repo.Migrations.AddFactoryRuns do
  use Ecto.Migration

  # A factory run holds everything about one job: its type, what the person asked
  # for, how the factory should work, and Kiro's planning. Plain chats keep kind nil.
  # Saved setups are a run's choices kept to start the next run from.
  def change do
    alter table(:runs) do
      add :kind, :string
      add :description, :text, null: false, default: ""
      add :settings, :map, null: false, default: %{}
      add :plan, :map, null: false, default: %{}
    end

    create index(:runs, [:kind])

    create table(:run_setups) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :settings, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end
  end
end
