defmodule FactoryWeb.ChatLive.Plan do
  @moduledoc """
  The plan being made in the chat (`FactoryWeb.ChatLive`, shown by
  `FactoryWeb.PlanPanel`): the run's spec it lives in, followed while the chat is open,
  and the panel's events. Each task can be edited (in its form or in place), removed,
  or handed to Kiro to flesh out from the code or change as asked; the planner can
  check the plan's scope, or rework the whole plan.

  Everything here takes the chat's socket; the chat works out what it shows from the
  plan (`show?/1`, `working/1`, `spec_hint?/1`) once these return.
  """
  import Ecto.Query, only: [from: 2]
  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]
  alias Factory.{Repo, Runs, Specs, Workflows}
  alias Factory.Runs.Message
  alias FactoryWeb.TaskImprove

  @doc """
  The run's spec, where its plan lives; followed while the chat is open, so Kiro's
  work on a task and every change to the plan show here.
  """
  def load(socket) do
    run = socket.assigns.run

    {run, spec} =
      cond do
        run == nil ->
          {nil, nil}

        run.spec_id ->
          {run, Specs.get_spec(run.spec_id)}

        # A plan whose spec was deleted (on the Specs page) comes back from the chat's
        # own copy of it, so its tasks aren't lost while the chat is being planned.
        # That makes a spec, so it waits for the connected render.
        run.status == "draft" and run.tasks != [] and connected?(socket) ->
          spec = Specs.for_run(run)
          {Runs.get_run(run.id), spec}

        true ->
          {run, nil}
      end

    socket = assign(socket, run: run)
    old = socket.assigns.plan_sub

    if connected?(socket) and old != (spec && spec.id) do
      if old, do: Phoenix.PubSub.unsubscribe(Factory.PubSub, "spec:#{old}")
      if spec, do: Specs.subscribe(spec.id)
    end

    socket
    |> put_plan_spec(spec)
    |> assign(
      plan_check: latest_check(run, socket.assigns[:planner]),
      plan_before: if(old == (spec && spec.id), do: socket.assigns[:plan_before]),
      plan_sub: spec && spec.id,
      plan_editing: nil,
      plan_asking: nil,
      plan_improve: %{},
      plan_inline: nil
    )
  end

  @doc """
  The plan as it was before the planner reworks it (FactoryWeb.PlanDiff), so the panel
  can mark in gold what it changed. Only a plan that has tasks is kept.
  """
  def remember(socket) do
    case socket.assigns.plan_tasks do
      [] -> socket
      tasks -> assign(socket, plan_before: FactoryWeb.PlanDiff.snapshot(tasks))
    end
  end

  @doc """
  The plan panel shows while the run is being planned, in the All view, once there are
  tasks. It stays while the planner reworks them, showing what it's doing.
  """
  def show?(assigns) do
    run = assigns.run

    run != nil and run.status == "draft" and assigns.focus == nil and
      assigns.plan_spec != nil and run.tasks != []
  end

  @doc "What the planner is doing right now, for the panel's header; nil when it's idle."
  def working(assigns) do
    with %{id: id} <- assigns.planner,
         %{} = chunk <- assigns.streaming[id] do
      chunk[:activity] ||
        if(Workflows.kind(assigns.workflow) == "review",
          do: "Reviewing…",
          else: "Working on the plan…"
        )
    else
      _ -> nil
    end
  end

  @doc "No base specs and no requirements of its own: offer to add some."
  def spec_hint?(assigns),
    do: assigns.base_ids == [] and String.trim(assigns.plan_spec.requirements || "") == ""

  def handle_event("plan_edit", %{"i" => i}, socket),
    do: {:noreply, assign(socket, plan_editing: String.to_integer(i), plan_asking: nil)}

  def handle_event("plan_edit_cancel", _, socket),
    do: {:noreply, assign(socket, plan_editing: nil)}

  # Editing in place (double-click): a task's title or objective, one of its steps or
  # checks, or a new step or check.
  def handle_event("plan_inline", %{"i" => i, "part" => part}, socket)
      when part in ["title", "objective", "new", "newcheck"] or
             binary_part(part, 0, 5) == "step-" or binary_part(part, 0, 6) == "check-" do
    {:noreply,
     assign(socket,
       plan_inline: {String.to_integer("#{i}"), part},
       plan_editing: nil,
       plan_asking: nil
     )}
  end

  def handle_event("plan_inline_cancel", _, socket),
    do: {:noreply, assign(socket, plan_inline: nil)}

  # Saved by Enter or by leaving the field; only the field that's open counts, so the
  # blur after an Enter doesn't save twice.
  def handle_event("plan_inline_save", %{"i" => i, "part" => part} = params, socket) do
    i = String.to_integer("#{i}")
    value = String.trim(params["value"] || "")

    with {^i, ^part} <- socket.assigns.plan_inline,
         %{} = task <- Enum.at(socket.assigns.plan_tasks, i),
         {:ok, changed} <- inline_change(task, part, value) do
      socket
      |> assign(plan_inline: nil)
      |> own_change(i, :edit, Specs.edit_plan_task(plan_spec(socket), i, changed))
    else
      _ -> {:noreply, assign(socket, plan_inline: nil)}
    end
  end

  def handle_event("plan_save", %{"i" => i, "task" => params}, socket) do
    socket
    |> assign(plan_editing: nil)
    |> own_change(
      String.to_integer(i),
      :edit,
      Specs.edit_plan_task(plan_spec(socket), String.to_integer(i), params)
    )
  end

  def handle_event("plan_remove", %{"i" => i}, socket) do
    socket
    |> assign(plan_editing: nil, plan_asking: nil)
    |> own_change(
      String.to_integer(i),
      :remove,
      Specs.remove_plan_task(plan_spec(socket), String.to_integer(i))
    )
  end

  # The gold marks on what the planner changed: cleared once they've been read.
  def handle_event("plan_changes_clear", _, socket),
    do: {:noreply, assign(socket, plan_before: nil)}

  def handle_event("plan_check_dismiss", _, socket),
    do: {:noreply, assign(socket, plan_check: nil)}

  def handle_event("plan_refine", %{"i" => i}, socket),
    do: {:noreply, ask_kiro(socket, String.to_integer(i), "")}

  # Scope: the planner checks the plan against what was asked and the code, and reports
  # above the plan; nothing changes (Factory.Specs.Planner has the prompt).
  def handle_event("plan_scope", _, socket) do
    run = socket.assigns.run && Runs.get_run(socket.assigns.run.id)
    planner = socket.assigns.planner

    if run && planner && run.status == "draft" do
      Factory.ChatPlanner.start(run, planner, action: :scope)
      {:noreply, assign(socket, plan_checking: true)}
    else
      {:noreply, put_flash(socket, :error, "This run has no planner to check its plan.")}
    end
  end

  # Refine (and "Refine with this"): the planner reworks the plan in place from the
  # code, acting on the scope check shown with it. The request goes to the planner
  # only, not into the chat; its reply does.
  def handle_event("plan_review", _, socket) do
    run = socket.assigns.run && Runs.get_run(socket.assigns.run.id)
    planner = socket.assigns.planner

    if run && planner && run.status == "draft" do
      findings = socket.assigns.plan_check && socket.assigns.plan_check.body
      Factory.ChatPlanner.start(run, planner, action: :refine, findings: findings)
      {:noreply, socket |> remember() |> assign(plan_checking: false)}
    else
      {:noreply, put_flash(socket, :error, "This run has no planner to review its plan.")}
    end
  end

  def handle_event("plan_ask_open", %{"i" => ""}, socket),
    do: {:noreply, assign(socket, plan_asking: nil)}

  def handle_event("plan_ask_open", %{"i" => i}, socket) do
    task = Enum.at(socket.assigns.plan_tasks, String.to_integer(i))
    {:noreply, assign(socket, plan_asking: task && task.title, plan_editing: nil)}
  end

  def handle_event("plan_ask", %{"i" => i, "instruction" => instruction}, socket) do
    {:noreply, socket |> assign(plan_asking: nil) |> ask_kiro(String.to_integer(i), instruction)}
  end

  # Kiro's version replaces the task.
  def handle_event("plan_use", %{"title" => title}, socket) do
    with {:ok, params} <- TaskImprove.suggestion(socket.assigns.plan_improve, title),
         i when is_integer(i) <-
           Enum.find_index(socket.assigns.plan_tasks, &(&1.title == title)) do
      socket
      |> update(:plan_improve, &Map.delete(&1, title))
      |> own_change(i, :edit, Specs.edit_plan_task(plan_spec(socket), i, params))
    else
      _ -> {:noreply, update(socket, :plan_improve, &Map.delete(&1, title))}
    end
  end

  def handle_event("plan_discard", %{"title" => title}, socket),
    do: {:noreply, update(socket, :plan_improve, &Map.delete(&1, title))}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def handle_info({:spec_updated, spec}, socket), do: {:noreply, put_plan_spec(socket, spec)}

  def handle_info({:task_activity, title, text}, socket),
    do: {:noreply, update(socket, :plan_improve, &TaskImprove.activity(&1, title, text))}

  def handle_info({:task_improved, title, result}, socket),
    do: {:noreply, update(socket, :plan_improve, &TaskImprove.result(&1, title, result))}

  # A task with one line changed in place, as edit_plan_task/3 takes it; :same when
  # nothing changed. An emptied step goes; an empty title or new step changes nothing.
  defp inline_change(task, part, value) do
    params = Specs.task_params(task)
    objective = params["objective"]
    steps = task.details
    checks = Map.get(task, :verify) || []

    case part do
      "title" when value in ["", task.title] -> :same
      "title" -> {:ok, %{params | "title" => value}}
      "objective" when value == objective -> :same
      "objective" -> {:ok, %{params | "objective" => value}}
      "new" when value == "" -> :same
      "new" -> {:ok, %{params | "details" => Enum.join(steps ++ [value], "\n")}}
      "newcheck" when value == "" -> :same
      "newcheck" -> {:ok, %{params | "verify" => Enum.join(checks ++ [value], "\n")}}
      "step-" <> j -> line_change(params, "details", steps, String.to_integer(j), value)
      "check-" <> j -> line_change(params, "verify", checks, String.to_integer(j), value)
    end
  end

  # One line of a task's steps or checks changed in place; emptied, it goes.
  defp line_change(params, field, lines, j, value) do
    cond do
      Enum.at(lines, j) == value -> :same
      value == "" -> {:ok, %{params | field => Enum.join(List.delete_at(lines, j), "\n")}}
      true -> {:ok, %{params | field => Enum.join(List.replace_at(lines, j, value), "\n")}}
    end
  end

  # The planner's latest reply, when it's a scope check: the report the plan shows.
  defp latest_check(nil, _planner), do: nil
  defp latest_check(_run, nil), do: nil

  defp latest_check(run, planner) do
    last =
      Repo.one(
        from m in Message,
          where:
            m.run_id == ^run.id and not is_nil(m.author) and
              fragment("?->>'agent_id'", m.meta) == ^to_string(planner.id),
          order_by: [desc: m.id],
          limit: 1
      )

    if last && last.meta["check"], do: last
  end

  defp plan_spec(socket),
    do: socket.assigns.plan_spec && Specs.get_spec(socket.assigns.plan_spec.id)

  # The plan's spec, and its tasks read from it once, for the panel and the events on it.
  defp put_plan_spec(socket, spec),
    do: assign(socket, plan_spec: spec, plan_tasks: tasks_of(spec))

  defp tasks_of(nil), do: []
  defp tasks_of(spec), do: spec.tasks |> Kernel.||("") |> Factory.Spec.blocks() |> elem(1)

  defp plan_changed(socket, {:ok, spec}),
    do: {:noreply, put_plan_spec(socket, spec)}

  defp plan_changed(socket, {:error, :locked}),
    do:
      {:noreply,
       put_flash(
         socket,
         :error,
         "The tasks are approved on the Spec page: reopen them there to change them."
       )}

  defp plan_changed(socket, {:error, :blank_title}),
    do: {:noreply, put_flash(socket, :error, "A task needs a title.")}

  defp plan_changed(socket, _error),
    do: {:noreply, put_flash(socket, :error, "That task changed meanwhile. Try again.")}

  # A change the person made to task `i`: saved, and taken into the snapshot, so it
  # isn't marked as the planner's.
  defp own_change(socket, i, how, {:ok, spec} = result) do
    after_tasks = tasks_of(spec)

    before =
      FactoryWeb.PlanDiff.accept(
        socket.assigns.plan_before,
        socket.assigns.plan_tasks,
        after_tasks,
        i,
        how
      )

    socket |> assign(plan_before: before) |> plan_changed(result)
  end

  defp own_change(socket, _i, _how, result), do: plan_changed(socket, result)

  defp ask_kiro(socket, i, instruction) do
    with %{} = spec <- plan_spec(socket),
         {:ok, title} <- Specs.improve_task(spec, i, instruction) do
      update(socket, :plan_improve, &TaskImprove.thinking(&1, title, instruction))
    else
      _ -> put_flash(socket, :error, "That task changed meanwhile. Try again.")
    end
  end
end
