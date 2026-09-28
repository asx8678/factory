# Start the graph with a single agent. Run with: mix run priv/repo/seeds.exs
alias Factory.{Agents, Repo}

if Repo.aggregate(Agents.Agent, :count) == 0 do
  {:ok, _} =
    Agents.create_agent(%{
      name: "Orchestrator",
      role: "Plans work and hands it to other agents",
      model: "claude-opus-5-5"
    })
end

# Example base specs (coding standards, testing, security…) to include in runs.
Factory.Specs.Examples.install()
