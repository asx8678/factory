defmodule FactoryWeb.SpecLive do
  @moduledoc "One spec: its overview, requirements, design and tasks, written and approved in order."
  use FactoryWeb, :live_view
  import FactoryWeb.SpecPageParts
  alias Factory.{Runs, Specs}
  alias Factory.Specs.Spec

  def mount(%{"id" => id}, _session, socket) do
    case spec_by_id(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "That spec doesn't exist.") |> push_navigate(to: ~p"/specs")}

      spec ->
        if connected?(socket), do: Specs.subscribe(spec.id)

        {:ok,
         socket
         |> FactoryWeb.UsageMeter.scope({:spec, spec.id})
         |> assign(home_run: Specs.home_run(spec))
         |> put_spec(spec)
         |> assign(page_title: spec.name, preview: false, saved: false, undo: nil)
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

  # A spec by the id in the URL; nil for an id that isn't a number, as for one that's gone.
  defp spec_by_id(id) do
    case Integer.parse(id) do
      {n, ""} -> Specs.get_spec(n)
      _ -> nil
    end
  end

  # The spec, and its tasks parsed once (Factory.Specs.task_list/1) for the list, the
  # queue and the handlers, rather than on every render.
  defp put_spec(socket, spec),
    do: assign(socket, spec: spec, task_list: Specs.task_list(spec))

  # Saves from this page and the background review and task suggestions all arrive here.
  def handle_info({:spec_updated, spec}, socket) do
    socket =
      if task_structure(socket.assigns.spec) != task_structure(spec),
        do: assign(socket, selected: MapSet.new(), expanded: MapSet.new(), editing: nil),
        else: socket

    {:noreply,
     socket
     |> plan_defaults(socket.assigns.spec.plan, spec.plan)
     |> put_spec(spec)
     |> assign(page_title: spec.name)}
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
       preview:
         Spec.approved?(spec, step) or (step == "tasks" and socket.assigns.task_list != []),
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
      {:ok, spec} -> {:noreply, socket |> put_spec(spec) |> assign(page_title: spec.name)}
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
      for {t, i} <- Enum.with_index(socket.assigns.task_list),
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

    if socket.assigns.editing == i do
      old = Enum.at(socket.assigns.task_list, i)

      case Specs.update_task(socket.assigns.spec, i, params) do
        {:error, :blank_title} ->
          {:noreply, put_flash(socket, :error, "A task needs a title.")}

        {:error, :not_found} ->
          {:noreply, assign(socket, editing: nil)}

        result ->
          socket = assign(socket, improve: Map.delete(socket.assigns.improve, old.title))
          tasks_changed(socket, result)
      end
    else
      {:noreply, socket}
    end
  end

  # Improving a task with Kiro: say what should be better, then apply, edit or
  # discard what Kiro suggests.

  def handle_event("improve_open", %{"i" => i}, socket) do
    case Enum.at(socket.assigns.task_list, String.to_integer(i)) do
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
      params = Specs.task_params(s)

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
        added(socket, Specs.add_task(socket.assigns.spec, Specs.task_params(s)))

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
    titles = Enum.map(socket.assigns.task_list, & &1.title)
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
        {:noreply, put_spec(socket, spec)}

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
  def handle_event("plan_next", params, socket) do
    {:noreply, socket} = handle_event("plan_answer", params, socket)
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
       |> put_spec(spec)
       |> assign(preview: false)
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
    {:noreply, put_spec(socket, spec)}
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
      {:ok, spec} -> {:noreply, socket |> put_spec(spec) |> assign(activity: [])}
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
      {:ok, spec} -> {:noreply, put_spec(socket, spec)}
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
        socket = put_spec(socket, spec)

        case Spec.step_after(step) do
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
    {:noreply, socket |> put_spec(spec) |> assign(preview: false)}
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
  # Markdown tasks have no stable ids; their ordered titles identify the rows.
  defp task_structure(spec), do: spec |> Specs.task_list() |> Enum.map(&{&1.ref, &1.title})

  defp tasks_changed(socket, {:ok, spec}),
    do:
      {:noreply,
       socket
       |> put_spec(spec)
       |> assign(selected: MapSet.new(), expanded: MapSet.new(), editing: nil)}

  defp tasks_changed(socket, {:error, :locked}),
    do: {:noreply, put_flash(socket, :error, "Click Edit to change approved tasks.")}

  # The tasks are saved; a draft run couldn't follow them.
  defp tasks_changed(socket, {:error, reason}),
    do:
      {:noreply,
       put_flash(socket, :error, "Saved, but a run couldn't follow the change: #{why(reason)}")}

  defp queue_changed(socket, {:ok, spec}, opts \\ []) do
    socket = put_spec(socket, spec)
    {:noreply, if(opts[:clear], do: assign(socket, selected: MapSet.new()), else: socket)}
  end

  defp queue_changed(socket, {:error, reason}, _opts),
    do: {:noreply, put_flash(socket, :error, why(reason))}

  # A task was added: it's last, so it opens (and shows highlighted) there.
  defp added(socket, {:ok, spec}) do
    last = length(Specs.task_list(spec)) - 1
    {:noreply, socket} = tasks_changed(socket, {:ok, spec})
    {:noreply, assign(socket, draft: nil, expanded: MapSet.new([last]), filter: "")}
  end

  defp added(socket, {:error, :blank_title}),
    do: {:noreply, put_flash(socket, :error, "A task needs a title.")}

  defp added(socket, {:error, reason}), do: tasks_changed(socket, {:error, reason})

  defp added(socket, error), do: tasks_changed(socket, error)

  defp update_draft(socket, ref, fun) do
    case socket.assigns.draft do
      %{ref: ^ref} = draft when ref != nil -> assign(socket, draft: fun.(draft))
      _ -> socket
    end
  end

  defp task_index(socket, title),
    do: Enum.find_index(socket.assigns.task_list, &(&1.title == title))

  defp update_improve(socket, title, fun) do
    case socket.assigns.improve do
      %{^title => entry} = improve -> assign(socket, improve: %{improve | title => fun.(entry)})
      _ -> socket
    end
  end

  defp close_improve(socket, title),
    do: assign(socket, improve: Map.delete(socket.assigns.improve, title))

  defp selected_titles(socket) do
    for {t, i} <- Enum.with_index(socket.assigns.task_list),
        MapSet.member?(socket.assigns.selected, i),
        do: t.title
  end

  defp plan_tasks(socket, answers) do
    case Specs.plan_tasks(socket.assigns.spec, answers) do
      {:ok, spec} -> {:noreply, put_spec(socket, spec)}
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
      case Specs.update_spec(spec, %{step => text}) do
        {:ok, spec} ->
          socket |> put_spec(spec) |> assign(saved: true)

        {:error, %Ecto.Changeset{}} ->
          socket

        # The text is saved; a draft run couldn't follow it.
        {:error, reason} ->
          socket
          |> put_spec(Specs.get_spec(spec.id))
          |> assign(saved: true)
          |> put_flash(:error, "Saved, but a run couldn't follow the change: #{why(reason)}")
      end
    else
      socket
    end
  end

  defp text(spec, step), do: Map.fetch!(spec, String.to_existing_atom(step))

  def render(assigns) do
    assigns =
      assign(assigns,
        text: text(assigns.spec, assigns.step),
        open: Spec.open?(assigns.spec, assigns.step),
        approved: Spec.approved?(assigns.spec, assigns.step),
        ready: Spec.current_step(assigns.spec) == "ready",
        name_form: to_form(%{"name" => assigns.spec.name})
      )

    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active_runs={@active_runs} active={:specs}>
      <Layouts.back_link :if={!@home_run} to={~p"/specs"}>Specs</Layouts.back_link>
      <Layouts.back_link :if={@home_run} to={~p"/chat/#{@home_run.id}"}>
        {@home_run.title}
      </Layouts.back_link>

      <div class="mb-8 flex flex-wrap items-start justify-between gap-4">
        <.form
          for={@name_form}
          id="spec-name"
          phx-change="rename"
          phx-submit="rename"
          class="min-w-0 flex-1"
        >
          <.input
            field={@name_form[:name]}
            id="spec-name-input"
            maxlength="80"
            phx-debounce="500"
            aria-label="Spec name"
            class="-mx-1 w-full rounded-md bg-transparent px-1 text-xl font-semibold tracking-tight outline-none hover:bg-base-200 focus:bg-base-200"
            wrapper_class="block"
          />
        </.form>
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

          <.step_editor
            :if={@open}
            open={@open}
            spec={@spec}
            step={@step}
            approved={@approved}
            preview={@preview}
            text={@text}
            saved={@saved}
            undo={@undo}
            uploads={@uploads}
            task_list={@task_list}
            draft={@draft}
            editing={@editing}
            expanded={@expanded}
            filter={@filter}
            builders={if @step == "tasks", do: Enum.map(Specs.builders(@spec), & &1.name), else: []}
            improve={@improve}
            selected={@selected}
          />
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
        <div class="relative w-full max-w-md rounded-xl border border-base-300 bg-base-100 p-6 shadow-2xl">
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

  defp why(reason) when is_binary(reason), do: reason
  defp why(reason), do: inspect(reason)
end
