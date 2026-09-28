defmodule Factory.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(idle running waiting error done)
  @kinds ~w(general orchestrator planner coder tester reviewer researcher writer action)
  @models ~w(claude-opus-5-5 claude-sonnet-5 claude-haiku-4-5)

  schema "agents" do
    field :name, :string
    field :role, :string, default: ""
    field :model, :string, default: "claude-sonnet-5"
    field :status, :string, default: "idle"
    field :activity, :string
    field :kind, :string, default: "general"
    field :prompt, :string, default: ""
    field :usage, :map, default: %{}
    field :session, :string, default: "own"
    field :runtime, :string
    field :kiro_mode, :string, default: "vibe"
    field :workdir, :string
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0
    # For kind "action": %{"type" => …, "config" => %{…}} (see Factory.Actions).
    field :action, :map, default: %{}
    belongs_to :workflow, Factory.Agents.Workflow

    timestamps(type: :utc_datetime)
  end

  @runtimes [{"Not connected", ""}, {"Kiro ACP (v3)", "kiro_v3"}]

  def runtimes, do: @runtimes

  @doc "Models to offer for an agent: Kiro's when it runs on Kiro, otherwise the plain list."
  def models(%__MODULE__{runtime: "kiro_v3"}), do: Factory.Kiro.models()
  def models(_agent), do: @models

  def kinds, do: @kinds

  @doc "Whether this card is an action (commit, open a PR, email…) rather than an agent."
  def action?(%__MODULE__{kind: kind}), do: kind == "action"

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :role,
      :kind,
      :prompt,
      :model,
      :status,
      :activity,
      :runtime,
      :kiro_mode,
      :session,
      :workdir,
      :x,
      :y,
      :workflow_id,
      :action
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 40)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    # Ecto casts a cleared text box to nil; the column keeps "" for "no context".
    |> update_change(:prompt, &(&1 || ""))
    |> validate_length(:prompt, max: 20_000)
    |> validate_inclusion(:runtime, ["kiro_v3"])
    |> validate_inclusion(:session, ["own", "shared"])
    |> kiro_defaults()
  end

  # A Kiro agent needs a model and mode Kiro knows; switching to Kiro picks "auto".
  defp kiro_defaults(changeset) do
    if get_field(changeset, :runtime) == "kiro_v3" do
      changeset =
        if get_field(changeset, :model) in Factory.Kiro.models(),
          do: changeset,
          else: put_change(changeset, :model, "auto")

      validate_inclusion(changeset, :kiro_mode, Factory.Kiro.modes())
    else
      changeset
    end
  end
end
