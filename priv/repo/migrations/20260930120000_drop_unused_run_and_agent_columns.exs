defmodule Factory.Repo.Migrations.DropUnusedRunAndAgentColumns do
  use Ecto.Migration

  # Columns and a table nothing reads any more: a run's plan lives in its spec
  # (Factory.Specs), saved setups were never built, and an agent's runtime and
  # folder are Kiro's (Factory.Kiro). An agent's model defaults to "auto", as the
  # schema says (Factory.Agents.Agent), rather than a model that may not exist.
  def up do
    alter table(:runs) do
      remove :plan
    end

    drop table(:run_setups)

    alter table(:agents) do
      remove :runtime
      remove :workdir
      modify :model, :string, null: false, default: "auto"
    end
  end

  def down do
    alter table(:agents) do
      modify :model, :string, null: false, default: "claude-sonnet-5"
      add :workdir, :string
      add :runtime, :string
    end

    create table(:run_setups) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :settings, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    alter table(:runs) do
      add :plan, :map, null: false, default: %{}
    end
  end
end
