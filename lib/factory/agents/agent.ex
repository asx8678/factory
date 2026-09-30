defmodule Factory.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(idle running waiting error done)
  @kinds ~w(general orchestrator planner coder tester reviewer researcher writer action)

  # Agents that only look: they read and search the project, never change it. They
  # have no web access (`fetch`): an agent that can read any file and also reach the
  # web could carry what it read out of the machine, so only agents a person already
  # trusts to edit and run commands may fetch.
  @read_only ~w(planner researcher reviewer)
  @read_tools ~w(read search think)
  @all_tools ~w(read search think fetch edit delete move execute other)

  schema "agents" do
    field :name, :string
    field :role, :string, default: ""
    field :model, :string, default: "auto"
    field :status, :string, default: "idle"
    field :activity, :string
    field :kind, :string, default: "general"
    field :prompt, :string, default: ""
    field :usage, :map, default: %{}
    field :session, :string, default: "own"
    field :kiro_mode, :string, default: "vibe"
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0
    # For kind "action": %{"type" => …, "config" => %{…}} (see Factory.Actions).
    field :action, :map, default: %{}
    belongs_to :workflow, Factory.Agents.Workflow

    timestamps(type: :utc_datetime)
  end

  @doc """
  The Kiro tool kinds an agent may use, the same in a chat and in a run: reading and
  searching for the kinds that only look (planner, researcher, reviewer), everything,
  the web included, for the rest. Kiro asks before it edits or runs a command; other
  requests are denied. Reading, searching and editing are also kept to the project
  folder and the agent's attached sources (`Factory.Kiro.Session`).
  """
  def tools(%{kind: kind}) when kind in @read_only, do: @read_tools
  def tools(_agent), do: @all_tools

  @doc "Whether the agent only reads and checks, never changes the project."
  def read_only?(%{kind: kind}), do: kind in @read_only

  def kinds, do: @kinds

  @doc "Whether this card is an action (commit, open a PR, email…) rather than an agent."
  def action?(%__MODULE__{kind: kind}), do: kind == "action"

  # What a person may change on an agent's card and in its side panel. The rest
  # (`status`, `activity`, `usage`, `workflow_id`) is Factory's own and set in code.
  @editable [:name, :role, :kind, :prompt, :model, :kiro_mode, :session, :x, :y, :action]

  @doc """
  The full changeset for Factory's own use (`Factory.Agents.create_agent/1`): it also
  takes `status` and `activity`. The workflow is set on the struct, never cast.
  """
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, @editable ++ [:status, :activity])
    |> validate()
  end

  @doc "The changeset for what a person edits: name, role, kind, prompt, model, mode, session, place and action."
  def edit_changeset(agent, attrs) do
    agent
    |> cast(attrs, @editable)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 40)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    # Ecto casts a cleared text box to nil; the column keeps "" for "no context".
    |> update_change(:prompt, &(&1 || ""))
    |> validate_length(:prompt, max: 20_000)
    |> validate_inclusion(:session, ["own", "shared"])
    |> kiro_defaults()
  end

  # Agents run on Kiro: they need a model and mode Kiro knows; an unknown model is "auto".
  defp kiro_defaults(changeset) do
    changeset =
      if get_field(changeset, :model) in Factory.Kiro.models(),
        do: changeset,
        else: put_change(changeset, :model, "auto")

    validate_inclusion(changeset, :kiro_mode, Factory.Kiro.modes())
  end
end
