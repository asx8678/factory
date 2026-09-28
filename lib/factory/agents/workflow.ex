defmodule Factory.Agents.Workflow do
  @moduledoc """
  A named set of agents and the hand-offs between them. Standard workflows have a
  `key` (the run type they're for, see `Factory.Runs.Types`) and can be restored to
  their default; custom ones have none. The `current` one is what plain chats use.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "workflows" do
    field :name, :string
    field :key, :string
    field :description, :string, default: ""
    field :current, :boolean, default: false
    has_many :agents, Factory.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
    |> update_change(:description, &(&1 || ""))
  end

  def standard?(%__MODULE__{key: key}), do: key != nil
end
