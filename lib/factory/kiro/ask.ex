defmodule Factory.Kiro.Ask do
  @moduledoc """
  One question to Kiro in a throwaway session: start `kiro-cli acp --agent-engine v3`,
  open a session, set the model, send the text, collect the reply, stop the process.

  It blocks the calling process until Kiro answers, so call it from a task. Kiro
  may not write files or run commands: permission requests are denied unless the
  tool's kind is in the `:allow` option (e.g. `["read", "search"]` to let it look
  around a project).
  """
  alias Factory.Kiro
  alias Factory.Kiro.RPC

  @doc """
  Returns `{:ok, reply_text}` or `{:error, reason}`. Options:

    * `:model` - default "auto"
    * `:workdir` - the folder Kiro works in, default the Kiro workspace
    * `:allow` - tool kinds Kiro may use when it asks (ACP kinds: read, search, edit, execute, …),
      and "look" for commands that only look (`Factory.Kiro.Permission.looking?/2`)
    * `:on_tool` - called with each ACP `tool_call` update as Kiro starts using a tool
    * `:mcp_servers` - MCP servers the session gets, as ACP `session/new` takes them; Kiro
      may call the tools of these without asking (its MCP permission requests carry no kind)
    * `:reply` - `:all` (default) for everything Kiro wrote, `:last` for only what it wrote
      after its last tool call (its closing message, without the narration in between),
      which may be empty, or `:first` for only what it wrote before its first tool call
    * `:usage` - what the call is for, recorded with its cost by `Factory.Usage.record/1`:
      `%{source: "review", spec_id: 1}` and so on. Without it the source is "other".
  """
  def run(text, opts \\ []) do
    workdir = opts[:workdir] || Kiro.config(:workspace)
    if workdir == Kiro.config(:workspace), do: File.mkdir_p!(workdir)
    File.mkdir_p!(Kiro.config(:log_dir))

    cond do
      not File.dir?(workdir) ->
        {:error, "The folder #{workdir} doesn't exist."}

      not File.exists?(Kiro.config(:cli)) ->
        {:error, "kiro-cli wasn't found at #{Kiro.config(:cli)}."}

      true ->
        converse(text, workdir, opts)
    end
  end

  defp converse(text, workdir, opts) do
    port = Kiro.open_port(workdir, "ask.log")
    deadline = System.monotonic_time(:millisecond) + Kiro.config(:prompt_timeout)

    conn = %{
      port: port,
      workdir: workdir,
      deadline: deadline,
      allow: opts[:allow] || [],
      mcp: Enum.map(opts[:mcp_servers] || [], & &1.name),
      on_tool: opts[:on_tool] || fn _ -> :ok end
    }

    started = System.monotonic_time(:millisecond)
    model = opts[:model] || "auto"

    result =
      try do
        with {:ok, _, _} <-
               call(conn, 1, "initialize", %{protocolVersion: 1, clientCapabilities: %{}}),
             {:ok, session, _} <-
               call(conn, 2, "session/new", %{cwd: workdir, mcpServers: opts[:mcp_servers] || []}),
             sid = session["sessionId"],
             :ok <- set_model(conn, sid, session, model) do
          call(conn, 4, "session/prompt", %{sessionId: sid, prompt: [%{type: "text", text: text}]})
        end
      after
        RPC.close_port(port)
      end

    {reply, acc} =
      case result do
        {:ok, _, acc} ->
          cond do
            # A turn that ends on a tool call has nothing after it; the caller decides.
            opts[:reply] == :last -> {{:ok, acc.last}, acc}
            opts[:reply] == :first and String.trim(acc.first) != "" -> {{:ok, acc.first}, acc}
            String.trim(acc.text) == "" -> {{:error, "Kiro ended the turn without a reply."}, acc}
            true -> {{:ok, acc.text}, acc}
          end

        {:error, reason, acc} ->
          {{:error, reason}, acc}
      end

    # Only a call that got as far as the prompt costs anything.
    if acc.prompted do
      Factory.Usage.record(
        Map.merge(Map.new(opts[:usage] || %{}), %{
          model: model,
          credits: acc.credits,
          input_tokens: Factory.Usage.estimate_tokens(text),
          output_tokens: Factory.Usage.estimate_tokens(acc.text),
          ms: System.monotonic_time(:millisecond) - started,
          ok: match?({:ok, _}, reply)
        })
      )
    end

    reply
  end

  defp set_model(conn, sid, session, model) do
    current =
      Enum.find_value(
        session["configOptions"] || [],
        &(&1["id"] == "model" && &1["currentValue"])
      )

    if current == model do
      :ok
    else
      params = %{sessionId: sid, configId: "model", value: model}

      case call(conn, 3, "session/set_config_option", params) do
        {:ok, _, _} -> :ok
        error -> error
      end
    end
  end

  # Sends a request and waits for its response: `{:ok, result, acc}` or
  # `{:error, reason, acc}`, where acc has what Kiro said while answering (a prompt's
  # reply streams in before its response) and the credits it reported.
  defp call(conn, id, method, params) do
    RPC.request(conn.port, id, method, params)

    acc = %{
      text: "",
      last: "",
      first: "",
      tooled: false,
      credits: 0.0,
      prompted: method == "session/prompt",
      kinds: %{},
      commands: %{}
    }

    await(conn, id, "", acc)
  end

  defp await(%{port: port} = conn, id, buffer, acc) do
    timeout = max(conn.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, part}}} ->
        await(conn, id, buffer <> part, acc)

      {^port, {:data, {:eol, part}}} ->
        case RPC.decode(buffer <> part) do
          {:ok, msg} ->
            case handle(conn, msg, id, acc) do
              {:cont, acc} -> await(conn, id, "", acc)
              done -> done
            end

          :skip ->
            await(conn, id, "", acc)
        end

      {^port, {:exit_status, code}} ->
        {:error,
         "Kiro stopped unexpectedly (exit code #{code}). Details are in tmp/kiro-logs/ask.log.",
         acc}
    after
      timeout ->
        {:error,
         "Kiro didn't answer within #{div(Kiro.config(:prompt_timeout), 60_000)} minutes.", acc}
    end
  end

  defp handle(_conn, %{"id" => id, "error" => error}, id, acc),
    do: {:error, "Kiro returned an error: #{RPC.error_message(error)}", acc}

  defp handle(_conn, %{"id" => id, "result" => result}, id, acc), do: {:ok, result, acc}

  defp handle(
         conn,
         %{"id" => rid, "method" => "session/request_permission", "params" => p},
         _id,
         acc
       ) do
    options = p["options"] || []
    # Kiro names the MCP server a tool comes from; its request has no kind then.
    server = get_in(p, ["_meta", "kiro", "mcpTool", "identity", "serverName"])

    kind = Kiro.Permission.kind(p, acc.kinds)

    looking? =
      kind == "execute" and "look" in conn.allow and
        Kiro.Permission.looking?(Kiro.Permission.command(p, acc.commands), conn.workdir)

    wanted =
      if kind in conn.allow or looking? or (server && server in conn.mcp),
        do: "allow",
        else: "reject"

    RPC.reply(conn.port, rid, %{outcome: Kiro.Permission.outcome(options, wanted)})
    {:cont, acc}
  end

  # A one-off question has nobody to ask mid-turn: a tool's question is cancelled, and
  # the tool carries on without it.
  defp handle(conn, %{"id" => rid, "method" => "_kiro/mcp/elicitation"}, _id, acc) do
    RPC.reply(conn.port, rid, %{action: "cancel"})
    {:cont, acc}
  end

  defp handle(conn, %{"id" => rid, "method" => method}, _id, acc) do
    RPC.reply_error(conn.port, rid, -32601, "#{method} is not supported by Factory")
    {:cont, acc}
  end

  defp handle(
         _conn,
         %{
           "method" => "session/update",
           "params" => %{
             "update" => %{
               "sessionUpdate" => "agent_message_chunk",
               "content" => %{"type" => "text", "text" => chunk}
             }
           }
         },
         _id,
         acc
       ),
       do:
         {:cont,
          %{
            acc
            | text: acc.text <> chunk,
              last: acc.last <> chunk,
              first: if(acc.tooled, do: acc.first, else: acc.first <> chunk)
          }}

  # Kiro reports what each turn cost, in credits.
  defp handle(
         _conn,
         %{
           "method" => "session/update",
           "params" => %{"update" => %{"_meta" => %{"kiro" => %{"promptTurnSummaries" => s}}}}
         },
         _id,
         acc
       )
       when is_list(s) do
    credits = s |> Enum.map(&(&1["usage"] || 0)) |> Enum.sum()
    {:cont, %{acc | credits: credits / 1}}
  end

  defp handle(
         conn,
         %{
           "method" => "session/update",
           "params" => %{"update" => %{"sessionUpdate" => "tool_call"} = update}
         },
         _id,
         acc
       ) do
    conn.on_tool.(update)

    # Kiro 2.26 names the kind here, not on the permission request that follows.
    kinds =
      if is_binary(update["toolCallId"]) and is_binary(update["kind"]),
        do: Map.put(acc.kinds, update["toolCallId"], update["kind"]),
        else: acc.kinds

    # And the command, for a request to run one.
    commands =
      case {update["toolCallId"], Kiro.Permission.command_of(update)} do
        {id, command} when is_binary(id) and is_binary(command) ->
          Map.put(acc.commands, id, command)

        _ ->
          acc.commands
      end

    {:cont, %{acc | last: "", tooled: true, kinds: kinds, commands: commands}}
  end

  defp handle(_conn, _msg, _id, acc), do: {:cont, acc}
end
