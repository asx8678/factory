defmodule FactoryWeb.SettingsLive do
  @moduledoc """
  What Factory runs with. General shows where Factory keeps things and how it drives
  Kiro, as configured (read-only: these come from `config/*.exs`). Models lists what
  this Kiro offers, checked at startup or on demand. Tokens aren't stored anywhere:
  actions and sources read environment variables (see the README).
  """
  use FactoryWeb, :live_view

  @tabs [
    {"general", "General"},
    {"models", "Models"},
    {"runs", "Runs"},
    {"web", "Web searches"}
  ]

  alias Factory.Kiro.Catalog

  # The check's result arrives through FactoryWeb.KiroStatus, as `kiro_checked/2`.
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Settings", tabs: @tabs, checking: false) |> catalog()}
  end

  defp catalog(socket) do
    planning = Factory.Prefs.get("planning_model")
    verifying = Factory.Prefs.get("verify_model")

    assign(socket,
      names_form:
        to_form(%{"names" => Enum.join(Factory.Redact.saved_names(), "\n")}, as: :redact),
      limit_form: limit_form(Factory.Engine.credit_limit()),
      models: Catalog.models() || [],
      modes: Catalog.modes() || [],
      checked_at: Catalog.checked_at(),
      check_error: Catalog.error(),
      role_form: to_form(%{"planning" => planning || "", "verifying" => verifying || ""})
    )
  end

  # A role's choices: Factory's own pick first, then every model this Kiro offers.
  defp model_options(models, default_label),
    do: [{default_label, ""} | for(m <- models, do: {m["name"], m["value"]})]

  # Which model plans and which verifies; "" goes back to Factory's choice.
  def handle_event("role_models", params, socket) do
    for {key, field} <- [{"planning_model", "planning"}, {"verify_model", "verifying"}],
        Map.has_key?(params, field) do
      value = params[field]
      Factory.Prefs.put(key, if(value in Factory.Kiro.models(), do: value))
    end

    {:noreply, catalog(socket)}
  end

  # The names the agents that search the web never see (Factory.Redact).
  def handle_event("redact_names", %{"redact" => %{"names" => text}}, socket) do
    names =
      text
      |> String.split(~r/\R/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Factory.Prefs.put("redact_names", names)

    {:noreply,
     socket
     |> assign(names_form: to_form(%{"names" => Enum.join(names, "\n")}, as: :redact))
     |> put_flash(
       :info,
       "Saved #{length(names)} #{if length(names) == 1, do: "name", else: "names"}."
     )}
  end

  # How many credits a run may use before it pauses to ask (Factory.Engine); 0 is none.
  def handle_event("credit_limit", %{"limit" => %{"credits" => text}}, socket) do
    case Float.parse(String.trim(text)) do
      {n, ""} when n >= 0 ->
        Factory.Prefs.put("run_credit_limit", n)

        {:noreply,
         socket
         |> assign(limit_form: limit_form(n))
         |> put_flash(
           :info,
           if(n == 0,
             do: "Runs now go on however many credits they use.",
             else: "Runs now pause at #{FactoryWeb.Usage.credits(n)} credits to ask."
           )
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "The limit is a number of credits, 0 or more.")}
    end
  end

  # Asks Kiro which models it has; the answer comes back as {:kiro_catalog, _}.
  def handle_event("check_models", _, socket) do
    Catalog.check_later()
    {:noreply, assign(socket, checking: true)}
  end

  def kiro_checked(_catalog, socket), do: socket |> assign(checking: false) |> catalog()

  defp limit_form(n),
    do: to_form(%{"credits" => FactoryWeb.Usage.credits(n)}, as: :limit)

  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in Enum.map(@tabs, &elem(&1, 0)), do: params["tab"], else: "general"
    {:noreply, assign(socket, tab: tab)}
  end

  # How Factory is set up, as the General tab shows it: {label, value, hint}.
  defp facts do
    kiro = Application.fetch_env!(:factory, :kiro)
    cli = kiro[:cli]

    [
      {"Kiro CLI", cli,
       if(File.exists?(cli),
         do: "Found. Each agent's session runs it as `kiro-cli acp`.",
         else: "Not found: install kiro-cli or set its path in config :factory, :kiro."
       )},
      {"Default workspace", kiro[:workspace],
       "Where Kiro works when a chat has no project folder."},
      {"Kiro logs", kiro[:log_dir], "Each session's stderr, for when something goes wrong."},
      {"Reply timeout", "#{div(kiro[:prompt_timeout], 60_000)} minutes",
       "How long a turn may take before Factory stops it."},
      {"Loop passes", "#{Factory.Engine.max_rounds()}",
       "How many times a reviewer may send work back per step."},
      {"Compact at", "#{Factory.Context.config(:compact_at)}% of the context",
       "When a session's conversation is compacted before its next message."}
    ]
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      usage={@usage_meter}
      active_runs={@active_runs}
      kiro={@kiro}
      active={:settings}
    >
      <Layouts.page_title title="Settings" />

      <div class="grid gap-10 md:grid-cols-[12rem_minmax(0,1fr)]">
        <nav class="flex gap-1 md:flex-col">
          <.link
            :for={{key, label} <- @tabs}
            patch={~p"/settings?tab=#{key}"}
            class={[
              "rounded-md px-3 py-2 text-sm",
              if(@tab == key,
                do: "bg-base-200 font-medium",
                else: "text-base-content/60 hover:text-base-content"
              )
            ]}
          >
            {label}
          </.link>
        </nav>

        <div class="max-w-xl">
          <%= case @tab do %>
            <% "models" -> %>
              <section id="role-models" class="mb-10">
                <h2 class="font-medium">Models by role</h2>
                <p class="mt-0.5 text-sm text-base-content/55">
                  Plan with the strongest model Factory uses, build on Auto, and verify with a different, quicker one.
                </p>
                <.form
                  for={@role_form}
                  id="role-models-form"
                  phx-change="role_models"
                  class="mt-3 divide-y divide-base-300/70 rounded-xl border border-base-300/70"
                >
                  <div class="flex items-center gap-4 px-3.5 py-3">
                    <span class="min-w-0 flex-1">
                      <span class="block text-sm font-medium">Planning</span>
                      <span class="block text-xs text-base-content/55">
                        The chat's planner, Scope and Refine, and Suggest with AI and Improve on the Spec page.
                      </span>
                    </span>
                    <.input
                      field={@role_form[:planning]}
                      type="select"
                      id="planning-model"
                      aria-label="Planning model"
                      options={
                        model_options(
                          @models,
                          "Factory's choice (#{Factory.Kiro.model_name(Factory.Kiro.strongest())})"
                        )
                      }
                      class="h-8 w-full rounded-md border border-base-300 bg-base-100 px-2 text-[13px] outline-none focus:border-base-content/30"
                      wrapper_class="w-56 shrink-0"
                    />
                  </div>
                  <div class="flex items-center gap-4 px-3.5 py-3">
                    <span class="min-w-0 flex-1">
                      <span class="block text-sm font-medium">Building</span>
                      <span class="block text-xs text-base-content/55">
                        Coding agents build on their own model, Auto unless set on the card. Other agents use the model the plan gives each task. Factory never gives a task Sonnet.
                      </span>
                    </span>
                    <span class="w-56 shrink-0 px-2 text-[13px] text-base-content/60">
                      Per agent, Auto unless set
                    </span>
                  </div>
                  <div class="flex items-center gap-4 px-3.5 py-3">
                    <span class="min-w-0 flex-1">
                      <span class="block text-sm font-medium">Verifying</span>
                      <span class="block text-xs text-base-content/55">
                        Checks each finished task against its Verify list, running its commands, and sends it back when a check fails.
                      </span>
                    </span>
                    <.input
                      field={@role_form[:verifying]}
                      type="select"
                      id="verifying-model"
                      aria-label="Verifying model"
                      options={
                        model_options(
                          @models,
                          "Quick and different (#{Factory.Kiro.model_name(Factory.Kiro.quick())})"
                        )
                      }
                      class="h-8 w-full rounded-md border border-base-300 bg-base-100 px-2 text-[13px] outline-none focus:border-base-content/30"
                      wrapper_class="w-56 shrink-0"
                    />
                  </div>
                </.form>
                <p
                  :if={!Enum.any?(@models, &String.contains?(&1["value"], "opus"))}
                  class="mt-2 text-xs text-base-content/55"
                >
                  Factory doesn't pick Sonnet on its own, and this Kiro offers no Opus, so planning runs on Auto. Pick a model above to plan with it instead; Factory switches to an Opus once Kiro lists one.
                </p>
              </section>

              <section id="kiro-models" class="mb-8">
                <div class="flex items-start justify-between gap-4">
                  <div>
                    <h2 class="font-medium">Models Kiro offers</h2>
                    <p class="mt-0.5 text-sm text-base-content/55">
                      Checked automatically when Factory starts. Every model picker uses this list.
                    </p>
                  </div>
                  <button
                    id="check-models"
                    type="button"
                    phx-click="check_models"
                    disabled={@checking}
                    class="btn btn-sm shrink-0"
                  >
                    <span :if={@checking} class="loading loading-spinner loading-xs"></span>
                    <.icon :if={!@checking} name="hero-arrow-path-mini" class="size-4" />
                    {if @checking, do: "Checking…", else: "Check now"}
                  </button>
                </div>

                <p class="mt-3 flex items-center gap-2 text-xs text-base-content/55">
                  <span class={[
                    "size-1.5 rounded-full",
                    cond do
                      @check_error -> "bg-warning"
                      @checked_at -> "bg-success"
                      true -> "bg-base-content/30"
                    end
                  ]}></span>
                  {cond do
                    @checked_at ->
                      "#{length(@models)} models · checked #{Layouts.ago(elem(DateTime.from_iso8601(@checked_at), 1))}"

                    true ->
                      "Not checked yet: using the list Factory ships with."
                  end}
                  <span :if={@check_error} class="text-warning">Last check failed: {@check_error}</span>
                </p>

                <ul
                  :if={@models != []}
                  class="mt-3 divide-y divide-base-300/70 rounded-xl border border-base-300/70"
                >
                  <li :for={m <- @models} class="flex items-baseline gap-3 px-3.5 py-2 text-sm">
                    <span class="w-40 shrink-0 truncate font-mono text-xs font-light">{m["value"]}</span>
                    <span class="min-w-0 flex-1 truncate text-base-content/55">
                      {if m["description"] != "", do: m["description"], else: m["name"]}
                    </span>
                  </li>
                </ul>

                <details :if={@modes != []} class="mt-3 text-sm">
                  <summary class="cursor-pointer text-base-content/60 hover:text-base-content">
                    {length(@modes)} modes
                  </summary>
                  <ul class="mt-2 space-y-1 pl-4">
                    <li :for={m <- @modes}>
                      <span class="font-mono text-xs font-light">{m["value"]}</span>
                      <span class="text-base-content/55"> · {m["description"]}</span>
                    </li>
                  </ul>
                </details>
              </section>
            <% "runs" -> %>
              <section id="credit-limit">
                <h2 class="font-medium">Credits a run may use</h2>
                <p class="mt-0.5 text-sm text-base-content/55">
                  A run that has used this many credits pauses before its next step and asks
                  whether to go on; Continue lets it use as many again. It's checked between
                  steps, so a step that's already working finishes first. 0 means no limit.
                </p>
                <.form
                  for={@limit_form}
                  id="credit-limit-form"
                  phx-submit="credit_limit"
                  class="mt-3 flex items-start gap-2"
                >
                  <div class="w-32">
                    <.input field={@limit_form[:credits]} type="number" min="0" step="0.5" />
                  </div>
                  <button id="credit-limit-save" class="btn btn-sm mt-1">Save</button>
                </.form>
              </section>
            <% "web" -> %>
              <section id="redact-names">
                <h2 class="font-medium">Names to keep out of web searches</h2>
                <p class="mt-0.5 text-sm text-base-content/55">
                  The agents that search the web (the Error Researcher and the Fact Checker) are
                  never shown these, nor hostnames, IDs or secrets. One per line: your company,
                  its products, its customers. Each is matched as a whole word, in any case, so
                  a name that's also a common word is taken out everywhere.
                </p>
                <.form for={@names_form} id="redact-names-form" phx-submit="redact_names" class="mt-3">
                  <.input
                    field={@names_form[:names]}
                    type="textarea"
                    rows="4"
                    placeholder="Acme Corp\nAcme Orders\nContoso"
                  />
                  <button id="redact-names-save" class="btn btn-sm mt-2">Save</button>
                </.form>
              </section>
            <% _ -> %>
              <dl id="settings-facts" class="divide-y divide-base-300/70">
                <div :for={{label, value, hint} <- facts()} class="py-3">
                  <dt class="text-sm font-medium">{label}</dt>
                  <dd class={[
                    "mt-0.5 break-all",
                    if(String.starts_with?(value, "/"),
                      do: "font-mono text-xs font-light",
                      else: "text-sm"
                    )
                  ]}>
                    {value}
                  </dd>
                  <dd class="mt-1 text-[13px] text-base-content/55">{hint}</dd>
                </div>
              </dl>
              <p class="mt-6 text-[13px] text-base-content/55">
                These come from Factory's configuration. Tokens for actions and data sources
                are never stored: they're read from environment variables when needed.
              </p>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
