defmodule Factory.PromptText do
  @moduledoc """
  Text shared by the prompts Factory gives Kiro and the replies it reads back: files
  wrapped for a prompt, and the JSON object a reply carries, found the same way
  wherever one is read (a plan, a review, a verification).
  """

  @doc "Files (`[{name, text}]`) as a prompt shows them: `<file name=\"…\">…</file>` each."
  def files(files) do
    Enum.map_join(files, "\n\n", fn {name, text} ->
      ~s(<file name="#{name}">\n#{text}\n</file>)
    end)
  end

  # How many `{` that never close are looked past. Each is read to the end of the
  # reply, so a reply of nothing but `{` would otherwise take seconds.
  @unclosed 64

  @doc """
  The JSON object in a reply: `{:ok, map}` or `:error`. A ```json block comes first;
  else the first balanced `{…}` that reads as an object, so braces in the prose around
  it (or a second object after it) don't spoil it.
  """
  def json_object(reply) when is_binary(reply) do
    fenced = for [_, body] <- Regex.scan(~r/```(?:json)?[ \t]*\R(.*?)```/si, reply), do: body
    Enum.find_value(fenced ++ [reply], :error, &first_object(&1, @unclosed))
  end

  def json_object(_reply), do: :error

  # The first `{…}` from the left that decodes to a map. One that doesn't is skipped
  # whole, so an object nested in it isn't taken for the reply.
  defp first_object(_text, 0), do: nil

  defp first_object(text, tries) do
    case :binary.match(text, "{") do
      :nomatch ->
        nil

      {start, _} ->
        rest = binary_part(text, start, byte_size(text) - start)

        case balanced(rest, 0, 0, false, false) do
          nil ->
            first_object(binary_part(rest, 1, byte_size(rest) - 1), tries - 1)

          len ->
            candidate = binary_part(rest, 0, len)

            case JSON.decode(candidate) do
              {:ok, %{} = data} -> {:ok, data}
              _ -> first_object(binary_part(rest, len, byte_size(rest) - len), tries)
            end
        end
    end
  end

  # The length of the `{…}` that opens `text`, counting braces outside strings; nil
  # when it never closes.
  defp balanced(<<>>, _at, _depth, _in_string, _escaped), do: nil

  defp balanced(<<_, rest::binary>>, at, depth, true, true),
    do: balanced(rest, at + 1, depth, true, false)

  defp balanced(<<?\\, rest::binary>>, at, depth, true, false),
    do: balanced(rest, at + 1, depth, true, true)

  defp balanced(<<?", rest::binary>>, at, depth, in_string, false),
    do: balanced(rest, at + 1, depth, not in_string, false)

  defp balanced(<<_, rest::binary>>, at, depth, true, false),
    do: balanced(rest, at + 1, depth, true, false)

  defp balanced(<<?{, rest::binary>>, at, depth, false, _),
    do: balanced(rest, at + 1, depth + 1, false, false)

  defp balanced(<<?}, _rest::binary>>, at, 1, false, _), do: at + 1

  defp balanced(<<?}, rest::binary>>, at, depth, false, _),
    do: balanced(rest, at + 1, depth - 1, false, false)

  defp balanced(<<_, rest::binary>>, at, depth, false, _),
    do: balanced(rest, at + 1, depth, false, false)
end
