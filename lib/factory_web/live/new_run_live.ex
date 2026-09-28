defmodule FactoryWeb.NewRunLive do
  @moduledoc """
  Starting a factory run: describe the job, choose how the factory works on it
  (workflow, setup, whether to review the plan, project folder), then Start.
  Recommended choices come pre-selected, so describing the job is often enough.
  Opens from the start screen with `?type=bug`, or `?setup=ID` for a saved setup.
  """
  use FactoryWeb, :live_view
  import FactoryWeb.RunParts
  alias Factory.{Kiro, Launch}
  alias Factory.Runs.Types

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       answers: %{},
       save: false,
       setup_name: "",
       workspace: Kiro.config(:workspace),
       workflows: Factory.Workflows.list()
     )}
  end

  def handle_params(params, _uri, socket) do
    setup = params["setup"] && Launch.get_setup(params["setup"])
    kind = if setup, do: setup.kind, else: params["type"]

    case Types.get(kind) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      type ->
        settings =
          Map.merge(Types.default_settings(kind), (setup && setup.settings) || %{})

        {:noreply,
         assign(socket,
           page_title: type.label,
           kind: kind,
           type: type,
           settings: settings,
           from_setup: setup
         )}
    end
  end

  # Every change to the form comes here, so the page always shows what's chosen.
  def handle_event("change", params, socket) do
    settings = read_settings(socket.assigns, params)

    {:noreply,
     assign(socket,
       answers: params["answers"] || %{},
       settings: settings,
       save: params["save"]["on"] == "true",
       setup_name: params["save"]["name"] || socket.assigns.setup_name
     )}
  end

  def handle_event("wf_add", %{"kind" => kind}, socket) do
    step = Types.role(kind)
    {:noreply, update_workflow(socket, &(&1 ++ [step]))}
  end

  def handle_event("wf_remove", %{"i" => i}, socket),
    do: {:noreply, update_workflow(socket, &List.delete_at(&1, String.to_integer(i)))}

  def handle_event("wf_move", %{"i" => i, "by" => by}, socket) do
    i = String.to_integer(i)
    j = i + String.to_integer(by)

    {:noreply,
     update_workflow(socket, fn steps ->
       if j < 0 or j >= length(steps),
         do: steps,
         else:
           steps
           |> List.replace_at(i, Enum.at(steps, j))
           |> List.replace_at(j, Enum.at(steps, i))
     end)}
  end

  def handle_event("start", params, socket) do
    socket = elem(handle_event("change", params, socket), 1)
    %{kind: kind, answers: answers, settings: settings} = socket.assigns

    case Launch.start(kind, answers, settings) do
      {:ok, run} ->
        if socket.assigns.save and String.trim(socket.assigns.setup_name) != "",
          do: Launch.save_setup(socket.assigns.setup_name, kind, run.settings)

        {:noreply, push_navigate(socket, to: ~p"/runs/#{run.id}")}

      {:error, :missing_answer} ->
        {:noreply, put_flash(socket, :error, "Describe the job first.")}
    end
  end

  defp update_workflow(socket, fun) do
    settings = socket.assigns.settings
    steps = fun.(settings["workflow"]) |> Enum.reject(&is_nil/1)
    assign(socket, settings: %{settings | "workflow" => steps})
  end

  defp read_settings(assigns, params) do
    s = params["settings"] || %{}
    old = assigns.settings
    mode = s["workflow_mode"] || old["workflow_mode"]

    standard = Factory.Workflows.standard(assigns.kind)
    base = s["workflow_id"] && s["workflow_id"] != "" && String.to_integer(s["workflow_id"])
    old_id = old["workflow_id"]

    {workflow_id, workflow} =
      case mode do
        # A different workflow to start from: its agents become the steps.
        "manual" when is_integer(base) and base != old_id ->
          w = Factory.Workflows.get(base)
          {base, if(w, do: Factory.Workflows.steps(w), else: old["workflow"])}

        "manual" ->
          {old["workflow_id"],
           case params["wf"] do
             nil ->
               old["workflow"]

             steps ->
               steps
               |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
               |> Enum.map(fn {_, step} ->
                 %{
                   "kind" => step["kind"],
                   "name" => String.trim(step["name"] || ""),
                   "does" => step["does"] || ""
                 }
               end)
           end}

        _ ->
          {standard && standard.id, Factory.Workflows.recommended_steps(assigns.kind)}
      end

    %{
      "workflow_mode" => mode,
      "workflow_id" => workflow_id,
      "workflow" => workflow,
      "setup_mode" => s["setup_mode"] || old["setup_mode"],
      "model" => if(s["setup_mode"] == "manual", do: s["model"] || old["model"], else: "auto"),
      "approve_plan" => (s["approve_plan"] || to_string(old["approve_plan"])) == "true",
      "project_dir" => s["project_dir"] || old["project_dir"]
    }
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active={:home}>
      <div class="mx-auto max-w-3xl pb-28">
        <Layouts.back_link to={~p"/"}>Home</Layouts.back_link>

        <div class="flex items-start gap-4">
          <span class="grid size-12 shrink-0 place-items-center rounded-2xl bg-primary/12 text-primary">
            <.icon name={type_icon(@kind, :outline)} class="size-6" />
          </span>
          <div class="min-w-0">
            <h1 class="text-3xl font-semibold tracking-tight font-stretch-semi-condensed">
              {@type.label}
            </h1>
            <p class="mt-1 text-base-content/60">{@type.blurb}</p>
            <p :if={@from_setup} class="mt-1 text-sm text-info">
              From your saved setup “{@from_setup.name}”
            </p>
          </div>
        </div>

        <nav class="mt-5 flex flex-wrap gap-1.5" aria-label="Kind of job">
          <.link
            :for={t <- Types.all()}
            patch={~p"/new?#{[type: t.id]}"}
            aria-current={t.id == @kind && "page"}
            class={[
              "inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs transition-colors",
              if(t.id == @kind,
                do: "border-primary/50 bg-primary/10 text-base-content",
                else: "border-base-300 text-base-content/60 hover:text-base-content"
              )
            ]}
          >
            <.icon name={type_icon(t.id, :micro)} class="size-3.5" /> {t.short}
          </.link>
        </nav>

        <form id="new-run" phx-change="change" phx-submit="start" class="mt-8 space-y-10">
          <section>
            <h2 class="mb-4 flex items-center gap-2 text-lg font-medium">
              <span class="grid size-6 place-items-center rounded-full bg-base-content/10 text-xs">1</span>
              Describe it
            </h2>
            <div class="space-y-4">
              <label :for={{key, label, input, hint} <- @type.fields} class="block">
                <span class="mb-1.5 block text-sm font-medium">{label}</span>
                <textarea
                  :if={input == :textarea}
                  name={"answers[#{key}]"}
                  rows="4"
                  placeholder={hint}
                  phx-debounce="300"
                  class="block w-full resize-y rounded-lg border border-base-300 bg-base-100 px-3 py-2.5 text-sm leading-relaxed outline-none placeholder:text-base-content/40 focus:border-base-content/30"
                >{@answers[key]}</textarea>
                <input
                  :if={input == :text}
                  name={"answers[#{key}]"}
                  value={@answers[key]}
                  placeholder={hint}
                  phx-debounce="300"
                  autocomplete="off"
                  class="h-10 w-full rounded-lg border border-base-300 bg-base-100 px-3 text-sm outline-none placeholder:text-base-content/40 focus:border-base-content/30"
                />
                <select
                  :if={match?({:select, _}, input)}
                  name={"answers[#{key}]"}
                  class="select w-full"
                >
                  <option
                    :for={opt <- elem(input, 1)}
                    value={opt}
                    selected={@answers[key] == opt}
                  >
                    {opt}
                  </option>
                </select>
              </label>
            </div>
          </section>

          <section>
            <h2 class="mb-4 flex items-center gap-2 text-lg font-medium">
              <span class="grid size-6 place-items-center rounded-full bg-base-content/10 text-xs">2</span>
              How should the factory work?
            </h2>

            <h3 class="mb-2 text-sm font-medium">Workflow</h3>
            <div class="grid gap-2 sm:grid-cols-3">
              <.choice
                name="settings[workflow_mode]"
                value="recommended"
                current={@settings["workflow_mode"]}
                title="Recommended"
                text={"The usual agents for a #{String.downcase(@type.short)}."}
              />
              <.choice
                name="settings[workflow_mode]"
                value="kiro"
                current={@settings["workflow_mode"]}
                title="Let Kiro decide"
                text="Kiro reads the project and picks the agents."
              />
              <.choice
                name="settings[workflow_mode]"
                value="manual"
                current={@settings["workflow_mode"]}
                title="Manual"
                text="Choose the agents and their order."
              />
            </div>

            <div class="mt-3 rounded-xl border border-base-300/70 bg-base-200/30 px-4 py-3">
              <div :if={@settings["workflow_mode"] != "manual"}>
                <.chain steps={@settings["workflow"]} />
                <p
                  :if={@settings["workflow_mode"] == "kiro"}
                  class="mt-2 text-xs text-base-content/55"
                >
                  Kiro starts from this and changes it to fit the job; you'll see its choice on the run.
                </p>
              </div>

              <label
                :if={@settings["workflow_mode"] == "manual"}
                class="mb-3 flex flex-wrap items-center gap-2 text-sm"
              >
                <span class="text-base-content/70">Start from</span>
                <select name="settings[workflow_id]" class="select select-sm w-64">
                  <option value="" selected={is_nil(@settings["workflow_id"])}>
                    The steps below
                  </option>
                  <option
                    :for={w <- @workflows}
                    value={w.id}
                    selected={w.id == @settings["workflow_id"]}
                  >
                    {w.name}
                  </option>
                </select>
                <.link
                  navigate={~p"/workflows"}
                  class="text-xs text-base-content/50 hover:text-base-content"
                >
                  Edit workflows →
                </.link>
              </label>

              <ol :if={@settings["workflow_mode"] == "manual"} id="workflow-steps" class="space-y-2">
                <li
                  :for={{step, i} <- Enum.with_index(@settings["workflow"])}
                  class="flex items-center gap-2"
                >
                  <span class="w-4 text-right text-xs tabular-nums text-base-content/45">{i + 1}</span>
                  <select name={"wf[#{i}][kind]"} class="select select-sm w-36" aria-label="Role">
                    <option
                      :for={r <- Types.roles()}
                      value={r["kind"]}
                      selected={r["kind"] == step["kind"]}
                    >
                      {FactoryWeb.AgentKinds.label(r["kind"])}
                    </option>
                  </select>
                  <input
                    name={"wf[#{i}][name]"}
                    value={step["name"]}
                    aria-label="Name"
                    phx-debounce="300"
                    class="h-8 min-w-0 flex-1 rounded-md border border-base-300 bg-base-100 px-2.5 text-sm outline-none focus:border-base-content/30"
                  />
                  <input type="hidden" name={"wf[#{i}][does]"} value={step["does"]} />
                  <button
                    :if={i > 0}
                    type="button"
                    phx-click="wf_move"
                    phx-value-i={i}
                    phx-value-by="-1"
                    aria-label="Earlier"
                    class="grid size-7 place-items-center rounded text-base-content/50 hover:bg-base-300 hover:text-base-content"
                  >
                    <.icon name="hero-arrow-up-mini" class="size-4" />
                  </button>
                  <button
                    type="button"
                    phx-click="wf_remove"
                    phx-value-i={i}
                    aria-label="Remove"
                    class="grid size-7 place-items-center rounded text-base-content/50 hover:bg-base-300 hover:text-error"
                  >
                    <.icon name="hero-x-mark-mini" class="size-4" />
                  </button>
                </li>
                <li class="flex flex-wrap items-center gap-1.5 pt-1 pl-6">
                  <span class="text-xs text-base-content/50">Add</span>
                  <button
                    :for={r <- Types.roles()}
                    type="button"
                    phx-click="wf_add"
                    phx-value-kind={r["kind"]}
                    class="inline-flex items-center gap-1 rounded-md border border-base-300 px-2 py-0.5 text-xs text-base-content/70 hover:border-base-content/30 hover:text-base-content"
                  >
                    <.icon name={kind_icon(r["kind"])} class="size-3" /> {r["name"]}
                  </button>
                </li>
              </ol>
            </div>

            <h3 class="mb-2 mt-6 text-sm font-medium">Setup</h3>
            <div class="grid gap-2 sm:grid-cols-3">
              <.choice
                name="settings[setup_mode]"
                value="recommended"
                current={@settings["setup_mode"]}
                title="Recommended"
                text="Model auto: Kiro picks the model for each turn."
              />
              <.choice
                name="settings[setup_mode]"
                value="kiro"
                current={@settings["setup_mode"]}
                title="Let Kiro decide"
                text="Kiro picks one model for this job."
              />
              <.choice
                name="settings[setup_mode]"
                value="manual"
                current={@settings["setup_mode"]}
                title="Manual"
                text="Choose the model yourself."
              />
            </div>
            <label :if={@settings["setup_mode"] == "manual"} class="mt-3 flex items-center gap-3">
              <span class="text-sm text-base-content/70">Model</span>
              <select name="settings[model]" class="select select-sm w-56">
                <option :for={m <- Kiro.models()} value={m} selected={m == @settings["model"]}>
                  {m}
                </option>
              </select>
            </label>

            <h3 class="mb-2 mt-6 text-sm font-medium">Checkpoint</h3>
            <label class="flex cursor-pointer items-start gap-3 rounded-xl border border-base-300/70 bg-base-200/30 px-4 py-3">
              <input type="hidden" name="settings[approve_plan]" value="false" />
              <input
                type="checkbox"
                name="settings[approve_plan]"
                value="true"
                checked={@settings["approve_plan"]}
                class="toggle toggle-sm toggle-primary mt-0.5"
              />
              <span>
                <span class="block text-sm font-medium">Let me review the plan before the run starts</span>
                <span class="block text-xs text-base-content/55">
                  Kiro writes the requirements, design and tasks; you approve them in the spec.
                  Off: the plan is approved and the run is queued as soon as Kiro is done.
                </span>
              </span>
            </label>

            <label class="mt-6 block">
              <span class="mb-1.5 block text-sm font-medium">Project folder</span>
              <input
                name="settings[project_dir]"
                value={@settings["project_dir"]}
                placeholder={@workspace}
                phx-debounce="300"
                autocomplete="off"
                class="h-10 w-full rounded-lg border border-base-300 bg-base-100 px-3 font-mono text-xs outline-none placeholder:text-base-content/40 focus:border-base-content/30"
              />
              <span class="mt-1 block text-xs text-base-content/50">
                The folder Kiro reads and the agents work in. Empty: the Kiro workspace.
              </span>
            </label>

            <div class="mt-6 flex flex-wrap items-center gap-3">
              <label class="flex cursor-pointer items-center gap-2 text-sm">
                <input type="hidden" name="save[on]" value="false" />
                <input
                  type="checkbox"
                  name="save[on]"
                  value="true"
                  checked={@save}
                  class="checkbox checkbox-sm"
                /> Save these choices as a setup
              </label>
              <input
                :if={@save}
                name="save[name]"
                value={@setup_name}
                placeholder="Setup name, e.g. Quick bug fix"
                maxlength="60"
                phx-debounce="300"
                class="h-8 w-64 rounded-md border border-base-300 bg-base-100 px-2.5 text-sm outline-none focus:border-base-content/30"
              />
            </div>
          </section>

          <div class="fixed inset-x-0 bottom-0 z-20 border-t border-base-300 bg-base-100/90 backdrop-blur">
            <div class="mx-auto flex max-w-3xl items-center justify-between gap-4 px-4 py-3 sm:px-0">
              <p class="min-w-0 text-xs text-base-content/60">
                {if @settings["approve_plan"],
                  do: "Kiro plans it first, then you review the plan.",
                  else: "Kiro plans it and the run is queued right away."}
              </p>
              <button
                id="start-run"
                type="submit"
                disabled={!Types.ready?(@kind, @answers)}
                class="btn btn-primary"
              >
                <.icon name="hero-play-mini" class="size-4" /> Start factory run
              </button>
            </div>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :current, :string, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true

  # One option of a choice, as a card.
  defp choice(assigns) do
    ~H"""
    <label class={[
      "flex cursor-pointer flex-col rounded-xl border px-3.5 py-3 transition-colors",
      if(@current == @value,
        do: "border-primary/60 bg-primary/[0.07]",
        else: "border-base-300/70 hover:border-base-content/20"
      )
    ]}>
      <span class="flex items-center gap-2 text-sm font-medium">
        <input
          type="radio"
          name={@name}
          value={@value}
          checked={@current == @value}
          class="radio radio-xs radio-primary"
        />
        {@title}
      </span>
      <span class="mt-1 pl-6 text-xs leading-relaxed text-base-content/55">{@text}</span>
    </label>
    """
  end
end
