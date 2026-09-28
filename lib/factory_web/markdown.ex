defmodule FactoryWeb.Markdown do
  @moduledoc """
  Renders chat messages (Kiro replies are Markdown) to HTML. Raw HTML in the
  text is dropped by MDEx, so a message can't inject markup into the page.
  Single line breaks are kept, as people expect in a chat.
  """

  @options [
    # No strikethrough: a single ~ would strike through Elixir versions like "~> 1.2".
    extension: [table: true, autolink: true, tasklist: true],
    render: [hardbreaks: true]
  ]

  def render(nil), do: ""
  def render(text), do: text |> MDEx.to_html!(@options) |> Phoenix.HTML.raw()
end
