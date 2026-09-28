defmodule FactoryWeb.MarkdownTest do
  use ExUnit.Case, async: true
  alias FactoryWeb.Markdown

  defp html(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  test "renders Markdown and keeps single line breaks" do
    out = html("## Plan\n**bold** line one\nline two\n\n| a | b |\n|---|---|\n| 1 | 2 |")
    assert out =~ "<h2>Plan</h2>"
    assert out =~ "<strong>bold</strong> line one<br />"
    assert out =~ "<table>"
  end

  test "drops raw HTML so messages can't inject markup" do
    out = html(~s{hi <script>alert(1)</script> <img src=x onerror="alert(2)">})
    refute out =~ "<script"
    refute out =~ "<img"
    refute out =~ "onerror"
  end
end
