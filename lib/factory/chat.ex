defmodule Factory.Chat do
  @moduledoc """
  Handles what a person types into a run's chat. Slash commands are carried
  out here in Elixir; plain-language messages get a pointer to /help until a
  model is connected.
  """
  alias Factory.{Agents, Runs, Spec}
  alias Factory.Runs.Run

  @commands [
    {"/help", "Show the commands"},
    {"/run", "Start the run with the attached spec"},
    {"/status", "Show progress"},
    {"/tasks", "List the tasks"},
    {"/pause", "Pause the run"},
    {"/resume", "Resume a paused run"},
    {"/cancel", "Cancel the run"},
    {"/rename", "Rename this chat, e.g. /rename Login page"},
    {"/workflow", "Show the agents the run will use"}
  ]

  def commands, do: @commands

  @doc """
  Posts the person's message, applies any attached spec files
  (`[{name, content}]`), then runs the command and posts the factory's reply.
  """
  def handle(%Run{} = run, text, files \\ []) do
    text = String.trim(text)
    Runs.post(run, "user", text, attachments: Enum.map(files, &elem(&1, 0)))

    run = if files != [], do: attach(run, files), else: run
    if text != "", do: command(run, text)
    :ok
  end

  @doc "Runs a button action shown under a factory message."
  def action(%Run{} = run, "start"), do: command(run, "/run")

  defp attach(run, files) do
    case Spec.tasks_from_files(files) do
      {nil, []} ->
        {:ok, run} = Runs.attach_spec(run, files, [])

        say(run, """
        I stored #{names(files)} but found no tasks in it. Tasks are top-level lines like \
        `- [ ] 1. Add login page` or `1. Add login page`. Attach a tasks.md to continue.\
        """)

        run

      {from, tasks} ->
        {:ok, run} = Runs.attach_spec(run, files, tasks)

        list =
          tasks
          |> Enum.take(12)
          |> Enum.map_join("\n", &"#{if &1.ref, do: &1.ref <> ".", else: "•"} #{&1.title}")

        more = if length(tasks) > 12, do: "\n…and #{length(tasks) - 12} more", else: ""

        say(run, "Found #{length(tasks)} #{plural(tasks, "task")} in #{from}:\n#{list}#{more}",
          actions: ["start"]
        )

        run
    end
  end

  defp command(run, "/" <> rest) do
    [name | args] = String.split(rest, ~r/\s+/, parts: 2)
    run_command(run, String.downcase(name), List.first(args, ""))
  end

  defp command(run, _text) do
    say(
      run,
      "I only understand slash commands for now. Type /help to see them, or attach a spec to start."
    )
  end

  defp run_command(run, "help", _) do
    say(run, "Commands:\n" <> Enum.map_join(@commands, "\n", fn {c, d} -> "#{c}  #{d}" end))
  end

  defp run_command(%Run{tasks: []} = run, "run", _) do
    say(
      run,
      "There's nothing to run yet. Drop a tasks.md into the chat, or click the paperclip to attach one."
    )
  end

  defp run_command(%Run{status: "draft"} = run, "run", _) do
    {:ok, run} = Runs.update_run(run, %{status: "queued"})

    say(run, """
    Queued #{length(run.tasks)} #{plural(run.tasks, "task")}. Nothing executes tasks yet: the engine \
    that runs agents comes in the next build phases, so they stay pending for now.\
    """)
  end

  defp run_command(run, "run", _),
    do: say(run, "This run is already #{run.status}. Use /status to see progress.")

  defp run_command(run, "status", _) do
    counts =
      run.tasks
      |> Enum.frequencies_by(& &1.status)
      |> Enum.map_join(", ", fn {s, n} -> "#{n} #{s}" end)

    tasks = if run.tasks == [], do: "no tasks yet", else: counts

    spec =
      if run.spec_files == [],
        do: "no spec attached",
        else: "spec: " <> Enum.join(run.spec_files, ", ")

    say(run, "Run is #{run.status}. #{String.capitalize(tasks)}. #{String.capitalize(spec)}.")
  end

  defp run_command(%Run{tasks: []} = run, "tasks", _),
    do: say(run, "No tasks yet. Attach a tasks.md first.")

  defp run_command(run, "tasks", _) do
    say(
      run,
      Enum.map_join(run.tasks, "\n", &"#{&1.ref || &1.position}. #{&1.title} (#{&1.status})")
    )
  end

  defp run_command(%Run{status: s} = run, "pause", _) when s in ["queued", "running"] do
    {:ok, run} = Runs.update_run(run, %{status: "paused"})
    say(run, "Paused. Type /resume to continue.")
  end

  defp run_command(run, "pause", _),
    do: say(run, "Only a queued or running run can be paused. This one is #{run.status}.")

  defp run_command(%Run{status: "paused"} = run, "resume", _) do
    {:ok, run} = Runs.update_run(run, %{status: "queued"})
    say(run, "Resumed.")
  end

  defp run_command(run, "resume", _),
    do: say(run, "Only a paused run can be resumed. This one is #{run.status}.")

  defp run_command(%Run{status: s} = run, "cancel", _) when s in ["done", "cancelled"] do
    say(run, "This run is already #{s}.")
  end

  defp run_command(run, "cancel", _) do
    {:ok, run} = Runs.update_run(run, %{status: "cancelled"})
    say(run, "Cancelled.")
  end

  defp run_command(run, "rename", ""),
    do: say(run, "Give the new name after the command, e.g. /rename Login page")

  defp run_command(run, "rename", title) do
    case Runs.update_run(run, %{title: title}) do
      {:ok, run} -> say(run, "Renamed to “#{run.title}”.")
      {:error, _} -> say(run, "Names can be up to 80 characters.")
    end
  end

  defp run_command(run, "workflow", _) do
    case Agents.list_agents() do
      [] ->
        say(run, "The workflow has no agents yet. Add them under Workflows.")

      agents ->
        say(
          run,
          "Agents in the workflow:\n" <>
            Enum.map_join(agents, "\n", &"• #{&1.name} (#{&1.model})")
        )
    end
  end

  defp run_command(run, name, _),
    do: say(run, "There's no /#{name} command. Type /help to see them.")

  defp say(run, body, opts \\ []), do: Runs.post(run, "factory", body, opts)

  defp names(files), do: files |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
  defp plural([_], word), do: word
  defp plural(_, word), do: word <> "s"
end
