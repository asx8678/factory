defmodule FactoryWeb.SpecParts do
  @moduledoc """
  Pieces for base specs: the company rules and conventions kept on the Specs page and
  included in runs, by default through a workflow or one by one in a run's chat.
  """
  use FactoryWeb, :html

  attr :id, :string, required: true
  attr :specs, :list, required: true, doc: "every base spec"
  attr :selected, :list, required: true, doc: "ids of the ones included"
  attr :event, :string, required: true, doc: "sent with `id` when one is clicked"
  attr :locked, :boolean, default: false

  @doc "Base specs to include or leave out, each with the start of what it says."
  def base_picker(assigns) do
    ~H"""
    <div id={@id}>
      <p
        :if={@specs == []}
        class="rounded-xl border border-dashed border-base-300 px-4 py-5 text-center text-sm text-base-content/55"
      >
        No base specs yet. Add your company's rules and conventions once, and include them
        in every run.
      </p>
      <ul
        :if={@specs != []}
        class="divide-y divide-base-300/70 overflow-hidden rounded-xl border border-base-300/70"
      >
        <li :for={s <- @specs}>
          <button
            id={"#{@id}-#{s.id}"}
            type="button"
            phx-click={@event}
            phx-value-id={s.id}
            disabled={@locked}
            aria-pressed={to_string(s.id in @selected)}
            class={[
              "flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm transition-colors disabled:cursor-default",
              if(s.id in @selected, do: "bg-primary/[0.07]", else: "hover:bg-base-200/60")
            ]}
          >
            <span class={[
              "grid size-4 shrink-0 place-items-center rounded border",
              if(s.id in @selected,
                do: "border-primary bg-primary text-primary-content",
                else: "border-base-content/30"
              )
            ]}>
              <.icon :if={s.id in @selected} name="hero-check-micro" class="size-3" />
            </span>
            <.category_icon spec={s} />
            <span class="w-40 shrink-0 truncate font-medium">{s.name}</span>
            <span class="min-w-0 flex-1 truncate text-base-content/55">{preview(s.overview)}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  @doc "The first line of a spec that says something (not a heading), for a preview."
  def preview(text) do
    text
    |> to_string()
    |> String.split(~r/\R/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("Empty", &(&1 != "" and not String.starts_with?(&1, "#")))
    |> String.replace(~r/^([-*+]|\d+[.)])\s+/, "")
  end

  # What a base spec is about, from its name and text: {label, icon, classes}. The icon
  # tells them apart; they share one quiet tile.
  # Icon names are written out in full so Tailwind's heroicons plugin sees them.
  @categories [
    {~r/secur|secret|auth|privacy/i, "Security", "hero-shield-check-mini",
     "bg-base-content/[0.06] text-base-content/65"},
    {~r/test|qa\b|quality/i, "Testing", "hero-beaker-mini",
     "bg-base-content/[0.06] text-base-content/65"},
    {~r/git|pull request|commit|branch|review/i, "Git", "hero-arrows-right-left-mini",
     "bg-base-content/[0.06] text-base-content/65"},
    {~r/access|a11y|\bui\b|design|css/i, "UI", "hero-eye-mini",
     "bg-base-content/[0.06] text-base-content/65"},
    {~r/doc|readme|changelog/i, "Docs", "hero-book-open-mini",
     "bg-base-content/[0.06] text-base-content/65"},
    {~r/./, "Code", "hero-code-bracket-mini", "bg-base-content/[0.06] text-base-content/65"}
  ]

  @doc "What a base spec is about: `{label, icon, classes}`."
  def category(spec) do
    # The name says it best; the text decides when the name doesn't.
    [spec.name, String.slice(spec.overview || "", 0, 300)]
    |> Enum.find_value(fn about ->
      Enum.find_value(Enum.drop(@categories, -1), fn {re, label, icon, classes} ->
        Regex.match?(re, about) && {label, icon, classes}
      end)
    end)
    |> Kernel.||(@categories |> List.last() |> Tuple.delete_at(0))
  end

  @doc "How many rules a base spec has: its list items, else its non-empty lines."
  def rule_count(text) do
    lines = text |> to_string() |> String.split(~r/\R/u) |> Enum.map(&String.trim/1)

    case Enum.count(lines, &Regex.match?(~r/^([-*+]|\d+[.)])\s+/, &1)) do
      0 -> Enum.count(lines, &(&1 != "" and not String.starts_with?(&1, "#")))
      n -> n
    end
  end

  attr :spec, :map, required: true

  @doc "A base spec's category, as a small icon on a quiet tile."
  def category_icon(assigns) do
    assigns = assign(assigns, :category, category(assigns.spec))

    ~H"""
    <span
      class={["grid size-6 shrink-0 place-items-center rounded-md", elem(@category, 2)]}
      title={elem(@category, 0)}
    >
      <.icon name={elem(@category, 1)} class="size-3.5" />
    </span>
    """
  end
end
