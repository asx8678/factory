defmodule Factory.Agents.Link do
  use Ecto.Schema
  import Ecto.Changeset

  schema "links" do
    belongs_to :source, Factory.Agents.Agent
    belongs_to :target, Factory.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:source_id, :target_id])
    |> validate_required([:source_id, :target_id])
    |> validate_not_self()
    |> unique_constraint([:source_id, :target_id])
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:target_id)
  end

  defp validate_not_self(changeset) do
    if get_field(changeset, :source_id) == get_field(changeset, :target_id),
      do: add_error(changeset, :target_id, "can't link an agent to itself"),
      else: changeset
  end
end
