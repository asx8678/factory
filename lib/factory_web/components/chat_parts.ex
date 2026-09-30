defmodule FactoryWeb.ChatParts do
  @moduledoc """
  What the chat page's pieces share (`FactoryWeb.ChatLive`): the message box's
  placeholder, who a message goes to, whether the run can still be set up, and the
  chat's paths. The pieces themselves are `FactoryWeb.ChatHeader` (the controls above
  the chat), `FactoryWeb.ChatGreeting` (a new chat), `FactoryWeb.ChatMessages` (the
  conversation), `FactoryWeb.ChatQuestions` (an agent's questions to answer) and
  `FactoryWeb.ChatComposer` (the message box). Events from them go to the chat LiveView.
  """
  use FactoryWeb, :html

  # Before the run starts, a message to the agent that plans it (or to Factory, which
  # passes it on) is planned into tasks: the box says so.
  def placeholder(agent, run, planner \\ nil, job \\ nil)

  def placeholder(nil, run, planner, job) do
    cond do
      planner && settable?(run) && job == "review" ->
        "Paste a pull request's link or name a branch for #{planner.name}, or type / for commands"

      planner && settable?(run) ->
        "Describe a change for #{planner.name} to plan, or type / for commands"

      true ->
        "Message the factory, or type / for commands"
    end
  end

  def placeholder(agent, run, planner, job) do
    cond do
      planner && planner.id == agent.id && settable?(run) && job == "review" ->
        "Paste a pull request's link, or name the branch to review…"

      planner && planner.id == agent.id && settable?(run) ->
        "Describe a change, e.g. add an export button to the invoices page…"

      true ->
        "Message #{agent.name}…"
    end
  end

  # The agent a message goes to, or nil for the factory.
  def recipient(focus, _to) when focus != nil, do: focus
  def recipient(_focus, :factory), do: nil
  def recipient(_focus, to), do: to

  # The workflow and folder can change until the run starts.
  def settable?(nil), do: true
  def settable?(run), do: run.status == "draft"

  def chat_path(nil, nil), do: ~p"/chat"
  def chat_path(nil, agent), do: ~p"/chat?#{[agent: agent.id]}"
  def chat_path(run, nil), do: ~p"/chat/#{run.id}"
  def chat_path(run, agent), do: ~p"/chat/#{run.id}?#{[agent: agent.id]}"
end
