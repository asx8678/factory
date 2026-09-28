defmodule Factory.Repo.Migrations.AddPromptToLinks do
  use Ecto.Migration

  def change do
    alter table(:links) do
      # Said to the receiving agent when work is handed over along this arrow.
      add :prompt, :text, null: false, default: ""
    end
  end
end
