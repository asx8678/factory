defmodule Factory.Repo.Migrations.AddHandlesToLinks do
  use Ecto.Migration

  # Which circle on each agent the arrow is attached to: "top", "right", "bottom" or "left".
  # nil means "the sides facing each other".
  def change do
    alter table(:links) do
      add :source_handle, :string
      add :target_handle, :string
    end
  end
end
