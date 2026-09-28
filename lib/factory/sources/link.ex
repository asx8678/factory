defmodule Factory.Sources.Link do
  @moduledoc "A data source attached to an agent: the agent gets the source in its prompt."
  use Ecto.Schema

  schema "source_links" do
    belongs_to :source, Factory.Sources.Source
    belongs_to :agent, Factory.Agents.Agent
    timestamps(type: :utc_datetime)
  end
end
