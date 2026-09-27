defmodule Factory.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(idle running waiting error done)
  @models ~w(claude-opus-5-5 claude-sonnet-5 claude-haiku-4-5)

  schema "agents" do
    field :name, :string
    field :role, :string, default: ""
    field :model, :string, default: "claude-sonnet-5"
    field :status, :string, default: "idle"
    field :activity, :string
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0

    timestamps(type: :utc_datetime)
  end

  def models, do: @models

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :role, :model, :status, :activity, :x, :y])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 40)
    |> validate_inclusion(:status, @statuses)
  end
end
