defmodule Factory.Runs do
  @moduledoc """
  Runs and their traces. Nothing records runs yet, so everything is empty
  until the harness starts executing agents.
  """

  def list_runs, do: []
  def list_runs_for(agent_id), do: Enum.filter(list_runs(), &(&1.agent_id == agent_id))
  def get_run(id), do: Enum.find(list_runs(), &(&1.id == id))
  def trace(_run_id), do: []
end
