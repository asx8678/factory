defmodule Factory.Text do
  @moduledoc """
  Small text helpers shared by the modules that read Kiro's replies and write specs:
  trimming what may not be a string, splitting lists into lines, finding the JSON
  object in a reply and the first heading in markdown.
  """

  @doc "The string trimmed, or \"\" for anything that isn't one."
  def text(s) when is_binary(s), do: String.trim(s)
  def text(_), do: ""

  @doc "The string trimmed, or nil when it's empty or not a string (`nil` as \"no value\")."
  def presence(v) do
    case v |> to_string() |> String.trim() do
      "" -> nil
      s -> s
    end
  end

  @doc "`text` unless it's blank, else `default`."
  def or_default(text, default), do: if(String.trim(text || "") == "", do: default, else: text)

  @doc """
  The non-empty lines in a list of strings (or numbers), each trimmed. An item with
  line breaks in it is split, so a list given as one text block reads the same.
  """
  def lines(list) do
    for item <- List.wrap(list),
        is_binary(item) or is_number(item),
        line <- item |> to_string() |> String.split(~r/\R/u),
        line = String.trim(line),
        line != "",
        do: line
  end

  @doc "The outermost `{...}` in a reply, which may be wrapped in a ```json fence or prose; nil without one."
  def json_object(reply) when is_binary(reply) do
    case Regex.run(~r/\{.*\}/s, reply) do
      [json] -> json
      _ -> nil
    end
  end

  def json_object(_reply), do: nil

  @doc "The JSON object in a reply (`json_object/1`), decoded: `{:ok, map}` or `:error`."
  def decode_json(reply) do
    with json when is_binary(json) <- json_object(reply),
         {:ok, data} when is_map(data) <- JSON.decode(json) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  @doc "The first `# Heading` in the markdown, trimmed and at most 80 characters, or nil."
  def first_heading(markdown) when is_binary(markdown) do
    case Regex.run(~r/^#\s+(.+)$/m, markdown) do
      [_, heading] -> heading |> String.trim() |> String.slice(0, 80)
      _ -> nil
    end
  end

  def first_heading(_markdown), do: nil
end
