defmodule Factory.Repo.Migrations.CreateUsageEvents do
  use Ecto.Migration

  # One row per call to Kiro: what it was for, what it cost, and where it belongs.
  def change do
    create table(:usage_events) do
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :spec_id, references(:specs, on_delete: :nilify_all)
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :source, :string, null: false
      add :model, :string
      add :credits, :float, null: false, default: 0.0
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :ms, :integer
      add :ok, :boolean, null: false, default: true
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:usage_events, [:inserted_at])
    create index(:usage_events, [:run_id])
    create index(:usage_events, [:spec_id])
  end
end
