defmodule FactoryWeb.RunParts do
  @moduledoc "Pieces shared by the pages about factory runs: the start screen, New run and a run."
  use FactoryWeb, :html
  alias Factory.Runs.Types
  alias FactoryWeb.UsageMeter, as: Fmt

  # Icon class names are written out in full so Tailwind's heroicons plugin sees them.
  @type_icons %{
    "feature" => {"hero-sparkles", "hero-sparkles-micro"},
    "bug" => {"hero-bug-ant", "hero-bug-ant-micro"},
    "issue" => {"hero-ticket", "hero-ticket-micro"},
    "deps" => {"hero-arrow-path", "hero-arrow-path-micro"},
    "other" => {"hero-chat-bubble-left-ellipsis", "hero-chat-bubble-left-ellipsis-micro"}
  }

  @kind_icons %{
    "general" => "hero-cpu-chip-micro",
    "orchestrator" => "hero-rectangle-group-micro",
    "planner" => "hero-clipboard-document-list-micro",
    "coder" => "hero-code-bracket-micro",
    "tester" => "hero-beaker-micro",
    "reviewer" => "hero-magnifying-glass-micro",
    "researcher" => "hero-book-open-micro",
    "writer" => "hero-pencil-square-micro"
  }

  @doc "A run type's icon, `:outline` (24px) or `:micro` (16px)."
  def type_icon(kind, :outline), do: @type_icons |> Map.get(kind, @type_icons["other"]) |> elem(0)
  def type_icon(kind, :micro), do: @type_icons |> Map.get(kind, @type_icons["other"]) |> elem(1)

  @doc "An agent kind's 16px icon."
  def kind_icon(kind), do: Map.get(@kind_icons, kind, "hero-cpu-chip-micro")

  attr :kind, :string, default: nil
  attr :class, :string, default: nil

  @doc "The run's type as a small label: Bug fix, Feature…"
  def type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide",
      if(@kind, do: "bg-primary/15 text-primary", else: "bg-base-content/10 text-base-content/60"),
      @class
    ]}>
      <.icon :if={@kind} name={type_icon(@kind, :micro)} class="size-3" />
      {Types.short(@kind)}
    </span>
    """
  end

  attr :steps, :list, required: true
  attr :class, :string, default: nil

  @doc "A workflow in one line: Investigator → Fixer → Tester → Reviewer."
  def chain(assigns) do
    ~H"""
    <span class={["flex flex-wrap items-center gap-1 text-xs text-base-content/60", @class]}>
      <%!-- Each arrow stays on the line of the step it points to. --%>
      <span :for={{step, i} <- Enum.with_index(@steps)} class="inline-flex items-center gap-1">
        <.icon :if={i > 0} name="hero-arrow-long-right-micro" class="size-3.5 text-base-content/30" />
        <span class="inline-flex items-center gap-1 rounded-md bg-base-content/[0.06] px-1.5 py-0.5">
          <.icon name={kind_icon(step["kind"])} class="size-3 opacity-70" />
          {step["name"]}
        </span>
      </span>
    </span>
    """
  end

  attr :totals, :map, required: true
  attr :class, :string, default: nil

  @doc "Credits and estimated tokens, e.g. ⚡0.62 ≈41k."
  def usage(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-2 text-xs tabular-nums", @class]}>
      <span class="inline-flex items-center gap-0.5 font-medium">
        <.icon name="hero-bolt-micro" class="size-3.5 text-warning/80" />{Fmt.credits(@totals.credits)}
      </span>
      <span class="text-base-content/50">≈{Fmt.tokens(@totals.tokens)}</span>
    </span>
    """
  end

  attr :run, :map, required: true

  @doc "Where a run is, in a few words."
  def run_state(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 text-xs text-base-content/60">
      <span class={["size-1.5 rounded-full", state_dot(@run)]}></span>
      {state_text(@run)}
    </span>
    """
  end

  defp state_dot(%{plan: %{"status" => "writing"}}), do: "bg-info animate-pulse"
  defp state_dot(%{plan: %{"status" => "error"}}), do: "bg-error"
  defp state_dot(%{status: status}) when status in ~w(queued running), do: "bg-info"
  defp state_dot(%{status: "done"}), do: "bg-success"
  defp state_dot(_), do: "bg-base-content/30"

  def state_text(%{plan: %{"status" => "writing"}}), do: "Kiro is planning"
  def state_text(%{plan: %{"status" => "error"}}), do: "Planning failed"

  def state_text(%{kind: kind, status: "draft", tasks: []}) when not is_nil(kind),
    do: "Plan ready for review"

  def state_text(%{status: status}), do: String.capitalize(status)
end
