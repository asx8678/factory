defmodule Factory.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  # draft: chatting, maybe a spec attached. queued/running/paused: started. done/cancelled: finished.
  @statuses ~w(draft queued running paused done cancelled)

  schema "runs" do
    field :title, :string
    field :status, :string, default: "draft"
    field :spec_files, {:array, :string}, default: []
    field :spec, :string
    has_many :tasks, Factory.Runs.Task, preload_order: [asc: :position]
    has_many :messages, Factory.Runs.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:title, :status, :spec_files, :spec])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 80)
    |> validate_inclusion(:status, @statuses)
  end
end
