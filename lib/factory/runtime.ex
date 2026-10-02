defmodule Factory.Runtime do
  @moduledoc """
  The coding CLI Factory's agents run on: Kiro (`kiro-cli acp`), or pi through its ACP
  adapter (`pi-acp`, which starts `pi --mode rpc`). Both speak ACP over stdio, so the
  sessions (`Factory.Kiro.Session`, `Factory.Kiro.Ask`) are the same; what differs is
  here: how each is found and started, and what it can't do.

  Kiro is the default. pi is for when Kiro can't be used (its usage limit, say), on a
  model pi offers, chosen in Settings. On pi:

    * there is one model, the one chosen (`pi_model/0`): agents' and tasks' own models
      are Kiro's and aren't used, so `Factory.Kiro.models/0` is just "auto";
    * Factory's tools reach pi through its extension (`priv/pi/factory.ts`), which also
      asks Factory before every tool pi runs (`Factory.Kiro.Session.permit/4`), as
      pi never asks by itself;
    * a question to the person is shown when the turn ends, not during it, and what
      Factory would ask the person first (a web page, a file outside the project) is
      refused;
    * pi reports no credits, so a run's credit limit never stops it.

  The choice is kept in `Factory.Prefs` and read from `:persistent_term`, like the
  Kiro catalog, so asking which runtime is in use costs nothing.
  """
  alias Factory.Prefs

  @key {__MODULE__, :runtime}

  @doc "The runtime in use: `:kiro`, or `:pi` when it's chosen and still there."
  def current do
    case :persistent_term.get(@key, %{}) do
      %{"runtime" => "pi"} -> if pi_there?(), do: :pi, else: :kiro
      _ -> :kiro
    end
  end

  # Whether pi is still installed, looked up at most every 30 seconds: `current/0` is
  # asked on every page drawn, and looking costs a search of the PATH.
  @detected {__MODULE__, :pi_there}
  defp pi_there? do
    now = System.monotonic_time(:second)

    case :persistent_term.get(@detected, nil) do
      {at, there?} when now - at < 30 ->
        there?

      _ ->
        there? = available?(:pi)
        :persistent_term.put(@detected, {now, there?})
        there?
    end
  end

  @doc "Loads the choice remembered. Called at startup."
  def load do
    :persistent_term.put(@key, %{
      "runtime" => Prefs.get("runtime"),
      "pi_model" => Prefs.get("pi_model")
    })
  end

  @doc """
  Chooses the runtime (`:kiro` or `:pi`) for every agent from now on. The sessions
  running are stopped, so the next message starts on the new one. `{:error, reason}`
  when it isn't installed.
  """
  def choose(runtime) when runtime in [:kiro, :pi] do
    :persistent_term.erase(@detected)

    if available?(runtime) do
      put("runtime", to_string(runtime))
      Factory.Kiro.stop_all()
      :ok
    else
      {:error, "#{label(runtime)} isn't installed on this computer."}
    end
  end

  @doc "The model pi runs on, as pi names it (`provider/model`), or nil for pi's own default."
  def pi_model do
    case :persistent_term.get(@key, %{}) do
      %{"pi_model" => model} when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @doc "Chooses pi's model (nil or \"\" for pi's own default). Sessions on pi start again."
  def choose_pi_model(model) do
    put("pi_model", if(model in [nil, ""], do: nil, else: model))
    if current() == :pi, do: Factory.Kiro.stop_all()
    :ok
  end

  defp put(key, value) do
    Prefs.put(key, value)
    :persistent_term.put(@key, Map.put(:persistent_term.get(@key, %{}), key, value))
    Phoenix.PubSub.broadcast(Factory.PubSub, "runtime", {:runtime, current()})
  end

  @doc "Subscribes to `{:runtime, runtime}` when the choice changes."
  def subscribe, do: Phoenix.PubSub.subscribe(Factory.PubSub, "runtime")

  @doc "What a runtime is called."
  def label(:kiro), do: "Kiro"
  def label(:pi), do: "pi"

  @doc """
  What's installed: `%{kiro: path | nil, pi: path | nil, pi_acp: path | nil}`. pi needs
  both `pi` and its ACP adapter.
  """
  def detect do
    %{kiro: existing(Factory.Kiro.config(:cli)), pi: find(:cli), pi_acp: find(:acp)}
  end

  @doc "Whether a runtime can be started here."
  def available?(:kiro), do: detect().kiro != nil
  def available?(:pi), do: match?(%{pi: pi, pi_acp: acp} when pi != nil and acp != nil, detect())

  # `config :factory, :pi, cli: path, acp: path` names them; else they're looked up on
  # the PATH, each time, so one installed while Factory runs is found.
  defp find(key) do
    configured = Application.get_env(:factory, :pi, [])[key]
    name = if key == :cli, do: "pi", else: "pi-acp"
    existing(configured) || System.find_executable(name)
  end

  defp existing(path) when is_binary(path), do: if(File.exists?(path), do: path)
  defp existing(_path), do: nil

  @doc """
  The program to start for a runtime, with its arguments and environment (`{name,
  value}` strings): `{executable, args, env}`. `opts` for pi: `:mcp`, Factory's MCP
  server for the session (`%{url:, headers:}`), and `:permit`, the token its extension
  asks Factory with before each tool.
  """
  def command(:kiro, _opts) do
    # v3 rejects --model; the model and mode are set on the session, per turn.
    {Factory.Kiro.config(:cli), ["acp", "--agent-engine", "v3", "--auth-method", "cli"], []}
  end

  def command(:pi, opts) do
    found = detect()
    mcp = opts[:mcp] || %{}

    token =
      Enum.find_value(List.wrap(mcp[:headers]), "", fn h ->
        h[:name] == "Authorization" && String.replace_prefix(h[:value] || "", "Bearer ", "")
      end)

    env =
      [
        # pi-acp starts this in place of pi: the wrapper adds what Factory needs.
        {"PI_ACP_PI_COMMAND", Path.join(priv(), "pi.sh")},
        {"FACTORY_PI", found.pi || "pi"},
        {"FACTORY_PI_MODEL", pi_model() || ""},
        {"FACTORY_PI_EXTENSIONS",
         Enum.join([Path.join(priv(), "factory.ts") | provider_extensions()], ":")},
        {"FACTORY_MCP_URL", mcp[:url] || Factory.PlanTools.url()},
        {"FACTORY_MCP_TOKEN", token},
        {"FACTORY_PERMIT_TOKEN", opts[:permit] || ""}
      ]

    {found.pi_acp, [], env}
  end

  defp priv, do: Path.join(:code.priv_dir(:factory), "pi")

  @doc """
  The models pi offers, as it lists them (`pi --list-models`): `[%{"value" =>
  "provider/model", "name" => ...}]`, or `[]` when pi can't say. Slow (it starts pi),
  so for Settings only.
  """
  def pi_models do
    with pi when is_binary(pi) <- detect().pi,
         {:ok, out, 0} <- Factory.OsProcess.run(pi, ["--list-models"], timeout: 30_000) do
      for line <- String.split(out, "\n"),
          [provider, model | _] <- [String.split(line)],
          provider != "provider",
          String.match?(provider, ~r/^[\w.-]+$/) and String.match?(model, ~r/^[\w.:\/@-]+$/),
          do: %{"value" => "#{provider}/#{model}", "name" => "#{provider}/#{model}"}
    else
      _ -> []
    end
  end

  # pi runs without the person's own extensions, which write into replies (a speed
  # footer, say). The one that brings the chosen model's provider is needed, though:
  # an installed pi package named after the provider (`pi-zro-provider` for `zro/…`).
  # A provider built into pi needs none.
  defp provider_extensions do
    with model when is_binary(model) <- pi_model(),
         [provider, _] <- String.split(model, "/", parts: 2) do
      dir = System.get_env("PI_CODING_AGENT_DIR") || Path.expand("~/.pi/agent")

      (Path.wildcard(Path.join(dir, "npm/node_modules/*")) ++
         Path.wildcard(Path.join(dir, "npm/node_modules/@*/*")) ++
         Path.wildcard(Path.join(dir, "git/*/*/*")))
      |> Enum.filter(&(&1 |> Path.basename() |> String.downcase() |> String.contains?(provider)))
      |> Enum.flat_map(&entry/1)
    else
      _ -> []
    end
  end

  # A pi package's extension file: what its package.json names, else its index.
  defp entry(dir) do
    named =
      with {:ok, json} <- File.read(Path.join(dir, "package.json")),
           {:ok, %{"pi" => %{"extensions" => [first | _]}}} when is_binary(first) <-
             JSON.decode(json),
           do: Path.expand(first, dir),
           else: (_ -> nil)

    Enum.filter([named || Path.join(dir, "index.ts")], &File.exists?/1) |> Enum.take(1)
  end
end
