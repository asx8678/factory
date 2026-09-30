defmodule Factory.Kiro.Permission do
  @moduledoc """
  Answers Kiro's `session/request_permission`: which kind of tool it asks for, and the
  option that says yes or no.

  Kiro 2.24 put the tool's kind (read, edit, execute…) on the request. Kiro 2.26
  leaves it out: the kind came earlier, on the `tool_call` update with the same
  `toolCallId`, and the request names Kiro's own tool (`_meta.kiro.toolId`, e.g.
  `fs_write`). `kind/2` looks in that order, so a request is judged by what the tool
  does whichever Kiro sent it.
  """

  # Kiro's own tools, by what they do, for requests that carry neither kind nor call id.
  @tool_kinds %{
    "fs_read" => "read",
    "fs_write" => "edit",
    "fs_append" => "edit",
    "str_replace" => "edit",
    "execute_bash" => "execute",
    "execute_cmd" => "execute",
    "shell" => "execute",
    "grep" => "search",
    "glob" => "search",
    "code" => "search",
    "web_fetch" => "fetch",
    "web_search" => "fetch"
  }

  @doc """
  The kind of tool a permission request is for, or nil when it can't be told.
  `known` maps tool call ids to the kinds their `tool_call` updates gave.
  """
  def kind(params, known \\ %{}) do
    call = params["toolCall"] || %{}

    call["kind"] || Map.get(known, call["toolCallId"]) ||
      Map.get(@tool_kinds, get_in(params, ["_meta", "kiro", "toolId"]))
  end

  # ACP permits cancellation when none of the offered options matches the decision.
  def outcome(options, decision) do
    case Enum.find(options, &String.starts_with?(&1["kind"] || "", decision)) do
      %{"optionId" => id} when is_binary(id) -> %{outcome: "selected", optionId: id}
      _ -> %{outcome: "cancelled"}
    end
  end
end
