defmodule FactoryWeb.SpecPageParts do
  @moduledoc """
  The Spec page's pieces (`FactoryWeb.SpecLive`): the step tabs, the editor and preview,
  the review, the plan wizard and the approve bar. Events from them go to the Spec
  LiveView.
  """
  use FactoryWeb, :html
  alias Factory.Specs
  alias Factory.Specs.{Review, Spec}

  @labels %{
    "overview" => "Overview",
    "requirements" => "Requirements",
    "design" => "Design",
    "tasks" => "Tasks",
    "ready" => "Ready to run"
  }

  def step_label(step), do: Map.fetch!(@labels, step)

  attr :spec, Spec, required: true
  attr :activity, :list, required: true

  # Kiro writes the parts the spec is missing (Factory.Specs.write_missing/1).
  def write_panel(assigns) do
    write = assigns.spec.plan["write"] || %{}
    missing = Specs.missing_parts(assigns.spec)

    assigns =
      assign(assigns,
        status: write["status"],
        write: write,
        missing: missing,
        offer: missing != [] and Specs.files(assigns.spec) != [] and write["status"] != "running"
      )

    ~H"""
    <section :if={@offer or @status in ["running", "done"]} id="write-panel">
      <h2 class="font-medium">Write with Kiro</h2>

      <div :if={@status == "running"} class="mt-2 text-base-content/65">
        <p class="flex items-center gap-2">
          <span class="loading loading-spinner loading-xs text-info"></span>
          Kiro is reading the project and writing the {parts(@write["writing"])}.
        </p>
        <p
          :for={line <- Enum.take(@activity, -3)}
          class="mt-1 truncate pl-6 text-xs text-base-content/45"
        >
          {line}
        </p>
      </div>

      <p
        :if={@status == "done" and @write["why"] not in [nil, ""]}
        class="mt-1 text-base-content/65"
      >
        Wrote the {parts(@write["wrote"])}. {@write["why"]}
      </p>

      <div :if={@offer}>
        <p :if={@status == "error"} class="mt-1 text-error">{@write["error"]}</p>
        <p class="mt-1 text-base-content/60">
          Kiro reads the project, then writes the {parts(@missing)}, keeping to what you
          wrote. QA reviews the spec after.
        </p>
        <button id="write-missing" phx-click="write_missing" class="btn btn-sm mt-3">
          <.icon name="hero-sparkles-mini" class="size-4" /> Write the {parts(@missing)}
        </button>
      </div>
    </section>
    """
  end

  defp parts(list) do
    case List.wrap(list) do
      [] -> "rest"
      [one] -> one
      many -> Enum.join(Enum.drop(many, -1), ", ") <> " and " <> List.last(many)
    end
  end

  attr :run, :map, required: true

  # The base specs (company rules) the run this spec plans follows.
  def rules_panel(assigns) do
    assigns = assign(assigns, specs: Specs.list_base_specs())

    ~H"""
    <section id="rules-panel">
      <h2 class="font-medium">Rules this run follows</h2>
      <p class="mt-1 mb-3 text-base-content/60">
        Base specs every agent in the run keeps to.
      </p>
      <FactoryWeb.SpecParts.base_picker
        id="run-base-specs"
        specs={@specs}
        selected={@run.settings["base_spec_ids"] || []}
        event="toggle_base"
      />
    </section>
    """
  end

  attr :spec, Spec, required: true
  attr :title, :string, default: "Kiro review"

  @doc """
  Kiro's review of the whole spec: score, verdict, checks (worst first) and what to
  improve. Its buttons send `review`.
  """
  def review_panel(assigns) do
    review = assigns.spec.review

    assigns =
      assign(assigns,
        review: review,
        status: review["status"],
        empty: Specs.files(assigns.spec) == [],
        stale: Specs.changed_since_review?(assigns.spec),
        checks: Enum.sort_by(review["checks"] || [], &check_order(&1["status"]))
      )

    ~H"""
    <section id="review" class="border-b border-base-300 pb-8">
      <div class="flex items-center justify-between gap-3">
        <h2 class="font-medium">{@title}</h2>
        <button
          :if={@status in ["done", "error"]}
          phx-click="review"
          class="text-[13px] text-base-content/55 hover:text-base-content"
        >
          Review again
        </button>
      </div>

      <div :if={@status == nil}>
        <p class="mt-1 text-base-content/60">
          Kiro scores the spec and lists what's missing: acceptance criteria,
          expected results, edge cases and scope.
        </p>
        <button phx-click="review" disabled={@empty} class="btn btn-sm mt-3">
          Review with Kiro
        </button>
      </div>

      <p :if={@status == "running"} class="mt-2 flex items-center gap-2 text-base-content/65">
        <span class="loading loading-spinner loading-xs text-info"></span>
        Kiro is reading the spec. This can take a minute.
      </p>

      <p :if={@status == "error"} class="mt-2 text-error">{@review["error"]}</p>

      <div :if={@status == "done"} class="mt-3">
        <p class="flex items-baseline gap-2">
          <span class="text-3xl font-semibold tabular-nums tracking-tight">{@review["score"]}</span>
          <span class="text-base-content/45">/ 100</span>
          <span class={["ml-1 font-medium", verdict_class(@review["verdict"])]}>
            {verdict_label(@review["verdict"])}
          </span>
        </p>
        <p :if={@review["summary"] != ""} class="mt-2 text-base-content/70">{@review["summary"]}</p>
        <p :if={@stale} class="mt-2 text-[13px] text-warning">
          The spec changed after this review.
        </p>

        <ul :if={@checks != []} class="mt-4 space-y-2.5">
          <li :for={c <- @checks} class="flex gap-2">
            <.icon
              name={check_icon(c["status"])}
              class={["mt-0.5 size-4 shrink-0", check_class(c["status"])]}
            />
            <span class="min-w-0">
              <span class="font-medium">{Review.label(c["id"])}</span>
              <span :if={c["note"] != ""} class="block text-base-content/60">{c["note"]}</span>
            </span>
          </li>
        </ul>

        <div :if={@review["improvements"] != []} class="mt-5">
          <h3 class="font-medium">To improve</h3>
          <ul class="mt-1.5 list-disc space-y-1.5 pl-4 text-base-content/70 marker:text-base-content/35">
            <li :for={i <- @review["improvements"]}>{i}</li>
          </ul>
        </div>

        <p class="mt-4 text-xs text-base-content/45">
          Reviewed {Layouts.ago(elem(DateTime.from_iso8601(@review["at"]), 1))}
        </p>
      </div>
    </section>
    """
  end

  def verdict_label("strong"), do: "Strong"

  def verdict_label("needs_work"), do: "Needs work"

  def verdict_label(_), do: "Weak"

  def verdict_class("strong"), do: "text-success"

  def verdict_class("needs_work"), do: "text-warning"

  def verdict_class(_), do: "text-error"

  defp check_order("fail"), do: 0

  defp check_order("warn"), do: 1

  defp check_order(_), do: 2

  defp check_icon("pass"), do: "hero-check-circle-mini"

  defp check_icon("warn"), do: "hero-exclamation-triangle-mini"

  defp check_icon(_), do: "hero-x-circle-mini"

  defp check_class("pass"), do: "text-success"

  defp check_class("warn"), do: "text-warning"

  defp check_class(_), do: "text-error"

  attr :spec, Spec, required: true
  attr :step, :string, required: true

  # The three steps in order. Approved ones get a check; locked ones can't be opened.
  def steps(assigns) do
    ~H"""
    <nav aria-label="Spec steps" class="flex items-center gap-2 border-b border-base-300 pb-4 text-sm">
      <%= for {step, i} <- Enum.with_index(Spec.steps(), 1) do %>
        <span :if={i > 1} class="h-px w-6 bg-base-300 sm:w-10" aria-hidden="true"></span>
        <.link
          :if={Spec.open?(@spec, step)}
          patch={~p"/specs/#{@spec.id}?step=#{step}"}
          aria-current={@step == step && "step"}
          class={[
            "flex items-center gap-2 rounded-md px-2 py-1",
            if(@step == step, do: "bg-base-200 font-medium", else: "hover:bg-base-200")
          ]}
        >
          <.marker spec={@spec} step={step} n={i} />
          <.step_name step={step} />
        </.link>
        <span
          :if={!Spec.open?(@spec, step)}
          title={"Approve the #{String.downcase(step_label(prev_step(step)))} first"}
          class={[
            "flex items-center gap-2 rounded-md px-2 py-1 text-base-content/40",
            @step == step && "bg-base-200"
          ]}
        >
          <.marker spec={@spec} step={step} n={i} />
          <.step_name step={step} />
        </span>
      <% end %>
    </nav>
    """
  end

  defp step_name(assigns) do
    ~H"""
    <span class="text-left leading-tight">
      {step_label(@step)}
      <span class="hidden text-xs font-normal text-base-content/50 sm:block">{subtitle(@step)}</span>
    </span>
    """
  end

  defp subtitle("overview"), do: "The main spec"

  defp subtitle("requirements"), do: "What it should do"

  defp subtitle("design"), do: "How it's built"

  defp subtitle("tasks"), do: "Steps to build it"

  defp marker(assigns) do
    ~H"""
    <span
      :if={Spec.approved?(@spec, @step)}
      class="grid size-5 place-items-center rounded-full bg-success text-success-content"
    >
      <.icon name="hero-check-micro" class="size-3.5" />
    </span>
    <span
      :if={!Spec.approved?(@spec, @step)}
      class="grid size-5 place-items-center rounded-full border border-current text-[11px] tabular-nums"
    >
      {@n}
    </span>
    """
  end

  def tab_class(true), do: "bg-base-100 font-medium shadow-sm"

  def tab_class(false), do: "text-base-content/60 hover:text-base-content"

  defp prev_step("requirements"), do: "overview"

  defp prev_step("design"), do: "requirements"

  defp prev_step("tasks"), do: "design"

  defp prev_step(_), do: "overview"

  def reopen_confirm(spec, step) do
    later = Spec.steps() |> Enum.drop_while(&(&1 != step)) |> tl()

    case Enum.filter(later, &Spec.approved?(spec, &1)) do
      [] ->
        nil

      steps ->
        "Editing this step also reopens #{Enum.map_join(steps, " and ", &String.downcase(step_label(&1)))} for approval."
    end
  end

  # What to write in each step: a plain instruction, then prompts to answer.
  # What a step is for, in a few words.
  def purpose("overview"), do: "what you're building and why."

  def purpose("requirements"), do: "what it must do."

  def purpose("design"), do: "how it will be built."

  def purpose("tasks"), do: "the steps to build it, in order."

  defp intro("overview"),
    do:
      {"Write here the main spec: the big picture the other steps build on.",
       """
       - What are you building, and why?
       - What's in scope, and what isn't?
       - Anything the requirements, design and tasks must respect: stack, constraints, links.
       Nothing to add? Skip this step.\
       """}

  defp intro("requirements"),
    do:
      {"Write here what you want to build and what it must do.",
       """
       - Who is it for?
       - What must they be able to do?
       - What should happen, and how will you know it works?
         e.g. WHEN a user asks for a reset THEN they SHALL get an email with a link.\
       """}

  defp intro("design"),
    do:
      {"Write here how it will be built.",
       """
       - Which parts of the app change?
       - What new pages, modules or data are needed?
       - What happens when something fails?\
       """}

  defp intro("tasks"),
    do:
      {"Write here the steps to build it, in order, one per line.",
       """
       - [ ] 1. Add the reset form
       - [ ] 2. Send the reset email
       Keep each step small enough to build and test on its own.\
       """}

  def entry_errors(upload),
    do: for(entry <- upload.entries, err <- upload_errors(upload, entry), do: {entry, err})

  # An empty step's text box says what to write in it.
  def placeholder(step) do
    {question, explanation} = intro(step)
    "#{question}\n\n#{explanation}\n\nOr drop a .md or .txt file here."
  end

  def outline("overview") do
    """
    # Overview

    ## Goal

    What you're building and why.

    ## Scope

    - In scope:
    - Out of scope:

    ## Constraints

    Stack, conventions and anything every step must respect.

    ## References

    Links, related specs and files.
    """
  end

  def outline("requirements") do
    """
    # Requirements

    ## Introduction

    What the feature is and who it's for.

    ## Requirement 1

    **User story:** As a <role>, I want <goal>, so that <benefit>.

    ### Acceptance criteria

    1. WHEN <event> THEN the system SHALL <response>
    2. IF <condition> THEN the system SHALL <response>
    """
  end

  def outline("design") do
    """
    # Design

    ## Overview

    ## Architecture

    ## Components and interfaces

    ## Data models

    ## Error handling

    ## Testing strategy
    """
  end

  def outline("tasks") do
    """
    # Implementation plan

    - [ ] 1. First task
      - What to build, in a line or two
      - _Requirements: 1.1_

    - [ ] 2. Second task
      - _Requirements: 1.2_
    """
  end

  attr :spec, Spec, required: true
  attr :step, :string, required: true
  attr :open, :boolean, required: true
  attr :approved, :boolean, required: true
  attr :preview, :boolean, required: true
  attr :text, :string, required: true
  attr :saved, :boolean, required: true
  attr :undo, :any, required: true
  attr :uploads, :map, required: true
  attr :task_list, :list, required: true
  attr :draft, :any, required: true
  attr :editing, :any, required: true
  attr :expanded, :any, required: true
  attr :filter, :string, required: true
  attr :builders, :list, default: [], doc: "the agents its tasks can be given to, by name"
  attr :improve, :map, required: true
  attr :selected, :any, required: true

  # The open step: Write and Preview, the editor or the task list, upload and approve.
  def step_editor(assigns) do
    ~H"""
    <section>
      <div class="mb-2 flex flex-wrap items-center gap-3">
        <div :if={!@approved} class="flex rounded-md bg-base-200 p-0.5 text-[13px]">
          <button
            phx-click="preview"
            phx-value-on="false"
            class={["rounded px-2.5 py-1", tab_class(!@preview)]}
          >
            Write
          </button>
          <button
            phx-click="preview"
            phx-value-on="true"
            class={["rounded px-2.5 py-1", tab_class(@preview)]}
          >
            {if @step == "tasks", do: "Tasks", else: "Preview"}
          </button>
        </div>
        <p :if={@approved} class="flex items-center gap-1.5 text-[13px] text-success">
          <.icon name="hero-check-circle-mini" class="size-4" />
          Approved {Layouts.ago(Map.fetch!(@spec, Spec.approved_field(@step)))}
        </p>

        <span :if={!@approved && @saved && !@undo} class="text-xs text-base-content/45">
          Saved
        </span>
        <span :if={@undo} class="text-xs text-base-content/55">
          Filled from {@undo.name}.
          <button
            id="undo-upload"
            phx-click="undo"
            class="underline underline-offset-2 hover:text-base-content"
          >
            Undo
          </button>
        </span>

        <div class="ml-auto flex items-center gap-2">
          <button
            :if={@step == "tasks" && !@approved}
            id="suggest-tasks"
            phx-click="suggest"
            class="btn btn-ghost btn-sm"
          >
            <span
              :if={@spec.plan["status"] in ["reading", "writing"]}
              class="loading loading-spinner loading-xs text-info"
            ></span>
            <.icon
              :if={@spec.plan["status"] not in ["reading", "writing"]}
              name="hero-sparkles-mini"
              class="size-4"
            /> Suggest with Kiro
            <span
              :if={@spec.plan["status"] in ["questions", "tasks"]}
              class="size-1.5 rounded-full bg-info"
              title="Kiro is waiting for you"
            ></span>
          </button>
          <form
            :if={!@approved}
            id="spec-upload"
            phx-change="upload_changed"
            phx-submit="upload_changed"
          >
            <label
              for={@uploads.file.ref}
              title="Fill this step from a .md or .txt file"
              class="btn btn-ghost btn-sm cursor-pointer"
            >
              <.icon name="hero-arrow-up-tray-mini" class="size-4" /> Upload file
              <.live_file_input upload={@uploads.file} class="sr-only" />
            </label>
          </form>
          <button
            :if={@approved}
            phx-click="reopen"
            data-confirm={reopen_confirm(@spec, @step)}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-pencil-square-mini" class="size-4" /> Edit
          </button>
          <button
            :if={!@approved}
            id="approve"
            phx-click="approve"
            disabled={@step != "overview" and String.trim(@text) == ""}
            class={[
              "btn btn-sm",
              if(@step == "overview" and String.trim(@text) == "",
                do: "btn-ghost",
                else: "btn-primary"
              )
            ]}
          >
            {if @step == "overview" and String.trim(@text) == "",
              do: "Skip overview",
              else: "Approve #{String.downcase(step_label(@step))}"}
          </button>
        </div>
      </div>

      <form :if={!@preview} id="spec-editor" phx-change="edit" phx-submit="edit">
        <textarea
          id={"spec-#{@step}"}
          name="text"
          phx-hook="PromptEditor"
          data-drop
          phx-debounce="600"
          spellcheck="false"
          placeholder={placeholder(@step)}
          class="block min-h-[26rem] w-full resize-none rounded-lg border border-base-300 bg-base-100 px-4 py-3 font-mono text-[12px] leading-relaxed outline-none placeholder:text-base-content/40 focus:border-base-content/30"
        >{@text}</textarea>
      </form>

      <FactoryWeb.TaskList.list
        :if={@preview && @step == "tasks" && @task_list != []}
        tasks={@task_list}
        editable={!@approved}
        selected={@selected}
        expanded={@expanded}
        editing={@editing}
        improve={@improve}
        open={@open}
        filter={@filter}
        builders={@builders}
      />

      <FactoryWeb.TaskList.new_task
        :if={@step == "tasks" && @open && (@preview || @task_list == [])}
        draft={@draft}
        builders={@builders}
      />

      <div
        :if={@preview && String.trim(@text) != "" && (@step != "tasks" || @task_list == [])}
        id={"preview-#{@step}-#{:erlang.phash2(@text)}"}
        phx-hook="Markdown"
        phx-update="ignore"
        class="md rounded-lg border border-base-300 px-6 py-5"
      >
        {FactoryWeb.Markdown.render(@text)}
      </div>
      <p
        :if={@preview && String.trim(@text) == ""}
        class="rounded-lg border border-base-300 px-6 py-12 text-center text-sm text-base-content/50"
      >
        Nothing written yet.
      </p>

      <p :for={err <- upload_errors(@uploads.file)} class="mt-2 text-sm text-error">
        {upload_error(err, @uploads.file)}
      </p>
      <p
        :for={{entry, err} <- entry_errors(@uploads.file)}
        class="mt-2 text-sm text-error"
      >
        {entry.client_name}: {upload_error(err, @uploads.file)}
        <button
          phx-click="cancel_upload"
          phx-value-ref={entry.ref}
          class="ml-1 text-base-content/55 underline underline-offset-2 hover:text-base-content"
        >
          Dismiss
        </button>
      </p>

      <p
        :if={!@approved && !@preview && String.trim(@text) == ""}
        class="mt-3 text-sm text-base-content/55"
      >
        Not sure where to start?
        <span :if={@step == "tasks"}>
          <button
            phx-click="suggest"
            class="underline underline-offset-2 hover:text-base-content"
          >
            Let Kiro suggest tasks
          </button>
          from the project and the spec, or <button
            phx-click="outline"
            class="underline underline-offset-2 hover:text-base-content"
          >
            use an outline</button>.
        </span>
        <span :if={@step != "tasks"}>
          <button
            phx-click="outline"
            class="underline underline-offset-2 hover:text-base-content"
          >
            Use an outline
          </button>
          with the usual sections.
        </span>
      </p>
    </section>
    """
  end
end
