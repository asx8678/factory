defmodule FactoryWeb.SpecLive do
  @moduledoc "One spec: its overview, requirements, design and tasks, written and approved in order."
  use FactoryWeb, :live_view
  alias Factory.{Runs, Specs}
  alias Factory.Specs.{Review, Spec}

  @labels %{
    "overview" => "Overview",
    "requirements" => "Requirements",
    "design" => "Design",
    "tasks" => "Tasks",
    "ready" => "Ready to run"
  }

  def step_label(step), do: Map.fetch!(@labels, step)

  def mount(%{"id" => id}, _session, socket) do
    case Specs.get_spec(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "That spec doesn't exist.") |> push_navigate(to: ~p"/specs")}

      spec ->
        if connected?(socket), do: Specs.subscribe(spec.id)

        {:ok,
         socket
         |> FactoryWeb.UsageMeter.scope({:spec, spec.id})
         |> assign(home_run: Specs.home_run(spec))
         |> assign(page_title: spec.name, spec: spec, preview: false, saved: false, undo: nil)
         |> assign(suggest: false, activity: [], answers: %{}, others: %{}, add_mode: "append")
         |> assign(question: 0)
         |> assign(selected: MapSet.new(), expanded: MapSet.new(), filter: "", editing: nil)
         |> assign(improve: %{}, draft: nil)
         |> assign(confirm_delete: false)
         |> plan_defaults(%{}, spec.plan)
         |> allow_upload(:file,
           accept: ~w(.md .markdown .txt),
           max_entries: 1,
           max_file_size: 2_000_000,
           auto_upload: true,
           progress: &handle_progress/3
         )}
    end
  end

  # Saves from this page and the background review and task suggestions all arrive here.
  def handle_info({:spec_updated, spec}, socket) do
    {:noreply,
     socket
     |> plan_defaults(socket.assigns.spec.plan, spec.plan)
     |> assign(spec: spec, page_title: spec.name)}
  end

  # Improving one task with Kiro. Keyed by the task's title when it was asked, so
  # moving tasks around meanwhile doesn't lose the answer.
  def handle_info({:task_activity, title, text}, socket),
    do: {:noreply, update_improve(socket, title, &Map.put(&1, :activity, text))}

  def handle_info({:task_improved, title, result}, socket) do
    {:noreply,
     update_improve(socket, title, fn entry ->
       case result do
         {:ok, suggestion} -> %{entry | status: :done, suggestion: suggestion}
         {:error, reason} -> %{entry | status: :error, error: reason}
       end
     end)}
  end

  # A new task Kiro is writing. The ref tells this draft's answer from an older one.
  def handle_info({:draft_activity, ref, text}, socket),
    do: {:noreply, update_draft(socket, ref, &Map.put(&1, :activity, text))}

  def handle_info({:task_drafted, ref, result}, socket) do
    {:noreply,
     update_draft(socket, ref, fn draft ->
       case result do
         {:ok, suggestion} -> %{draft | status: :done, suggestion: suggestion}
         {:error, reason} -> %{draft | status: :error, error: reason}
       end
     end)}
  end

  # What Kiro is reading while it suggests tasks. Newest last, a few lines.
  def handle_info({:plan_activity, text}, socket),
    do: {:noreply, assign(socket, activity: Enum.take(socket.assigns.activity ++ [text], -6))}

  # When Kiro's questions arrive its recommended options are picked, and when its tasks
  # arrive they are all selected; the person changes what they want from there.
  defp plan_defaults(socket, old, new) do
    socket = assign_new(socket, :picked, fn -> MapSet.new() end)

    socket =
      if new["status"] in ["reading", "writing"] and old["status"] != new["status"],
        do: assign(socket, activity: []),
        else: socket

    cond do
      new["status"] == "questions" and old["status"] != "questions" ->
        answers =
          new["questions"]
          |> Enum.with_index()
          |> Map.new(fn {q, i} -> {to_string(i), hd(q["options"])} end)

        assign(socket, answers: answers, others: %{}, question: 0)

      new["status"] == "tasks" and old["status"] != "tasks" ->
        assign(socket, picked: MapSet.new(0..(length(new["tasks"]) - 1)//1))

      true ->
        socket
    end
  end

  # Without ?step= the page opens on the step being written.
  def handle_params(params, _uri, socket) do
    spec = socket.assigns.spec
    step = params["step"] || default_step(spec)
    step = if step in Spec.steps(), do: step, else: default_step(spec)

    {:noreply,
     assign(socket,
       step: step,
       # Tasks open as the list once there are some; other steps open on Write until approved.
       preview: Spec.approved?(spec, step) or (step == "tasks" and Specs.tasks(spec) != []),
       saved: false,
       undo: nil,
       suggest: Map.has_key?(params, "suggest") and step == "tasks" and Spec.open?(spec, step)
     )}
  end

  defp default_step(spec) do
    case Spec.current_step(spec) do
      "ready" -> "tasks"
      step -> step
    end
  end

  def handle_event("rename", %{"name" => name}, socket) do
    case Specs.update_spec(socket.assigns.spec, %{name: name}) do
      {:ok, spec} -> {:noreply, assign(socket, spec: spec, page_title: spec.name)}
      # A blank name isn't saved; the old one comes back on the next render.
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("edit", %{"text" => text}, socket),
    do: {:noreply, socket |> write(text) |> assign(undo: nil)}

  # The upload form only exists to hold the file input; the file arrives in handle_progress.
  def handle_event("upload_changed", _, socket), do: {:noreply, socket}

  # The task list: selection, filter, expanding details, reordering, deleting.

  def handle_event("task_select", %{"i" => i}, socket) do
    i = String.to_integer(i)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, i),
        do: MapSet.delete(selected, i),
        else: MapSet.put(selected, i)

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("task_select_all", _, socket) do
    shown =
      for {t, i} <- Enum.with_index(Specs.task_list(socket.assigns.spec)),
          FactoryWeb.TaskList.matches?(t, socket.assigns.filter),
          do: i

    {:noreply, assign(socket, selected: MapSet.new(shown))}
  end

  def handle_event("task_select_none", _, socket),
    do: {:noreply, assign(socket, selected: MapSet.new())}

  def handle_event("task_filter", %{"q" => q}, socket),
    do: {:noreply, assign(socket, filter: String.trim(q))}

  def handle_event("task_toggle", %{"i" => i}, socket) do
    i = String.to_integer(i)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, i),
        do: MapSet.delete(expanded, i),
        else: MapSet.put(expanded, i)

    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("task_move", %{"i" => i, "by" => by}, socket),
    do:
      tasks_changed(
        socket,
        Specs.move_task(socket.assigns.spec, String.to_integer(i), String.to_integer(by))
      )

  def handle_event("task_delete", %{"i" => i}, socket),
    do: tasks_changed(socket, Specs.delete_tasks(socket.assigns.spec, [String.to_integer(i)]))

  def handle_event("tasks_delete", _, socket),
    do:
      tasks_changed(
        socket,
        Specs.delete_tasks(socket.assigns.spec, MapSet.to_list(socket.assigns.selected))
      )

  def handle_event("task_edit", %{"i" => i}, socket),
    do: {:noreply, assign(socket, editing: String.to_integer(i))}

  def handle_event("task_edit_cancel", _, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("task_save", %{"i" => i} = params, socket) do
    i = String.to_integer(i)
    old = socket.assigns.spec |> Specs.task_list() |> Enum.at(i)

    case Specs.update_task(socket.assigns.spec, i, params) do
      {:error, :blank_title} ->
        {:noreply, put_flash(socket, :error, "A task needs a title.")}

      {:error, :not_found} ->
        {:noreply, assign(socket, editing: nil)}

      result ->
        socket = assign(socket, improve: Map.delete(socket.assigns.improve, old.title))
        tasks_changed(socket, result)
    end
  end

  # Improving a task with Kiro: say what should be better, then apply, edit or
  # discard what Kiro suggests.

  def handle_event("improve_open", %{"i" => i}, socket) do
    case socket.assigns.spec |> Specs.task_list() |> Enum.at(String.to_integer(i)) do
      nil ->
        {:noreply, socket}

      task ->
        entry = %{status: :asking, instruction: "", suggestion: nil, error: nil, activity: nil}

        {:noreply,
         assign(socket, improve: Map.put_new(socket.assigns.improve, task.title, entry))}
    end
  end

  def handle_event("improve_send", %{"title" => title, "instruction" => instruction}, socket) do
    with i when is_integer(i) <- task_index(socket, title),
         {:ok, _} <- Specs.improve_task(socket.assigns.spec, i, instruction) do
      {:noreply,
       update_improve(socket, title, fn entry ->
         %{entry | status: :thinking, instruction: instruction, error: nil, activity: nil}
       end)}
    else
      _ -> {:noreply, close_improve(socket, title)}
    end
  end

  def handle_event("improve_retry", %{"title" => title}, socket),
    do: {:noreply, update_improve(socket, title, &%{&1 | status: :asking})}

  def handle_event("improve_close", %{"title" => title}, socket),
    do: {:noreply, close_improve(socket, title)}

  def handle_event("improve_apply", %{"title" => title}, socket) do
    with %{status: :done, suggestion: s} <- socket.assigns.improve[title],
         i when is_integer(i) <- task_index(socket, title) do
      params = %{
        "title" => s.title,
        "details" => Enum.join(s.details, "\n"),
        "requirements" => Enum.join(s.requirements, ", ")
      }

      tasks_changed(
        close_improve(socket, title),
        Specs.update_task(socket.assigns.spec, i, params)
      )
    else
      _ -> {:noreply, close_improve(socket, title)}
    end
  end

  # Opens the edit form filled with Kiro's suggestion; saving it applies it.
  def handle_event("improve_edit", %{"title" => title}, socket) do
    case task_index(socket, title) do
      nil -> {:noreply, close_improve(socket, title)}
      i -> {:noreply, assign(socket, editing: i)}
    end
  end

  # Adding a task: write a rough title and notes, then add it as is or let Kiro
  # scope the project and write it out; review what Kiro wrote before it's added.

  def handle_event("draft_open", _, socket) do
    draft = %{
      status: :writing,
      title: "",
      notes: "",
      ref: nil,
      suggestion: nil,
      error: nil,
      activity: nil
    }

    {:noreply, assign(socket, draft: draft)}
  end

  def handle_event("draft_close", _, socket), do: {:noreply, assign(socket, draft: nil)}

  def handle_event("draft_change", params, socket) do
    {:noreply,
     update(socket, :draft, fn draft ->
       draft && %{draft | title: params["title"] || "", notes: params["notes"] || ""}
     end)}
  end

  def handle_event("draft_submit", %{"action" => "add"} = params, socket) do
    params = %{"title" => params["title"], "details" => params["notes"]}
    added(socket, Specs.add_task(socket.assigns.spec, params))
  end

  def handle_event("draft_submit", params, socket) do
    title = String.trim(params["title"] || "")
    notes = String.trim(params["notes"] || "")

    if title == "" and notes == "" do
      {:noreply, put_flash(socket, :error, "Write a title or a few notes for Kiro first.")}
    else
      ref = System.unique_integer([:positive])
      :ok = Specs.draft_task(socket.assigns.spec, title, notes, ref)

      draft = %{
        socket.assigns.draft
        | status: :thinking,
          title: title,
          notes: notes,
          ref: ref,
          error: nil,
          activity: nil
      }

      {:noreply, assign(socket, draft: draft)}
    end
  end

  def handle_event("draft_retry", _, socket),
    do: {:noreply, update(socket, :draft, &(&1 && %{&1 | status: :writing, ref: nil}))}

  def handle_event("draft_edit", _, socket),
    do: {:noreply, update(socket, :draft, &(&1 && %{&1 | status: :editing}))}

  def handle_event("draft_back", _, socket),
    do: {:noreply, update(socket, :draft, &(&1 && %{&1 | status: :done}))}

  def handle_event("draft_accept", _, socket) do
    case socket.assigns.draft do
      %{suggestion: %{} = s} ->
        params = %{
          "title" => s.title,
          "details" => Enum.join(s.details, "\n"),
          "requirements" => Enum.join(s.requirements, ", ")
        }

        added(socket, Specs.add_task(socket.assigns.spec, params))

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("draft_save", params, socket),
    do: added(socket, Specs.add_task(socket.assigns.spec, params))

  # The queue.

  def handle_event("queue_add", %{"title" => title}, socket),
    do: queue_changed(socket, Specs.queue_tasks(socket.assigns.spec, [title]))

  def handle_event("queue_remove", %{"title" => title}, socket),
    do: queue_changed(socket, Specs.unqueue_tasks(socket.assigns.spec, [title]))

  def handle_event("queue_selected", _, socket),
    do:
      queue_changed(socket, Specs.queue_tasks(socket.assigns.spec, selected_titles(socket)),
        clear: true
      )

  def handle_event("unqueue_selected", _, socket),
    do:
      queue_changed(socket, Specs.unqueue_tasks(socket.assigns.spec, selected_titles(socket)),
        clear: true
      )

  def handle_event("queue_move", %{"title" => title, "by" => by}, socket),
    do:
      queue_changed(socket, Specs.move_queued(socket.assigns.spec, title, String.to_integer(by)))

  def handle_event("queue_all", _, socket) do
    titles = socket.assigns.spec |> Specs.task_list() |> Enum.map(& &1.title)
    queue_changed(socket, Specs.queue_tasks(socket.assigns.spec, titles))
  end

  def handle_event("queue_clear", _, socket),
    do: queue_changed(socket, Specs.clear_queue(socket.assigns.spec))

  # Suggest tasks with Kiro: the window's own URL, so a reload keeps it open.
  def handle_event("suggest", _, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/specs/#{socket.assigns.spec.id}?step=tasks&suggest")}

  def handle_event("close_suggest", _, socket),
    do: {:noreply, push_patch(socket, to: ~p"/specs/#{socket.assigns.spec.id}?step=tasks")}

  def handle_event("plan_read", %{"dir" => dir}, socket) do
    case Specs.plan_questions(socket.assigns.spec, dir) do
      {:ok, spec} ->
        {:noreply, assign(socket, spec: spec)}

      {:error, :no_folder} ->
        {:noreply, put_flash(socket, :error, "There's no folder at #{dir}.")}

      {:error, :running} ->
        {:noreply, socket}
    end
  end

  # Picking an option, or typing into a question's "Other" box (which picks it).
  # Only the question on screen is in the form, so its answer is merged into the rest.
  def handle_event("plan_answer", params, socket) do
    others = Map.merge(socket.assigns.others, Map.get(params, "other", %{}))
    answers = Map.merge(socket.assigns.answers, Map.get(params, "answer", %{}))

    answers =
      Enum.reduce(Map.get(params, "other", %{}), answers, fn {i, text}, acc ->
        if String.trim(text) != "" and text != socket.assigns.others[i],
          do: Map.put(acc, i, "__other"),
          else: acc
      end)

    {:noreply, assign(socket, answers: answers, others: others)}
  end

  # Questions are shown one at a time: Enter (or Next) moves on, and on the last one
  # sends the answers.
  def handle_event("plan_next", _, socket) do
    last = length(socket.assigns.spec.plan["questions"] || []) - 1

    if socket.assigns.question >= last,
      do: handle_event("plan_tasks", %{}, socket),
      else: {:noreply, assign(socket, question: socket.assigns.question + 1)}
  end

  def handle_event("plan_question", %{"i" => i}, socket) do
    count = length(socket.assigns.spec.plan["questions"] || [])
    {:noreply, assign(socket, question: i |> String.to_integer() |> max(0) |> min(count - 1))}
  end

  def handle_event("plan_tasks", _, socket) do
    %{spec: spec, answers: answers, others: others} = socket.assigns

    answered =
      for {q, i} <- Enum.with_index(spec.plan["questions"] || []),
          answer = answer_text(answers[to_string(i)], others[to_string(i)]),
          do: %{"question" => q["question"], "answer" => answer}

    plan_tasks(socket, answered)
  end

  def handle_event("plan_skip", _, socket), do: plan_tasks(socket, [])

  def handle_event("plan_pick", params, socket) do
    picked = params |> Map.get("pick", []) |> MapSet.new(&String.to_integer/1)

    {:noreply,
     assign(socket, picked: picked, add_mode: params["mode"] || socket.assigns.add_mode)}
  end

  def handle_event("plan_all", _, socket) do
    count = length(socket.assigns.spec.plan["tasks"] || [])
    {:noreply, assign(socket, picked: MapSet.new(0..(count - 1)//1))}
  end

  def handle_event("plan_none", _, socket), do: {:noreply, assign(socket, picked: MapSet.new())}

  def handle_event("plan_add", _, socket) do
    %{spec: spec, picked: picked, add_mode: mode} = socket.assigns

    tasks =
      for {task, i} <- Enum.with_index(spec.plan["tasks"] || []),
          MapSet.member?(picked, i),
          do: task

    mode = if mode == "replace", do: :replace, else: :append

    with [_ | _] <- tasks,
         true <- Spec.open?(spec, "tasks") and not Spec.approved?(spec, "tasks"),
         {:ok, spec} <- Specs.add_tasks(spec, tasks, mode),
         {:ok, spec} <- Specs.reset_plan(spec) do
      {:noreply,
       socket
       |> assign(spec: spec, preview: false)
       |> put_flash(
         :info,
         "Added #{length(tasks)} #{if length(tasks) == 1, do: "task", else: "tasks"}."
       )
       |> push_patch(to: ~p"/specs/#{spec.id}?step=tasks")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("plan_restart", _, socket) do
    {:ok, spec} = Specs.reset_plan(socket.assigns.spec)
    {:noreply, assign(socket, spec: spec)}
  end

  def handle_event("plan_retry", _, socket) do
    spec = socket.assigns.spec

    case spec.plan["failed"] do
      "writing" -> plan_tasks(socket, spec.plan["answers"] || [])
      _ -> handle_event("plan_read", %{"dir" => Specs.project_dir(spec)}, socket)
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  def handle_event("undo", _, socket) do
    case socket.assigns.undo do
      %{step: step, text: text} when step == socket.assigns.step ->
        {:noreply, socket |> write(text) |> assign(undo: nil, preview: false)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("write_missing", _, socket) do
    case Specs.write_missing(socket.assigns.spec) do
      {:ok, spec} -> {:noreply, assign(socket, spec: spec, activity: [])}
      {:error, :nothing_missing} -> {:noreply, put_flash(socket, :info, "Every part is written.")}
    end
  end

  # The base specs (company rules) the run this spec plans follows.
  def handle_event("toggle_base", %{"id" => id}, socket) do
    run = Runs.get_run(socket.assigns.home_run.id)
    id = String.to_integer(id)
    ids = run.settings["base_spec_ids"] || []
    ids = if id in ids, do: List.delete(ids, id), else: ids ++ [id]
    {:ok, run} = Runs.update_run(run, %{settings: Map.put(run.settings, "base_spec_ids", ids)})
    {:noreply, assign(socket, home_run: run)}
  end

  def handle_event("review", _, socket) do
    case Specs.review(socket.assigns.spec) do
      {:ok, spec} -> {:noreply, assign(socket, spec: spec)}
      {:error, :empty} -> {:noreply, put_flash(socket, :error, "Write something first.")}
      {:error, :running} -> {:noreply, socket}
    end
  end

  def handle_event("drop_rejected", %{"name" => name}, socket),
    do:
      {:noreply,
       put_flash(
         socket,
         :error,
         "#{name} can't be used here: drop a .md or .txt file up to 2 MB."
       )}

  def handle_event("outline", _, socket),
    do: {:noreply, socket |> write(outline(socket.assigns.step)) |> assign(preview: false)}

  def handle_event("preview", %{"on" => on}, socket),
    do: {:noreply, assign(socket, preview: on == "true")}

  def handle_event("approve", _, socket) do
    %{spec: spec, step: step} = socket.assigns

    case Specs.approve(spec, step) do
      {:ok, spec} ->
        socket = assign(socket, spec: spec)

        case next_step(step) do
          nil -> {:noreply, assign(socket, preview: true)}
          next -> {:noreply, push_patch(socket, to: ~p"/specs/#{spec.id}?step=#{next}")}
        end

      {:error, :empty} ->
        {:noreply,
         put_flash(socket, :error, "Write the #{String.downcase(step_label(step))} first.")}

      {:error, :no_tasks} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No tasks found. Tasks are top-level lines like - [ ] 1. Add the login form"
         )}

      {:error, :locked} ->
        {:noreply, socket}
    end
  end

  def handle_event("reopen", _, socket) do
    {:ok, spec} = Specs.reopen(socket.assigns.spec, socket.assigns.step)
    {:noreply, assign(socket, spec: spec, preview: false)}
  end

  def handle_event("start", _, socket) do
    case Specs.start_run(socket.assigns.spec) do
      {:ok, run} -> {:noreply, push_navigate(socket, to: ~p"/chat/#{run.id}")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Approve all three steps first.")}
    end
  end

  # Deleting asks first, in a window of its own.
  def handle_event("ask_delete", _, socket), do: {:noreply, assign(socket, confirm_delete: true)}

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, confirm_delete: false)}

  def handle_event("delete", _, socket) do
    {:ok, _} = Specs.delete_spec(socket.assigns.spec)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{socket.assigns.spec.name}.")
     |> push_navigate(to: ~p"/specs")}
  end

  # Indices change when tasks move or go, so selection and expanded rows start over.
  defp tasks_changed(socket, {:ok, spec}),
    do:
      {:noreply,
       assign(socket, spec: spec, selected: MapSet.new(), expanded: MapSet.new(), editing: nil)}

  defp tasks_changed(socket, {:error, :locked}),
    do: {:noreply, put_flash(socket, :error, "Click Edit to change approved tasks.")}

  defp queue_changed(socket, {:ok, spec}, opts \\ []) do
    socket = assign(socket, spec: spec)
    {:noreply, if(opts[:clear], do: assign(socket, selected: MapSet.new()), else: socket)}
  end

  # A task was added: it's last, so it opens (and shows highlighted) there.
  defp added(socket, {:ok, spec}) do
    last = length(Specs.task_list(spec)) - 1
    {:noreply, socket} = tasks_changed(socket, {:ok, spec})
    {:noreply, assign(socket, draft: nil, expanded: MapSet.new([last]), filter: "")}
  end

  defp added(socket, {:error, :blank_title}),
    do: {:noreply, put_flash(socket, :error, "A task needs a title.")}

  defp added(socket, error), do: tasks_changed(socket, error)

  defp update_draft(socket, ref, fun) do
    case socket.assigns.draft do
      %{ref: ^ref} = draft when ref != nil -> assign(socket, draft: fun.(draft))
      _ -> socket
    end
  end

  defp task_index(socket, title),
    do: socket.assigns.spec |> Specs.task_list() |> Enum.find_index(&(&1.title == title))

  defp update_improve(socket, title, fun) do
    case socket.assigns.improve do
      %{^title => entry} = improve -> assign(socket, improve: %{improve | title => fun.(entry)})
      _ -> socket
    end
  end

  defp close_improve(socket, title),
    do: assign(socket, improve: Map.delete(socket.assigns.improve, title))

  defp selected_titles(socket) do
    for {t, i} <- Enum.with_index(Specs.task_list(socket.assigns.spec)),
        MapSet.member?(socket.assigns.selected, i),
        do: t.title
  end

  defp plan_tasks(socket, answers) do
    case Specs.plan_tasks(socket.assigns.spec, answers) do
      {:ok, spec} -> {:noreply, assign(socket, spec: spec)}
      {:error, :running} -> {:noreply, socket}
    end
  end

  defp answer_text("__other", other), do: blank_nil(other)
  defp answer_text(nil, _other), do: nil
  defp answer_text(option, _other), do: option

  defp blank_nil(nil), do: nil
  defp blank_nil(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  # An uploaded file fills the open step. If it replaced text, that can be undone.
  defp handle_progress(:file, entry, socket) do
    if entry.done? do
      text =
        consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

      old = text(socket.assigns.spec, socket.assigns.step)

      if String.valid?(text) do
        undo =
          if String.trim(old) != "",
            do: %{step: socket.assigns.step, text: old, name: entry.client_name}

        {:noreply, socket |> write(text) |> assign(undo: undo, preview: false)}
      else
        {:noreply, put_flash(socket, :error, "#{entry.client_name} isn't a text file.")}
      end
    else
      {:noreply, socket}
    end
  end

  # Saves the open step's text. Approved and locked steps can't be changed.
  defp write(socket, text) do
    %{spec: spec, step: step} = socket.assigns

    if Spec.open?(spec, step) and not Spec.approved?(spec, step) do
      {:ok, spec} = Specs.update_spec(spec, %{step => text})
      assign(socket, spec: spec, saved: true)
    else
      socket
    end
  end

  defp next_step("overview"), do: "requirements"
  defp next_step("requirements"), do: "design"
  defp next_step("design"), do: "tasks"
  defp next_step("tasks"), do: nil

  defp text(spec, step), do: Map.fetch!(spec, String.to_existing_atom(step))

  def render(assigns) do
    assigns =
      assign(assigns,
        text: text(assigns.spec, assigns.step),
        open: Spec.open?(assigns.spec, assigns.step),
        approved: Spec.approved?(assigns.spec, assigns.step),
        ready: Spec.current_step(assigns.spec) == "ready",
        tasks: Specs.tasks(assigns.spec),
        task_list: if(assigns.step == "tasks", do: Specs.task_list(assigns.spec), else: [])
      )

    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active={:specs}>
      <Layouts.back_link :if={!@home_run} to={~p"/specs"}>Specs</Layouts.back_link>
      <Layouts.back_link :if={@home_run} to={~p"/chat/#{@home_run.id}"}>
        {@home_run.title}
      </Layouts.back_link>

      <div class="mb-8 flex flex-wrap items-start justify-between gap-4">
        <form id="spec-name" phx-change="rename" phx-submit="rename" class="min-w-0 flex-1">
          <input
            name="name"
            value={@spec.name}
            maxlength="80"
            phx-debounce="500"
            aria-label="Spec name"
            class="-mx-1 w-full rounded-md bg-transparent px-1 text-3xl font-semibold tracking-tight font-stretch-semi-condensed outline-none hover:bg-base-200 focus:bg-base-200 sm:text-4xl"
          />
        </form>
        <div class="flex items-center gap-2 pt-1">
          <button
            :if={@ready}
            id="start-run"
            phx-click="start"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-play-mini" class="size-4" />
            {if @spec.queue == [],
              do: "Start run",
              else: "Start run with #{length(@spec.queue)} queued"}
          </button>
        </div>
      </div>

      <.steps spec={@spec} step={@step} />

      <div class="mt-6 grid gap-10 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div>
          <%!-- A step that isn't open yet: say which step to finish first. --%>
          <section
            :if={!@open}
            id="step-locked"
            class="rounded-lg border border-dashed border-base-300 px-6 py-12 text-center"
          >
            <.icon name="hero-lock-closed" class="size-5 text-base-content/35" />
            <h2 class="mt-2 font-medium">
              Finish the {step_label(Spec.current_step(@spec))} first
            </h2>
            <p class="mx-auto mt-1 max-w-sm text-sm text-base-content/60">
              {step_label(@step)}: {purpose(@step)} Steps open one at a time, as you approve them.
            </p>
            <.link
              patch={~p"/specs/#{@spec.id}?step=#{Spec.current_step(@spec)}"}
              class="btn btn-sm mt-5"
            >
              Go to {step_label(Spec.current_step(@spec))}
            </.link>
          </section>

          <section :if={@open}>
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
            />

            <FactoryWeb.TaskList.new_task
              :if={@step == "tasks" && @open && (@preview || @task_list == [])}
              draft={@draft}
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
              {upload_error(err)}
            </p>
            <p
              :for={{entry, err} <- entry_errors(@uploads.file)}
              class="mt-2 text-sm text-error"
            >
              {entry.client_name}: {upload_error(err)}
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
        </div>

        <aside class="space-y-8 text-sm">
          <.write_panel spec={@spec} activity={@activity} />
          <.rules_panel :if={@home_run} run={@home_run} />
          <.review_panel :if={@step != "tasks"} spec={@spec} />

          <FactoryWeb.TaskList.queue
            :if={@step == "tasks" && @open && @task_list != []}
            queue={@task_list |> Enum.filter(& &1.queued) |> Enum.sort_by(& &1.queued)}
            ready={@ready}
          />

          <.review_panel :if={@step == "tasks"} spec={@spec} />

          <div :if={@step == "tasks" && @open && @task_list == []}>
            <h2 class="font-medium">No tasks yet</h2>
            <p class="mt-1 text-base-content/65">
              Each top-level line like <code class="code-inline">- [ ] 1. Title</code> becomes a task.
            </p>
          </div>

          <div :if={@spec.runs != []}>
            <h2 class="font-medium">Runs</h2>
            <ul class="mt-2 space-y-2">
              <li :for={run <- @spec.runs}>
                <.link
                  navigate={~p"/chat/#{run.id}"}
                  class="flex items-center justify-between gap-3 hover:text-base-content"
                >
                  <span class="truncate text-base-content/75">
                    Started {Layouts.ago(run.inserted_at)}
                  </span>
                  <Layouts.status_badge status={run.status} />
                </.link>
              </li>
            </ul>
          </div>
        </aside>
      </div>

      <section class="mt-16 flex flex-wrap items-center justify-between gap-4 border-t border-base-300 pt-6">
        <div class="text-sm">
          <h2 class="font-medium">Delete this spec</h2>
          <p class="mt-0.5 text-base-content/60">
            Removes its requirements, design and tasks. Runs started from it are kept.
          </p>
        </div>
        <button
          id="ask-delete"
          phx-click="ask_delete"
          class="btn btn-sm btn-outline border-error/40 text-error hover:border-error hover:bg-error hover:text-error-content"
        >
          <.icon name="hero-trash-mini" class="size-4" /> Delete spec
        </button>
      </section>

      <div
        :if={@confirm_delete}
        id="confirm-delete"
        class="fixed inset-0 z-50 grid place-items-center bg-base-content/25 p-4 backdrop-blur-[2px]"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="confirm-delete-title"
        phx-window-keydown="cancel_delete"
        phx-key="Escape"
      >
        <div class="absolute inset-0" phx-click="cancel_delete" aria-hidden="true"></div>
        <div class="relative w-full max-w-md rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl">
          <div class="flex items-start gap-3">
            <span class="grid size-9 shrink-0 place-items-center rounded-full bg-error/15 text-error">
              <.icon name="hero-trash" class="size-5" />
            </span>
            <div>
              <h2 id="confirm-delete-title" class="font-semibold">Delete “{@spec.name}”?</h2>
              <p class="mt-1.5 text-sm leading-relaxed text-base-content/75">
                Its requirements, design, {length(Specs.tasks(@spec))} tasks and Kiro's review
                are deleted for good. Runs started from it are kept.
              </p>
            </div>
          </div>
          <div class="mt-6 flex justify-end gap-2">
            <button phx-click="cancel_delete" class="btn btn-ghost btn-sm" autofocus>Cancel</button>
            <button id="confirm-delete-button" phx-click="delete" class="btn btn-error btn-sm">
              Delete spec
            </button>
          </div>
        </div>
      </div>

      <FactoryWeb.SuggestTasks.window
        :if={@suggest}
        spec={@spec}
        activity={@activity}
        answers={@answers}
        others={@others}
        question={@question}
        picked={@picked}
        add_mode={@add_mode}
        project_dir={Specs.project_dir(@spec)}
      />
    </Layouts.app>
    """
  end

  attr :spec, Spec, required: true
  attr :activity, :list, required: true

  # Kiro writes the parts the spec is missing (Factory.Specs.write_missing/1).
  defp write_panel(assigns) do
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
  defp rules_panel(assigns) do
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
  defp steps(assigns) do
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

  defp tab_class(true), do: "bg-base-100 font-medium shadow-sm"
  defp tab_class(false), do: "text-base-content/60 hover:text-base-content"

  defp prev_step("requirements"), do: "overview"
  defp prev_step("design"), do: "requirements"
  defp prev_step("tasks"), do: "design"
  defp prev_step(_), do: "overview"

  defp reopen_confirm(spec, step) do
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
  defp purpose("overview"), do: "what you're building and why."
  defp purpose("requirements"), do: "what it must do."
  defp purpose("design"), do: "how it will be built."
  defp purpose("tasks"), do: "the steps to build it, in order."

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

  defp entry_errors(upload),
    do: for(entry <- upload.entries, err <- upload_errors(upload, entry), do: {entry, err})

  defp upload_error(:too_large), do: "larger than 2 MB"
  defp upload_error(:not_accepted), do: "only .md and .txt files"
  defp upload_error(:too_many_files), do: "one file at a time"
  defp upload_error(err), do: to_string(err)

  # An empty step's text box says what to write in it.
  defp placeholder(step) do
    {question, explanation} = intro(step)
    "#{question}\n\n#{explanation}\n\nOr drop a .md or .txt file here."
  end

  defp outline("overview") do
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

  defp outline("requirements") do
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

  defp outline("design") do
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

  defp outline("tasks") do
    """
    # Implementation plan

    - [ ] 1. First task
      - What to build, in a line or two
      - _Requirements: 1.1_

    - [ ] 2. Second task
      - _Requirements: 1.2_
    """
  end
end
