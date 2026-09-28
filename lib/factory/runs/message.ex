defmodule Factory.Runs.Message do
  use Ecto.Schema

  # role: "user" or "factory". actions: buttons shown under a factory message, e.g. ["start"].
  schema "messages" do
    belongs_to :run, Factory.Runs.Run
    field :role, :string
    field :body, :string, default: ""
    field :attachments, {:array, :string}, default: []
    field :actions, {:array, :string}, default: []
    field :author, :string
    field :meta, :map, default: %{}

    timestamps(type: :utc_datetime)
  end
end
