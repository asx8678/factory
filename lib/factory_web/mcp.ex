defmodule FactoryWeb.MCP do
  @moduledoc """
  Factory's MCP server over HTTP, for the Kiro sessions Factory starts: they call
  Factory's tools here (`Factory.PlanTools`). Each JSON-RPC request is answered with
  one JSON response, except a tool that asks the person something now: its answer is
  an event stream carrying `elicitation/create`, and the client posts the person's
  answer back (see `elicit/4`). `GET` is refused as MCP allows.

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
          {:elicit, request, then} -> elicit(conn, id, request, then)
          {:error, code, text} -> reply(conn, error(id, code, text))
        end

      # The client's answer to our elicitation/create: to the tool call waiting for it,
      # when it comes with the token that call was made with (so nobody else who
      # learns the id can answer for the person).
      %{"jsonrpc" => "2.0", "id" => id} = msg when is_binary(id) ->
        case Registry.lookup(Factory.Kiro.Registry, {__MODULE__, id}) do
          [{pid, token}] when is_binary(token) ->
            if same_token?(token(conn), token),
              do: send(pid, {:elicitation_answer, id, msg["result"] || %{"action" => "cancel"}})

          _ ->
            :ok
        end

        send_resp(conn, 202, "")

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

  defp handle(conn, "tools/list", _params) do
    token = token(conn)

    tools =
      if RunTools.token?(token), do: RunTools.tools(token), else: PlanTools.tools(token)

    {:ok, %{tools: tools}}
  end

  defp handle(conn, "tools/call", %{"name" => name} = params) when is_binary(name) do
    token = token(conn)

    case tools(token).call(token, name, params["arguments"] || %{}) do
      {:elicit, request, then} ->
        # Only a client that reads a stream can be asked; others get the fallback.
        if accepts_stream?(conn),
          do: {:elicit, request, then},
          else: {:ok, tool_result(then.(%{"action" => "cancel"}))}

      result ->
        {:ok, tool_result(result)}
    end
  end

  defp handle(_conn, "tools/call", _params), do: {:error, -32602, "Name the tool to call."}

  defp handle(_conn, method, _params), do: {:error, -32601, "#{method} isn't supported."}

  defp tools(token), do: if(RunTools.token?(token), do: RunTools, else: PlanTools)

  defp tool_result({:ok, text}), do: %{content: [%{type: "text", text: text}], isError: false}
  defp tool_result({:error, text}), do: %{content: [%{type: "text", text: text}], isError: true}

  defp accepts_stream?(conn),
    do: Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "text/event-stream"))

  # A tool that asks the person something now (MCP elicitation): the answer to the
  # tools/call becomes an event stream carrying elicitation/create; the client (Kiro)
  # asks the person through its own client, Factory's chat, and posts the answer here,
  # which the tool then uses in its result, sent on the same stream.
  @elicit_wait :timer.minutes(15)

  defp elicit(conn, call_id, request, then) do
    id = "factory-elicit-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    # The answer must come with the same token as the call (`call/2`).
    {:ok, _} = Registry.register(Factory.Kiro.Registry, {__MODULE__, id}, token(conn) || "")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    ask = %{
      jsonrpc: "2.0",
      id: id,
      method: "elicitation/create",
      params: %{message: request.message, requestedSchema: request.schema}
    }

    answer =
      case chunk(conn, event(ask)) do
        {:ok, _} ->
          receive do
            {:elicitation_answer, ^id, answer} -> answer
          after
            @elicit_wait -> %{"action" => "cancel"}
          end

        {:error, _} ->
          %{"action" => "cancel"}
      end

    Registry.unregister(Factory.Kiro.Registry, {__MODULE__, id})
    result = %{jsonrpc: "2.0", id: call_id, result: tool_result(then.(answer))}
    _ = chunk(conn, event(result))
    conn
  end

  defp event(message), do: "event: message\ndata: " <> JSON.encode!(message) <> "\n\n"

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  # Whether the answer's token is the call's. A call made without a token (a planner's
  # tools/list needs none, but every tool that asks a question checks its token first)
  # takes no answer at all.
  defp same_token?(given, expected) when is_binary(given) and expected != "",
    do: Plug.Crypto.secure_compare(given, expected)

  defp same_token?(_given, _expected), do: false

  defp error(id, code, text), do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: text}}

  defp reply(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end
end
