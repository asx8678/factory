defmodule Factory.Runs.Task do
  use Ecto.Schema

  schema "tasks" do
    belongs_to :run, Factory.Runs.Run
    field :position, :integer
    field :ref, :string
    field :title, :string
    field :status, :string, default: "pending"

    timestamps(type: :utc_datetime)
  end
end
