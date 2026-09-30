defmodule FactoryWeb.TaskImprove do
  @moduledoc """
  Improving one task with Kiro (`Factory.Specs.improve_task/3`), on the chat's plan
  (`FactoryWeb.ChatLive`) and on the Spec page (`FactoryWeb.SpecLive`). Each page keeps
  Kiro's work in a map by the task's title when it was asked, so moving tasks around
  meanwhile doesn't lose the answer. An entry is
  `%{status:, instruction:, suggestion:, error:, activity:}`, its status `:thinking`,
  `:done` or `:error` (the Spec page adds `:asking`, while you say what to do better).
  """

  @doc "Kiro is at work on the task, asked to do `instruction` (\"\" to improve it from the code)."
  def thinking(improve, title, instruction) do
    entry = %{
      status: :thinking,
      instruction: instruction,
      suggestion: nil,
      error: nil,
      activity: nil
    }

    Map.put(improve, title, entry)
  end

  @doc "What Kiro is reading, from `{:task_activity, title, text}`."
  def activity(improve, title, text) do
    case improve do
      %{^title => entry} -> %{improve | title => %{entry | activity: text}}
      _ -> improve
    end
  end

  @doc "Kiro's answer, from `{:task_improved, title, result}`."
  def result(improve, title, result) do
    case {improve[title], result} do
      {nil, _} -> improve
      {e, {:ok, s}} -> %{improve | title => %{e | status: :done, suggestion: s}}
      {e, {:error, why}} -> %{improve | title => %{e | status: :error, error: why}}
    end
  end

  @doc "Kiro's version of the task, as the params that save it, once it's there."
  def suggestion(improve, title) do
    case improve[title] do
      %{status: :done, suggestion: s} -> {:ok, Factory.Specs.task_params(s)}
      _ -> :none
    end
  end
end
