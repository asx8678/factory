defmodule Factory.Runs.Setup do
  @moduledoc "A saved setup: the choices of a factory run, kept to start the next one from."
  use Ecto.Schema
  import Ecto.Changeset

  schema "run_setups" do
    field :name, :string
    field :kind, :string
    field :settings, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def changeset(setup, attrs) do
    setup
    |> cast(attrs, [:name, :kind, :settings])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :kind])
    |> validate_length(:name, max: 60)
  end
end
