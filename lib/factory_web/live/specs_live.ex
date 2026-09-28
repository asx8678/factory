defmodule FactoryWeb.SpecsLive do
  use FactoryWeb, :live_view
  alias Factory.Specs
  alias Factory.Specs.Spec

  def mount(_params, _session, socket) do
    if connected?(socket), do: Specs.subscribe()
    specs = Specs.list_specs()

    {:ok,
     socket
     |> assign(page_title: "Specs", specs: specs, adding: specs == [])
     |> assign(form: to_form(%{"name" => "", "description" => "", "review" => "true"}))
     |> allow_upload(:files,
       accept: ~w(.md .markdown .txt),
       max_entries: 4,
       max_file_size: 2_000_000
     )}
  end

  def handle_info({:specs_changed}, socket),
    do: {:noreply, assign(socket, specs: Specs.list_specs())}

  def handle_event("add", _, socket), do: {:noreply, assign(socket, adding: true)}

  def handle_event("cancel", _, socket) do
    socket =
      Enum.reduce(
        socket.assigns.uploads.files.entries,
        socket,
        &cancel_upload(&2, :files, &1.ref)
      )

    {:noreply, assign(socket, adding: socket.assigns.specs == [])}
  end

  # The review box only appears once a file is added, so until it's unticked it's on.
  def handle_event("validate", params, socket) do
    params =
      params |> Map.take(["name", "description", "review"]) |> Map.put_new("review", "true")

    {:noreply, assign(socket, form: to_form(params))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Specs.get_spec(id) do
      nil ->
        {:noreply, socket}

      spec ->
        {:ok, _} = Specs.delete_spec(spec)
        {:noreply, put_flash(socket, :info, "Deleted #{spec.name}.")}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("create", params, socket) do
    name = params["name"] || ""
    description = String.trim(params["description"] || "")

    uploaded =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)
      |> Enum.filter(fn {_, text} -> String.valid?(text) end)

    # The description goes into requirements, in front of any uploaded requirements.
    files = if description == "", do: uploaded, else: [{:description, description} | uploaded]

    result =
      if files == [], do: Specs.create_spec(name), else: Specs.create_from_files(name, files)

    case result do
      {:ok, spec} ->
        if files != [] and params["review"] == "true", do: Specs.review(spec)
        {:noreply, push_navigate(socket, to: ~p"/specs/#{spec.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(params, errors: changeset.errors))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active={:specs}>
      <Layouts.page_title
        title="Specs"
        subtitle="Take a feature from its main spec to requirements, design and tasks, approving each step, then run it."
      >
        <:actions>
          <button :if={!@adding} phx-click="add" class="btn btn-primary btn-sm">
            <.icon name="hero-plus-mini" class="size-4" /> New spec
          </button>
        </:actions>
      </Layouts.page_title>

      <.form
        :if={@adding}
        for={@form}
        id="new-spec"
        phx-submit="create"
        phx-change="validate"
        class="mb-10 max-w-xl space-y-3"
      >
        <label class="block">
          <span class="text-sm font-medium">Name</span>
          <input
            name="name"
            value={@form[:name].value}
            placeholder="e.g. Password reset"
            maxlength="80"
            autofocus
            class="input mt-1 w-full"
          />
        </label>
        <p
          :for={{msg, _} <- Keyword.get_values(@form.errors, :name)}
          class="-mt-1 text-xs text-error"
        >
          Give the spec a name, describe the feature, or add a spec file.
        </p>

        <label class="block pt-2">
          <span class="text-sm font-medium">What do you want to build?</span>
          <span class="block text-xs text-base-content/55">
            Write what must be done: who it's for, what they must be able to do and what
            should happen. A few sentences are enough; this becomes the spec's Overview.
          </span>
          <textarea
            name="description"
            rows="5"
            phx-debounce="400"
            placeholder="People who forget their password can get a reset link by email and choose a new one. The link works once and expires after 30 minutes."
            class="textarea mt-1.5 w-full text-sm leading-relaxed"
          >{@form[:description].value}</textarea>
        </label>

        <p class="flex items-center gap-3 text-xs text-base-content/45" aria-hidden="true">
          <span class="h-px flex-1 bg-base-300"></span>
          or start from files <span class="h-px flex-1 bg-base-300"></span>
        </p>

        <label
          for={@uploads.files.ref}
          phx-drop-target={@uploads.files.ref}
          class="flex cursor-pointer flex-col items-center gap-1 rounded-lg border border-dashed border-base-content/20 px-4 py-6 text-center text-sm transition-colors hover:border-base-content/40 hover:bg-base-200 [&.phx-drop-target-active]:border-primary [&.phx-drop-target-active]:bg-primary/5"
        >
          <.icon name="hero-arrow-up-tray" class="size-5 text-base-content/40" />
          <span>
            Drop spec files here, or <span class="underline underline-offset-2">choose files</span>
          </span>
          <span class="text-xs text-base-content/50">
            A main spec document, plus requirements.md, design.md, tasks.md (.md or .txt)
          </span>
          <.live_file_input upload={@uploads.files} class="sr-only" />
        </label>

        <p :for={err <- upload_errors(@uploads.files)} class="text-xs text-error">
          {upload_error(err)}
        </p>

        <ul :if={@uploads.files.entries != []} class="space-y-1 text-sm">
          <li :for={entry <- @uploads.files.entries} class="flex items-center gap-2">
            <.icon name="hero-document-text-mini" class="size-4 text-base-content/40" />
            <span class="truncate">{entry.client_name}</span>
            <span class="text-base-content/45">
              goes into {String.downcase(
                FactoryWeb.SpecLive.step_label(Specs.step_for(entry.client_name))
              )}
            </span>
            <span
              :for={err <- upload_errors(@uploads.files, entry)}
              class="text-xs text-error"
            >
              {upload_error(err)}
            </span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="ml-auto text-base-content/45 hover:text-base-content"
              aria-label={"Remove #{entry.client_name}"}
            >
              <.icon name="hero-x-mark-mini" class="size-4" />
            </button>
          </li>
        </ul>

        <label
          :if={@uploads.files.entries != [] or String.trim(@form[:description].value || "") != ""}
          class="flex items-start gap-2.5 rounded-lg bg-base-200 px-3 py-2.5 text-sm"
        >
          <input type="hidden" name="review" value="false" />
          <input
            type="checkbox"
            name="review"
            value="true"
            checked={@form[:review].value == "true"}
            class="checkbox checkbox-sm mt-0.5"
          />
          <span>
            Review with Kiro
            <span class="block text-xs text-base-content/55">
              Scores the spec and lists what's missing: acceptance criteria,
              expected results, edge cases, scope.
            </span>
          </span>
        </label>

        <div class="flex gap-2">
          <button class="btn btn-primary btn-sm">Create spec</button>
          <button :if={@specs != []} type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </.form>

      <p :if={@specs == []} class="max-w-xl text-sm text-base-content/55">
        Each spec has four steps, written in order: the overview (the main spec),
        requirements (what it must do), design (how it's built) and tasks (the
        checklist agents work through).
      </p>

      <div :if={@specs != []} class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead class="text-left text-[13px] text-base-content/55">
            <tr class="border-b border-base-300">
              <th class="py-2 pr-4 font-normal">Spec</th>
              <th class="py-2 pr-4 font-normal">Step</th>
              <th class="py-2 pr-4 font-normal">Review</th>
              <th class="py-2 pr-4 font-normal">Tasks</th>
              <th class="py-2 pr-4 font-normal">Latest run</th>
              <th class="py-2 text-right font-normal">Updated</th>
              <th class="w-10 py-2"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={s <- @specs}
              phx-click={JS.navigate(~p"/specs/#{s.id}")}
              id={"spec-#{s.id}"}
              class="group cursor-pointer border-b border-base-300 hover:bg-base-200"
            >
              <td class="py-3 pr-4">
                <.link navigate={~p"/specs/#{s.id}"} class="font-medium">{s.name}</.link>
              </td>
              <td class="py-3 pr-4"><.progress spec={s} /></td>
              <td class="py-3 pr-4"><.review_cell review={s.review} /></td>
              <td class="py-3 pr-4 tabular-nums text-base-content/75">
                {case length(Specs.tasks(s)) do
                  0 -> "–"
                  n -> n
                end}
              </td>
              <td class="py-3 pr-4">
                <span :if={s.runs == []} class="text-base-content/40">–</span>
                <span :if={run = List.first(s.runs)} class="flex items-center gap-2">
                  <Layouts.status_badge status={run.status} />
                  <span :if={run.tasks != []} class="tabular-nums text-base-content/55">
                    {Enum.count(run.tasks, &(&1.status == "done"))} of {length(run.tasks)} done
                  </span>
                </span>
              </td>
              <td class="whitespace-nowrap py-3 text-right text-base-content/55">
                {Layouts.ago(s.updated_at)}
              </td>
              <td class="py-3 pl-2 text-right">
                <button
                  phx-click="delete"
                  phx-value-id={s.id}
                  data-confirm={"Delete #{s.name}? Runs started from it are kept."}
                  aria-label={"Delete #{s.name}"}
                  title="Delete spec"
                  class="grid size-7 place-items-center rounded-md text-base-content/40 opacity-0 hover:bg-base-300 hover:text-error focus-visible:opacity-100 group-hover:opacity-100 [@media(hover:none)]:opacity-100"
                >
                  <.icon name="hero-trash-mini" class="size-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  defp review_cell(%{review: %{"status" => "done"}} = assigns) do
    ~H"""
    <span class="flex items-baseline gap-1.5">
      <span class="font-medium tabular-nums">{@review["score"]}</span>
      <span class={FactoryWeb.SpecLive.verdict_class(@review["verdict"])}>
        {FactoryWeb.SpecLive.verdict_label(@review["verdict"])}
      </span>
    </span>
    """
  end

  defp review_cell(%{review: %{"status" => "running"}} = assigns),
    do: ~H[<span class="text-info">Reviewing…</span>]

  defp review_cell(%{review: %{"status" => "error"}} = assigns),
    do: ~H[<span class="text-error/80">Review failed</span>]

  defp review_cell(assigns), do: ~H[<span class="text-base-content/40">–</span>]

  defp upload_error(:too_large), do: "larger than 2 MB"
  defp upload_error(:not_accepted), do: "only .md and .txt files"

  defp upload_error(:too_many_files),
    do: "up to 4 files: the main spec, requirements, design and tasks"

  defp upload_error(err), do: to_string(err)

  attr :spec, Spec, required: true

  # Three short bars, one per step, filled once approved, and the step being written.
  defp progress(assigns) do
    assigns = assign(assigns, current: Spec.current_step(assigns.spec))

    ~H"""
    <span class="flex items-center gap-2.5">
      <span class="flex gap-0.5" aria-hidden="true">
        <span
          :for={step <- Spec.steps()}
          class={[
            "h-1.5 w-4 rounded-full",
            cond do
              Spec.approved?(@spec, step) -> "bg-success"
              step == @current -> "bg-base-content/35"
              true -> "bg-base-300"
            end
          ]}
        ></span>
      </span>
      <span class={if @current == "ready", do: "text-success", else: "text-base-content/70"}>
        {FactoryWeb.SpecLive.step_label(@current)}
      </span>
    </span>
    """
  end
end
