defmodule Factory.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(idle running waiting error done)
  @kinds ~w(general orchestrator planner coder tester reviewer researcher writer action)

  # Agents that only look: they read and search the project, never change it. What they
  # read may be a stranger's pull request, so fetching a web page is asked about first:
  # an injected prompt could otherwise send what they read to any address.
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
    # An agent that only reads asks before it fetches a web page, unless this is set.
    field :web, :boolean, default: false
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0
    # For kind "action": %{"type" => …, "config" => %{…}} (see Factory.Actions).
    field :action, :map, default: %{}
    belongs_to :workflow, Factory.Agents.Workflow

    timestamps(type: :utc_datetime)
  end

  @doc """
  The Kiro tool kinds an agent may use, the same in a chat and in a run: reading and
  searching for the kinds that only look (planner, researcher, reviewer), everything
  for the rest. Kiro asks before it edits or runs a command; other requests are denied,
  except that the person is asked when one that only looks wants to fetch a web page
  (see `Factory.Kiro.Session`), unless it's set to search the web (`web?/1`).
  """
  def tools(%{kind: kind} = agent) when kind in @read_only,
    do: if(web?(agent), do: @read_tools ++ ["fetch"], else: @read_tools)

  def tools(_agent), do: @all_tools

  @doc """
  Whether the agent searches the web without asking. The ones that only look ask first
  (their reading could be steered to send what they read anywhere), except one set to
  (`web`), given claims to check rather than the raw material, like the Fact Checker.
  """
  def web?(agent), do: Map.get(agent, :web) == true

  @doc "Whether the agent only reads and checks, never changes the project."
  def read_only?(%{kind: kind}), do: kind in @read_only

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
      :kiro_mode,
      :session,
      :x,
      :y,
      :workflow_id,
      :action,
      :web
    ])
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
