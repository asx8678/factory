defmodule Factory.Runs.Titles do
  @moduledoc """
  Names chats and factory runs with a short summary written by Kiro, in place of
  "New run" or the first line of what the person wrote.

  A chat is renamed after each of its first few messages, as there is more to go on;
  a factory run once its plan is written. A title set with /rename is kept
  (`settings["title"] == "manual"`).
  """
  alias Factory.{Kiro, Runs}
  alias Factory.Runs.Run

  # A chat's title settles after this many messages from the person.
  @chat_messages 3

  @doc "Retitles the run in the background, unless titles are switched off (tests)."
  def start(%Run{} = run) do
    if Application.get_env(:factory, :auto_titles, true) and auto?(run) do
      Task.Supervisor.start_child(Factory.TaskSupervisor, fn -> retitle(run.id) end)
    end

    :ok
  end

  @doc "Whether a chat's latest message should retitle it."
  def chat_message?(%Run{kind: nil} = run),
    do: auto?(run) and Runs.count_messages(run.id, "user") <= @chat_messages

  def chat_message?(_run), do: false

  def auto?(%Run{settings: settings}), do: (settings || %{})["title"] != "manual"

  @doc "Asks Kiro for a title and saves it: `{:ok, run}` or `{:error, reason}`."
  def retitle(run_id) do
    with %Run{} = run <- Runs.get_run(run_id),
         true <- auto?(run) || {:error, :manual},
         about when about != "" <- about(run),
         {:ok, reply} <-
           Kiro.ask(prompt(about),
             model: "claude-haiku-4.5",
             usage: %{source: "title", run_id: run.id}
           ),
         title when title != "" <- clean(reply),
         # The person may have renamed it meanwhile.
         %Run{} = run <- Runs.get_run(run_id),
         true <- auto?(run) || {:error, :manual} do
      Runs.update_run(run, %{title: title})
    else
      {:error, _} = error -> error
      _ -> {:error, :nothing_to_go_on}
    end
  end

  defp about(%Run{kind: nil} = run) do
    run.id
    |> Runs.list_messages()
    |> Enum.filter(&(&1.role == "user" and not String.starts_with?(&1.body, "/")))
    |> Enum.take(@chat_messages)
    |> Enum.map_join("\n\n", & &1.body)
    |> String.slice(0, 3000)
  end

  defp about(%Run{} = run), do: String.slice(run.description || "", 0, 3000)

  defp prompt(about) do
    """
    <run-title>
    Write a title of 2 to 6 words that sums up what this is about, like a good email
    subject: specific, plain words, sentence case. If it's only small talk, say what
    kind (e.g. "Quick hello"). Reply with the title only: no quotes, no full stop.

    #{about}
    </run-title>
    """
  end

  @doc false
  def clean(reply) do
    reply
    |> String.split(~r/\R/u, trim: true)
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.replace(~r/^\s*(title\s*:\s*)?[#*"'“”‘’`]+|[#*"'“”‘’`.]+\s*$/iu, "")
    |> String.trim()
    |> String.slice(0, 60)
  end
end
