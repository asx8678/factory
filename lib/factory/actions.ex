defmodule Factory.Actions do
  @moduledoc """
  Actions: steps in a workflow that aren't agents. They sit between agents or after
  them (an arrow into an action means "when that's done, do this"): commit and push,
  open a pull request, update or close a ticket, send an email, post to Slack or
  Teams, run a command that must pass.

  An action is a workflow card with kind "action" (`Factory.Agents.Agent`); its
  `action` field is `%{"type" => …, "config" => %{…}}`. Settings may use
  placeholders: `{{run}}` (the run's title), `{{summary}}`, `{{branch}}`, `{{run_id}}`.

  Tokens and webhook URLs are never stored: settings name environment variables,
  read when the action runs. An action may only name variables that look like
  settings (`env_allowed?/1`): never Factory's own secrets, and only those in
  `config :factory, :action_env_vars` when that list is set. The addresses it calls
  must be public (`safe_url?/1`): nothing on this machine or a private network,
  unless `config :factory, :allow_private_action_urls` is true. `plan/2` says exactly
  what an action would do (a dry run); `run/2` does it.
  """
  alias Factory.Agents.Agent

  # Environment variables no action may read, by name or by what the name says.
  @env_denied ~w(SECRET_KEY_BASE DATABASE_URL)
  @env_denied_pattern ~r/SECRET|PRIVATE_KEY|PASSWORD/
  @env_name ~r/^[A-Z][A-Z0-9_]*$/

  # What a setting must look like, beyond being filled in, for the ones that go into an
  # address: {type, key, regex, hint}. (Azure DevOps names are encoded, so any will do.)
  @shapes [
    {"github_pr", "repo", ~r{^[\w.-]+/[\w.-]+$}, "owner/name"},
    {"github_issue", "repo", ~r{^[\w.-]+/[\w.-]+$}, "owner/name"},
    {"github_issue", "issue", ~r/^\d+$/, "a number"},
    {"azure_item_update", "item", ~r/^\d+$/, "a number"},
    {"azure_item_close", "item", ~r/^\d+$/, "a number"}
  ]

  # {type, label, group, what it does, fields}; a field is
  # {key, label, input, placeholder or default, required?}. Inputs: :text, :textarea,
  # :env (the name of an environment variable), {:select, options}.
  @types [
    {"git_push", "Commit & push", "Git & pull requests",
     "Commit everything the agents changed and push the branch.",
     [
       {"branch", "Branch", :text, "factory/{{run_id}}", false},
       {"message", "Commit message", :text, "{{run}}", true},
       {"remote", "Remote", :text, "origin", false},
       {"folder", "Folder", :text, "The run's project folder", false}
     ]},
    {"github_pr", "Create GitHub PR", "Git & pull requests",
     "Open a pull request on GitHub for the pushed branch.",
     [
       {"repo", "Repository", :text, "owner/name", true},
       {"head", "From branch", :text, "{{branch}}", true},
       {"base", "Into branch", :text, "main", true},
       {"title", "Title", :text, "{{run}}", true},
       {"body", "Description", :textarea, "{{summary}}", false},
       {"token_env", "Token variable", :env, "GITHUB_TOKEN", true}
     ]},
    {"azure_pr", "Create Azure DevOps PR", "Git & pull requests",
     "Open a pull request in an Azure DevOps repository.",
     [
       {"org", "Organization", :text, "contoso", true},
       {"project", "Project", :text, "Shop", true},
       {"repo", "Repository", :text, "backend", true},
       {"source", "From branch", :text, "{{branch}}", true},
       {"target", "Into branch", :text, "main", true},
       {"title", "Title", :text, "{{run}}", true},
       {"description", "Description", :textarea, "{{summary}}", false},
       {"pat_env", "Token variable", :env, "AZURE_DEVOPS_PAT", true}
     ]},
    {"azure_item_update", "Update Azure DevOps ticket", "Tickets",
     "Move a work item to a new state and add a comment.",
     [
       {"org", "Organization", :text, "contoso", true},
       {"project", "Project", :text, "Shop", true},
       {"item", "Work item id", :text, "1234", true},
       {"state", "New state", :text, "Active, Resolved…", false},
       {"comment", "Comment", :textarea, "Factory: {{summary}}", false},
       {"pat_env", "Token variable", :env, "AZURE_DEVOPS_PAT", true}
     ]},
    {"azure_item_close", "Close Azure DevOps ticket", "Tickets",
     "Close a work item when the job is done, with a comment.",
     [
       {"org", "Organization", :text, "contoso", true},
       {"project", "Project", :text, "Shop", true},
       {"item", "Work item id", :text, "1234", true},
       {"state", "Closed state", :text, "Closed", true},
       {"comment", "Comment", :textarea, "Done by Factory: {{run}}", false},
       {"pat_env", "Token variable", :env, "AZURE_DEVOPS_PAT", true}
     ]},
    {"github_issue", "Update GitHub issue", "Tickets",
     "Comment on a GitHub issue, and close it if you like.",
     [
       {"repo", "Repository", :text, "owner/name", true},
       {"issue", "Issue number", :text, "42", true},
       {"comment", "Comment", :textarea, "Factory: {{summary}}", false},
       {"close", "Close it", {:select, ["no", "yes"]}, "no", false},
       {"token_env", "Token variable", :env, "GITHUB_TOKEN", true}
     ]},
    {"email", "Send email", "Notify", "Email someone when this point is reached.",
     [
       {"to", "To", :text, "team@example.com", true},
       {"subject", "Subject", :text, "Factory: {{run}}", true},
       {"body", "Message", :textarea, "{{summary}}", true},
       {"from", "From", :text, "factory@localhost", false}
     ]},
    {"webhook", "Slack or Teams message", "Notify",
     "Post a message to a Slack or Microsoft Teams channel webhook.",
     [
       {"url_env", "Webhook URL variable", :env, "SLACK_WEBHOOK_URL", true},
       {"text", "Message", :textarea, "Factory finished {{run}}", true}
     ]},
    {"api_request", "API request", "API",
     "Call any HTTP API: GET, POST, PUT, PATCH or DELETE, with headers and a JSON body.",
     [
       {"method", "Method", {:select, ["POST", "GET", "PUT", "PATCH", "DELETE"]}, "POST", true},
       {"url", "URL", :text, "https://api.example.com/deploys", true},
       {"headers", "Headers", :textarea, "One per line, e.g. X-Team: platform", false},
       {"body", "Body", :textarea, ~s({"run": "{{run}}", "summary": "{{summary}}"}), false},
       {"token_env", "Token variable", :text, "Optional: sent as Authorization: Bearer", false}
     ]},
    {"command", "Run a command", "Checks",
     "Run a command, like the tests; the run only goes on if it succeeds.",
     [
       {"command", "Command", :text, "mix test", true},
       {"folder", "Folder", :text, "The run's project folder", false}
     ]}
  ]

  @doc "Every action type: `%{type:, label:, group:, blurb:, fields:}`."
  def types do
    for {type, label, group, blurb, fields} <- @types,
        do: %{type: type, label: label, group: group, blurb: blurb, fields: fields}
  end

  def get(type), do: Enum.find(types(), &(&1.type == type))

  def label(%Agent{action: %{"type" => type}}), do: label(type)
  def label(type) when is_binary(type), do: (get(type) || %{label: "Action"}).label

  @doc "A new action's settings: every field with a default (placeholder text isn't one)."
  def defaults(type) do
    for {key, _, input, default, _} <- get(type).fields,
        default?(key, input, default),
        into: %{},
        do: {key, default}
  end

  # Examples ("contoso", "owner/name", "The run's …") aren't defaults; templates are.
  defp default?(_key, :env, _), do: true
  defp default?(_key, {:select, _}, _), do: true

  defp default?(key, _, default),
    do:
      key in ~w(message remote branch head source title body description comment subject text state base target) and
        (String.contains?(default, "{{") or default in ["origin", "main", "Closed"])

  @doc "Required settings that are still empty."
  def missing(%Agent{action: %{"type" => type} = action}) do
    config = action["config"] || %{}

    for {key, label, _, _, true} <- get(type).fields,
        String.trim(to_string(config[key] || "")) == "",
        do: label
  end

  def missing(_), do: ["Type"]

  @doc """
  What's wrong with the settings that are filled in, as sentences: a token variable an
  action may not read (`env_allowed?/1`), an address that isn't public (`safe_url?/1`),
  a repository or ticket number that isn't one. Empty when all is well.
  """
  def invalid(%Agent{action: %{"type" => type} = action}) do
    config = action["config"] || %{}

    for {key, label, _, _, _} <- get(type).fields,
        value = Factory.Text.presence(config[key]),
        problem = problem(type, key, label, value),
        do: problem
  end

  def invalid(_), do: []

  defp problem(type, key, label, value) do
    shape = Enum.find(@shapes, fn {t, k, _, _} -> t == type and k == key end)

    cond do
      String.ends_with?(key, "_env") and not env_allowed?(value) ->
        "#{label}: #{value} isn't an environment variable an action may read."

      key == "url" and not safe_url?(value) ->
        "#{label}: #{value} must be a public http(s) address."

      shape != nil and not Regex.match?(elem(shape, 2), value) ->
        "#{label} must be #{elem(shape, 3)}, not #{value}."

      true ->
        nil
    end
  end

  @doc """
  Whether an action may read the environment variable `name`: a plain upper-case name
  that isn't one of Factory's own secrets (`SECRET_KEY_BASE`, `DATABASE_URL`, anything
  with SECRET, PRIVATE_KEY or PASSWORD in it) and, when `config :factory,
  :action_env_vars` lists names, one of those.
  """
  def env_allowed?(name) when is_binary(name) do
    name = String.trim(name)

    Regex.match?(@env_name, name) and name not in @env_denied and
      not Regex.match?(@env_denied_pattern, name) and listed_env?(name)
  end

  def env_allowed?(_name), do: false

  defp listed_env?(name) do
    case Application.get_env(:factory, :action_env_vars) do
      nil -> true
      names when is_list(names) -> name in names
    end
  end

  @doc """
  Whether an action may call `url`: an http(s) address whose host isn't this machine
  or a private network (loopback, link-local, 10/8, 172.16/12, 192.168/16, fc00::/7,
  `localhost`, `.local`, `.internal`). A name is judged by its spelling alone, not by
  what it resolves to (no DNS lookup: this stays quick and synchronous), so a public
  name that points at a private address isn't caught here. `config :factory,
  :allow_private_action_urls` set to true allows them all.
  """
  def safe_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != "" and
          (Application.get_env(:factory, :allow_private_action_urls) == true or
             public_host?(host))

      _ ->
        false
    end
  end

  def safe_url?(_url), do: false

  defp public_host?(host) do
    name =
      host
      |> String.downcase()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.trim_trailing(".")

    case :inet.parse_strict_address(String.to_charlist(name)) do
      {:ok, ip} ->
        not private_ip?(ip)

      {:error, _} ->
        name not in ["localhost", "localhost.localdomain"] and
          not String.ends_with?(name, [".localhost", ".local", ".internal", ".home.arpa"])
    end
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({_, _, _, _}), do: false
  # ::1, ::, fc00::/7 (unique local), fe80::/10 (link-local), and IPv4 mapped in IPv6.
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true

  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: private_ip?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  defp private_ip?(_ip), do: false

  @doc "Fills `{{run}}`, `{{summary}}`, `{{branch}}` and `{{run_id}}` from the context."
  def render(text, ctx) do
    Regex.replace(~r/\{\{\s*(\w+)\s*\}\}/, to_string(text || ""), fn whole, key ->
      case ctx[key] do
        nil -> whole
        value -> to_string(value)
      end
    end)
  end

  @doc """
  The context an action runs in. Outside a run (trying it from the Workflows page)
  it uses sample values, so templates still read sensibly.
  """
  def context(run \\ nil) do
    base = %{
      "run" => "Factory test run",
      "run_id" => "test",
      "summary" => "Test from the Workflows page.",
      "folder" => Factory.Kiro.config(:workspace)
    }

    ctx =
      case run do
        nil ->
          base

        run ->
          %{
            base
            | "run" => run.title,
              "run_id" => to_string(run.id),
              "summary" => "Factory run “#{run.title}”.",
              "folder" => Factory.Kiro.workdir(run)
          }
      end

    Map.put(ctx, "branch", "factory/#{ctx["run_id"]}")
  end

  # What each action does, as steps: {:cmd, folder, args, label} or
  # {:http, method, url, headers, body, label} or {:email, email, label}.

  @doc "Says what the action would do, without doing it: `{:ok, [line]}` or `{:error, reason}`."
  def plan(%Agent{} = action, ctx \\ context()) do
    with {:ok, steps} <- steps(action, ctx, :plan) do
      {:ok, Enum.map(steps, &describe/1)}
    end
  end

  @doc "Does the action: `{:ok, what happened}` or `{:error, reason}`."
  def run(%Agent{} = action, ctx \\ context()) do
    with {:ok, steps} <- steps(action, ctx, :run) do
      Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, done} ->
        case perform(step) do
          {:ok, out} -> {:cont, {:ok, done ++ [out]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, lines} -> {:ok, lines |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")}
        error -> error
      end
    end
  end

  defp steps(%Agent{action: %{"type" => type} = action} = card, ctx, mode) do
    # A command's script is kept as written: build/4 hands its values to the shell safely.
    # An API request's JSON body is filled in value by value, so a summary with quotes
    # or braces in it stays text and can't change the body's shape.
    c =
      Map.new(action["config"] || %{}, fn
        {"command", v} when type == "command" -> {"command", to_string(v || "")}
        {"body", v} when type == "api_request" -> {"body", render_body(v, ctx)}
        # Header by header: a summary with line breaks in it can't add headers.
        {"headers", v} when type == "api_request" -> {"headers", api_headers(v, ctx)}
        {k, v} -> {k, render(v, ctx)}
      end)

    case {missing(card), invalid(card)} do
      {[], []} -> build(type, c, ctx, mode)
      {[], problems} -> {:error, Enum.join(problems, " ")}
      {labels, _} -> {:error, "Fill in: #{Enum.join(labels, ", ")}."}
    end
  end

  defp steps(_card, _ctx, _mode), do: {:error, "This card has no action type."}

  defp build("git_push", c, ctx, _mode) do
    folder = folder(c, ctx)
    remote = Factory.Text.presence(c["remote"]) || "origin"
    branch = Factory.Text.presence(c["branch"])

    {:ok,
     if(branch,
       do: [{:cmd, folder, ["checkout", "-B", branch], "Switch to branch #{branch}"}],
       else: []
     ) ++
       [
         {:cmd, folder, ["add", "-A"], "Stage every change"},
         {:cmd, folder, ["commit", "-m", c["message"]], "Commit: #{c["message"]}"},
         {:cmd, folder, ["push", "-u", remote, branch || "HEAD"], "Push to #{remote}"}
       ]}
  end

  defp build("github_pr", c, _ctx, mode) do
    with {:ok, token} <- env(c["token_env"], mode) do
      {:ok,
       [
         {:http, :post, "https://api.github.com/repos/#{github_repo(c)}/pulls", github(token),
          %{title: c["title"], head: c["head"], base: c["base"], body: c["body"] || ""},
          "Open a pull request on #{c["repo"]}: #{c["head"]} → #{c["base"]}, “#{c["title"]}”"}
       ]}
    end
  end

  defp build("azure_pr", c, _ctx, mode) do
    with {:ok, pat} <- env(c["pat_env"], mode) do
      url =
        "#{azure_base(c)}/_apis/git/repositories/#{enc(c["repo"])}/pullrequests?api-version=7.1"

      {:ok,
       [
         {:http, :post, url, azure(pat),
          %{
            sourceRefName: "refs/heads/#{c["source"]}",
            targetRefName: "refs/heads/#{c["target"]}",
            title: c["title"],
            description: c["description"] || ""
          },
          "Open a pull request in #{c["org"]}/#{c["project"]}/#{c["repo"]}: #{c["source"]} → #{c["target"]}, “#{c["title"]}”"}
       ]}
    end
  end

  defp build(type, c, _ctx, mode) when type in ["azure_item_update", "azure_item_close"] do
    with {:ok, pat} <- env(c["pat_env"], mode) do
      ops =
        [
          Factory.Text.presence(c["state"]) &&
            %{op: "add", path: "/fields/System.State", value: c["state"]},
          Factory.Text.presence(c["comment"]) &&
            %{op: "add", path: "/fields/System.History", value: c["comment"]}
        ]
        |> Enum.filter(& &1)

      what =
        [
          Factory.Text.presence(c["state"]) && "set state to #{c["state"]}",
          Factory.Text.presence(c["comment"]) && "add a comment"
        ]
        |> Enum.filter(& &1)
        |> Enum.join(" and ")

      if ops == [] do
        {:error, "Give a new state or a comment."}
      else
        {:ok,
         [
           {:http, :patch,
            "#{azure_base(c)}/_apis/wit/workitems/#{enc(c["item"])}?api-version=7.1",
            [{"content-type", "application/json-patch+json"} | azure(pat)], ops,
            "Work item #{c["item"]} in #{c["org"]}/#{c["project"]}: #{what}"}
         ]}
      end
    end
  end

  defp build("github_issue", c, _ctx, mode) do
    with {:ok, token} <- env(c["token_env"], mode) do
      base = "https://api.github.com/repos/#{github_repo(c)}/issues/#{enc(c["issue"])}"

      steps =
        [
          Factory.Text.presence(c["comment"]) &&
            {:http, :post, "#{base}/comments", github(token), %{body: c["comment"]},
             "Comment on #{c["repo"]}##{c["issue"]}"},
          c["close"] == "yes" &&
            {:http, :patch, base, github(token), %{state: "closed"},
             "Close #{c["repo"]}##{c["issue"]}"}
        ]
        |> Enum.filter(& &1)

      if steps == [], do: {:error, "Write a comment or choose to close it."}, else: {:ok, steps}
    end
  end

  defp build("email", c, _ctx, _mode) do
    email =
      Swoosh.Email.new(
        to: c["to"] |> String.split(~r/[,;\s]+/, trim: true),
        from: Factory.Text.presence(c["from"]) || "factory@localhost",
        subject: c["subject"],
        text_body: c["body"]
      )

    {:ok, [{:email, email, "Email #{c["to"]}: “#{c["subject"]}”"}]}
  end

  defp build("webhook", c, _ctx, mode) do
    with {:ok, url} <- env(c["url_env"], mode),
         :ok <- if(mode == :plan, do: :ok, else: check_url(url)) do
      {:ok,
       [
         {:http, :post, url, [], %{text: c["text"]},
          "Post to the webhook in $#{c["url_env"]}: “#{c["text"]}”"}
       ]}
    end
  end

  defp build("api_request", c, _ctx, mode) do
    method = c["method"] |> to_string() |> String.downcase()
    method = if method in ~w(get post put patch delete), do: String.to_atom(method), else: :post

    with {:ok, auth} <- api_auth(Factory.Text.presence(c["token_env"]), mode),
         :ok <- check_url(c["url"]) do
      headers = (c["headers"] || []) ++ auth

      body =
        case {method, c["body"]} do
          {m, _} when m in [:get, :delete] -> nil
          {_, {:json, data}} -> api_body({:json, data})
          {_, text} -> if Factory.Text.presence(text), do: api_body(text), else: nil
        end

      {:ok,
       [
         {:http, method, c["url"], headers, body,
          "#{String.upcase(to_string(method))} #{c["url"]}"}
       ]}
    end
  end

  defp build("command", c, ctx, _mode) do
    shown = render(c["command"], ctx)

    {:ok,
     [
       {:sh, folder(c, ctx), shell_script(c["command"], ctx), shell_env(ctx), shown}
     ]}
  end

  defp build(type, _c, _ctx, _mode), do: {:error, "Factory doesn't know the action “#{type}”."}

  # Placeholders become shell variables, and their values travel in the environment, so a
  # summary like `$(rm -rf ~)` is only ever text: the shell never re-reads expanded values.
  defp shell_script(script, ctx) do
    Regex.replace(~r/\{\{\s*(\w+)\s*\}\}/, script, fn whole, key ->
      if Map.has_key?(ctx, key), do: "${#{env_name(key)}}", else: whole
    end)
  end

  defp shell_env(ctx), do: for({k, v} <- ctx, do: {env_name(k), to_string(v)})

  defp env_name(key), do: "FACTORY_" <> String.upcase(key)

  defp folder(c, ctx) do
    case Factory.Text.presence(c["folder"]) do
      nil -> ctx["folder"]
      f -> Path.expand(f)
    end
  end

  # A token or URL from the environment, one an action may read (`env_allowed?/1`). A
  # dry run only says which variable it reads.
  defp env(var, mode) do
    var = String.trim(to_string(var))

    cond do
      not env_allowed?(var) ->
        {:error, "#{var} isn't an environment variable an action may read."}

      mode == :plan ->
        {:ok, "$#{var}"}

      true ->
        case System.get_env(var) do
          nil ->
            {:error, "The environment variable #{var} isn't set. Set it and restart Factory."}

          "" ->
            {:error, "The environment variable #{var} is empty."}

          value ->
            {:ok, value}
        end
    end
  end

  # The address an action is about to call must be public (`safe_url?/1`). (A dry run's
  # webhook address is the variable's name, not an address, so it's only checked when run.)
  defp check_url(url) do
    if safe_url?(url),
      do: :ok,
      else: {:error, "#{url} isn't a public http(s) address, so the action didn't call it."}
  end

  defp api_auth(nil, _mode), do: {:ok, []}

  defp api_auth(var, mode) do
    with {:ok, token} <- env(var, mode), do: {:ok, [{"authorization", "Bearer #{token}"}]}
  end

  # "Name: value" per line, each value filled in after the lines are split, on one line.
  defp api_headers(text, ctx) do
    for line <- String.split(to_string(text || ""), ~r/\R/u, trim: true),
        [name, value] <- [String.split(line, ":", parts: 2)],
        String.trim(name) != "",
        do:
          {String.downcase(String.trim(name)),
           value |> render(ctx) |> String.replace(~r/[\r\n]+/, " ") |> String.trim()}
  end

  # The body template as JSON with its placeholders filled in inside the strings, or as
  # text with them filled in when it isn't JSON.
  defp render_body(template, ctx) do
    text = to_string(template || "")

    case JSON.decode(text) do
      {:ok, data} -> {:json, render_in(data, ctx)}
      {:error, _} -> render(text, ctx)
    end
  end

  defp render_in(s, ctx) when is_binary(s), do: render(s, ctx)
  defp render_in(list, ctx) when is_list(list), do: Enum.map(list, &render_in(&1, ctx))

  defp render_in(map, ctx) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, render_in(v, ctx)} end)

  defp render_in(other, _ctx), do: other

  # JSON when the template was JSON; otherwise sent as text.
  defp api_body({:json, data}), do: data
  defp api_body(text), do: {:raw, text}

  defp github(token),
    do: [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

  defp azure(pat), do: [{"authorization", "Basic " <> Base.encode64(":" <> pat)}]

  defp azure_base(c), do: "https://dev.azure.com/#{enc(c["org"])}/#{enc(c["project"])}"

  # "owner/name", each part on its own in the address (`invalid/1` checked the shape).
  defp github_repo(c),
    do: c["repo"] |> to_string() |> String.split("/", parts: 2) |> Enum.map_join("/", &enc/1)

  defp enc(s), do: URI.encode(String.trim(to_string(s)), &URI.char_unreserved?/1)

  defp describe({:cmd, folder, args, label}),
    do: "#{label}: git #{Enum.join(args, " ")} (in #{folder})"

  defp describe({:sh, folder, _cmd, _env, shown}),
    do: "Run `#{shown}` (must succeed) in #{folder}"

  defp describe({:http, method, url, _h, _b, label}),
    do:
      "#{label} (#{method |> to_string() |> String.upcase()} #{url |> String.split("?") |> hd()})"

  defp describe({:email, _email, label}), do: label

  # Doing it

  @git_timeout 5 * 60_000

  # git never asks for anything (a password, a passphrase, whether to trust a host): it
  # fails instead, and one that overruns is stopped with ssh and anything else it started.
  defp perform({:cmd, folder, args, label}) do
    remote? = hd(args) in ~w(push fetch pull)
    env = [{"GIT_TERMINAL_PROMPT", "0"} | if(remote?, do: ssh_env(folder), else: [])]

    case Factory.OsProcess.run("git", args, cd: folder, env: env, timeout: @git_timeout) do
      {:ok, _, 0} ->
        {:ok, label}

      {:ok, out, _} ->
        if out =~ "nothing to commit",
          do: {:ok, "Nothing to commit"},
          else: {:error, "#{label} failed: #{tail(out)}"}

      {:error, :timeout} ->
        {:error,
         "#{label} failed: git took over #{div(@git_timeout, 60_000)} minutes and was stopped."}

      {:error, reason} ->
        {:error, "#{label} failed: #{reason(reason)}"}
    end
  end

  # The shell and everything it started (the tests, say) are stopped at the deadline.
  defp perform({:sh, folder, command, env, shown}) do
    if is_binary(folder) and File.dir?(folder) do
      case Factory.OsProcess.run("sh", ["-c", command], cd: folder, env: env, timeout: 600_000) do
        {:ok, out, 0} -> {:ok, "Run `#{shown}` (must succeed): passed\n#{tail(out)}"}
        {:ok, out, code} -> {:error, "`#{shown}` failed (exit #{code}):\n#{tail(out)}"}
        {:error, :timeout} -> {:error, "`#{shown}` took over 10 minutes and was stopped."}
        {:error, reason} -> {:error, "`#{shown}` failed: #{reason(reason)}"}
      end
    else
      {:error, "The folder #{folder || "(none)"} doesn't exist."}
    end
  end

  defp perform({:http, method, url, headers, body, label}) do
    with :ok <- check_url(url) do
      request({:http, method, url, headers, body, label})
    end
  end

  defp perform({:email, email, label}) do
    case Factory.Mailer.deliver(email) do
      {:ok, _} -> {:ok, label}
      {:error, reason} -> {:error, "#{label} failed: #{inspect(reason)}"}
    end
  end

  defp request({:http, method, url, headers, body, label}) do
    payload =
      case body do
        nil -> []
        {:raw, text} -> [body: text]
        data -> [json: data]
      end

    # Not redirected: the address was checked (`check_url/1`), the one it redirects to
    # (a machine on this network) wasn't.
    opts = [method: method, url: url, headers: headers, retry: false, redirect: false] ++ payload
    opts = Keyword.merge(opts, Application.get_env(:factory, :actions_req_options, []))

    case Req.request(opts) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        link =
          is_map(resp) &&
            (resp["html_url"] || get_in(resp, ["_links", "web", "href"]) || resp["url"])

        {:ok,
         cond do
           is_binary(link) ->
             "#{label}: #{link}"

           method in [:get] or label =~ ~r/^(GET|POST|PUT|PATCH|DELETE) / ->
             "#{label}: HTTP #{status}\n#{preview(resp)}"

           true ->
             label
         end}

      {:ok, %{status: status, body: resp}} ->
        {:error, "#{label} failed (HTTP #{status}): #{error_text(resp)}"}

      {:error, e} ->
        {:error, "#{label} failed: #{Exception.message(e)}"}
    end
  end

  # ssh in batch mode, so a key's passphrase or a host it doesn't know yet fails at once.
  # It adds to the ssh command git would use anyway (GIT_SSH_COMMAND, else
  # core.sshCommand), so a key chosen there still counts; a GIT_SSH program is left be,
  # but ssh started by one still mustn't ask for a password or passphrase
  # (SSH_ASKPASS_REQUIRE=never: no prompt, it fails instead).
  defp ssh_env(folder) do
    [{"SSH_ASKPASS_REQUIRE", "never"} | ssh_command_env(folder)]
  end

  defp ssh_command_env(folder) do
    cond do
      command = Factory.Text.presence(System.get_env("GIT_SSH_COMMAND")) ->
        [{"GIT_SSH_COMMAND", batch(command)}]

      Factory.Text.presence(System.get_env("GIT_SSH")) ->
        []

      true ->
        [{"GIT_SSH_COMMAND", batch(ssh_config(folder) || "ssh")}]
    end
  end

  defp batch(ssh), do: ssh <> " -o BatchMode=yes -o ConnectTimeout=15"

  defp ssh_config(folder) do
    case Factory.OsProcess.run("git", ~w(config --get core.sshCommand),
           cd: folder,
           timeout: 10_000
         ) do
      {:ok, out, 0} -> Factory.Text.presence(out)
      _ -> nil
    end
  end

  defp reason(reason) when is_binary(reason), do: reason
  defp reason(reason), do: Exception.format_exit(reason)

  defp preview(""), do: ""
  defp preview(body) when is_binary(body), do: String.slice(body, 0, 400)
  defp preview(body), do: body |> JSON.encode!() |> String.slice(0, 400)

  defp error_text(%{"message" => m}), do: m
  defp error_text(body) when is_binary(body), do: tail(body)
  defp error_text(body), do: body |> inspect() |> tail()

  defp tail(text), do: text |> to_string() |> String.trim() |> String.slice(-500, 500)
end
