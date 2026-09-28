defmodule Factory.Specs.Spec do
  @moduledoc """
  A spec written in four steps: the overview (the main spec file), then Kiro's
  requirements, design and tasks. Each step is approved before the next one opens.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @steps ~w(overview requirements design tasks)

  schema "specs" do
    field :name, :string
    field :overview, :string, default: ""
    field :requirements, :string, default: ""
    field :design, :string, default: ""
    field :tasks, :string, default: ""
    field :overview_approved_at, :utc_datetime
    field :requirements_approved_at, :utc_datetime
    field :design_approved_at, :utc_datetime
    field :tasks_approved_at, :utc_datetime

    # Kiro's latest review: %{"status" => "running" | "done" | "error", ...}. See Factory.Specs.Review.
    field :review, :map, default: %{}
    # Where Kiro reads the project when it suggests tasks.
    field :project_dir, :string
    # Kiro's task suggestions in progress. See Factory.Specs.plan_questions/2.
    field :plan, :map, default: %{}
    # Titles of the tasks queued for the next run, in run order.
    field :queue, {:array, :string}, default: []
    has_many :runs, Factory.Runs.Run, preload_order: [desc: :id]

    timestamps(type: :utc_datetime)
  end

  def steps, do: @steps

  def changeset(spec, attrs) do
    spec
    |> cast(attrs, [:name, :overview, :requirements, :design, :tasks])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    # Ecto casts a cleared text box to nil; the columns keep "".
    |> update_change(:overview, &(&1 || ""))
    |> update_change(:requirements, &(&1 || ""))
    |> update_change(:design, &(&1 || ""))
    |> update_change(:tasks, &(&1 || ""))
  end

  def approved?(spec, step), do: Map.fetch!(spec, approved_field(step)) != nil

  def approved_field(step) when step in @steps,
    do: String.to_existing_atom(step <> "_approved_at")

  @doc "A step can be written once every step before it is approved."
  def open?(_spec, "overview"), do: true
  def open?(spec, "requirements"), do: approved?(spec, "overview")
  def open?(spec, "design"), do: approved?(spec, "requirements")
  def open?(spec, "tasks"), do: approved?(spec, "design")

  @doc "The first step that isn't approved yet, or `\"ready\"` when all are."
  def current_step(spec),
    do: Enum.find(@steps, "ready", &(not approved?(spec, &1)))
end
