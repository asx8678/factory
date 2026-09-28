defmodule Factory.Agents.Link do
  use Ecto.Schema
  import Ecto.Changeset

  @sides ~w(top right bottom left)

  schema "links" do
    belongs_to :source, Factory.Agents.Agent
    belongs_to :target, Factory.Agents.Agent
    field :source_handle, :string
    field :target_handle, :string
    # Said to the receiving agent when work is handed over along this arrow.
    field :prompt, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:source_id, :target_id, :source_handle, :target_handle, :prompt],
      empty_values: []
    )
    |> update_change(:prompt, &String.trim/1)
    |> validate_length(:prompt, max: 20_000)
    |> validate_inclusion(:source_handle, @sides)
    |> validate_inclusion(:target_handle, @sides)
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
