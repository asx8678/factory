defmodule FactoryWeb.AgentKinds do
  @moduledoc """
  Label, icon and prompt template for each agent kind, for the templates. The lists
  live in `Factory.Agents.Kinds`, so the web layer and `Factory.Workflows` read the same ones.
  """
  alias Factory.Agents.Kinds

  defdelegate all, to: Kinds
  defdelegate icon(kind), to: Kinds
  defdelegate template(kind, name), to: Kinds
  defdelegate label(kind), to: Kinds
  defdelegate blurb(kind), to: Kinds
end
