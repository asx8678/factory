defmodule FactoryWeb.MCP do
  @moduledoc """
  Factory's MCP server over HTTP, for the Kiro sessions Factory starts: they call
  Factory's tools here (`Factory.PlanTools`). Each JSON-RPC request is answered with
  one JSON response; there's no event stream, so `GET` is refused as MCP allows.

  The token says whose tools a session gets: a run step's (`Factory.RunTools`) or,
  otherwise, the planner's (`Factory.PlanTools`). Calling a tool needs the
  `Authorization: Bearer` token the session was given; without a good one the call
  fails as a tool error, not with HTTP 401, which Kiro would take as a cue to sign in
  with OAuth.
  """
  @behaviour Plug
  import Plug.Conn
  alias Factory.{PlanTools, RunTools}

  # Answered with the version the client asks for, else this one.
  @protocol "2025-06-18"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "method" => method, "id" => id} = msg ->
        case handle(conn, method, msg["params"] || %{}) do
          {:ok, result} -> reply(conn, %{jsonrpc: "2.0", id: id, result: result})
          {:error, code, text} -> reply(conn, error(id, code, text))
        end

      # A notification: nothing to answer.
      %{"jsonrpc" => "2.0", "method" => _} ->
        send_resp(conn, 202, "")

      _ ->
        reply(conn, error(nil, -32600, "Send one JSON-RPC 2.0 request as JSON."))
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  defp handle(_conn, "initialize", params) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || @protocol,
       capabilities: %{tools: %{}},
       serverInfo: %{name: PlanTools.server_name(), version: "1.0.0"},
       instructions: "Factory's tools: a chat's plan and its tasks, or a run's progress."
     }}
  end

  defp handle(_conn, "ping", _params), do: {:ok, %{}}

  defp handle(conn, "tools/list", _params), do: {:ok, %{tools: tools(token(conn)).tools()}}

  defp handle(conn, "tools/call", %{"name" => name} = params) when is_binary(name) do
    token = token(conn)

    {text, error?} =
      case tools(token).call(token, name, params["arguments"] || %{}) do
        {:ok, text} -> {text, false}
        {:error, text} -> {text, true}
      end

    {:ok, %{content: [%{type: "text", text: text}], isError: error?}}
  end

  defp handle(_conn, "tools/call", _params), do: {:error, -32602, "Name the tool to call."}

  defp handle(_conn, method, _params), do: {:error, -32601, "#{method} isn't supported."}

  defp tools(token), do: if(RunTools.token?(token), do: RunTools, else: PlanTools)

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp error(id, code, text), do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: text}}

  defp reply(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end
end
