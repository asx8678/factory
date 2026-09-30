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
    # A factory run's type ("feature", "bug", …, see Factory.Runs.Types); nil for a plain chat.
    field :kind, :string
    # What the person asked for, as they wrote it.
    field :description, :string, default: ""
    # How the factory works on it: workflow, setup, plan approval, project folder.
    field :settings, :map, default: %{}
    # The engine's way through the workflow (see Factory.Engine):
    # %{"done" => [step ids], "outputs" => %{step id => text}, "current" => id, "error" => text}.
    field :progress, :map, default: %{}
    # Only the latest chat planner request may replace this run's draft tasks.
    field :planner_generation, :binary_id
    belongs_to :spec_doc, Factory.Specs.Spec, foreign_key: :spec_id
    has_many :tasks, Factory.Runs.Task, preload_order: [asc: :position]
    has_many :messages, Factory.Runs.Message

    timestamps(type: :utc_datetime)
  end

  @doc """
  Factory's own changeset: `Factory.Runs.update_run/2` is only ever called with
  attributes built in code (a status the engine sets, settings the chat chose). Form
  params never reach it: a person renames a run through `/rename`, which passes the
  title alone.
  """
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :title,
      :status,
      :spec_files,
      :spec,
      :spec_id,
      :kind,
      :description,
      :settings,
      :progress
    ])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 80)
    |> validate_inclusion(:status, @statuses)
  end
end
