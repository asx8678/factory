defmodule Factory.Kiro.Catalog do
  @moduledoc """
  The models and modes Kiro offers, as `kiro-cli` reports them. `check/0` starts a Kiro
  session (without a prompt, so it costs nothing), reads the model and mode options it
  offers, and remembers them (`Factory.Prefs`), so every model picker shows what this
  Kiro really has. Factory checks at startup; Settings has a Check now button.

  Lookups (`models/0`, `modes/0`) read a cache in `:persistent_term`, never the
  database, so they're cheap anywhere. Until a check has worked, they're `nil` and
  `Factory.Kiro` falls back to the list it ships with.
  """
  require Logger
  alias Factory.{Kiro, Prefs}
  alias Factory.Kiro.Wire

  @key {__MODULE__, :catalog}
  @timeout 30_000

  @doc "The models Kiro offers: `[%{\"value\", \"name\", \"description\"}]`, or nil."
  def models, do: get()["models"]

  @doc "The modes Kiro offers, like `models/0`."
  def modes, do: get()["modes"]

  @doc "When the catalog was last checked (ISO 8601), or nil."
  def checked_at, do: get()["checked_at"]

  @doc "The error from the last check, if it failed."
  def error, do: get()["error"]

  @doc "Whether the last check, or a Kiro that stopped since, found Kiro signed out."
  def signed_out?, do: Kiro.signed_out?(error())

  defp get, do: :persistent_term.get(@key, %{})

  @doc "Loads the catalog remembered from the last check. Called at startup."
  def load do
    case Prefs.get("kiro_catalog") do
      %{} = catalog -> :persistent_term.put(@key, catalog)
      _ -> :ok
    end
  end

  @doc """
  Asks Kiro which models and modes it offers, and remembers them. Returns
  `{:ok, catalog}` or `{:error, reason}` (a failed check keeps the last good list).
  """
  def check do
    case probe() do
      {:ok, options} ->
        catalog = %{
          "models" => options["model"] || [],
          "modes" => options["mode"] || [],
          "checked_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
        }

        save(catalog)
        {:ok, catalog}

      {:error, reason} ->
        note_failure(reason)
        Logger.warning("Couldn't check Kiro's models: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Remembers why Kiro couldn't be used, keeping the last good list: a failed check, or
  a session that found Kiro signed out. Pages show it until a check works again.
  """
  def note_failure(reason) do
    save(
      Map.merge(get(), %{
        "error" => reason,
        "failed_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
      })
    )
  end

  @doc "Checks in the background, e.g. at startup."
  def check_later do
    Task.Supervisor.start_child(Factory.TaskSupervisor, fn -> check() end)
  end

  defp save(catalog) do
    :persistent_term.put(@key, catalog)
    Prefs.put("kiro_catalog", catalog)
    Phoenix.PubSub.broadcast(Factory.PubSub, "kiro_catalog", {:kiro_catalog, catalog})
  end

  @doc "Subscribes to `{:kiro_catalog, catalog}` after each check."
  def subscribe, do: Phoenix.PubSub.subscribe(Factory.PubSub, "kiro_catalog")

  # A throwaway ACP session: initialize, session/new, read its config options, stop.
  defp probe do
    workdir = Kiro.config(:workspace)
    File.mkdir_p!(workdir)
    File.mkdir_p!(Kiro.config(:log_dir))
    mark = Kiro.log_mark("catalog.log")
    port = Kiro.open_port(workdir, "catalog.log")

    try do
      send_json(port, %{
        id: 1,
        method: "initialize",
        params: %{protocolVersion: 1, clientCapabilities: %{}}
      })

      with {:ok, _} <- await(port, 1, mark),
           :ok <-
             send_json(port, %{
               id: 2,
               method: "session/new",
               params: %{cwd: workdir, mcpServers: []}
             }),
           {:ok, result} <- await(port, 2, mark) do
        options =
          for %{"id" => id, "options" => opts} <- List.wrap(result["configOptions"]),
              id in ["model", "mode"],
              into: %{} do
            {id,
             for(
               %{"value" => v} = o <- opts,
               is_binary(v),
               do: %{
                 "value" => v,
                 "name" => o["name"] || v,
                 "description" => o["description"] || ""
               }
             )}
          end

        if options["model"] in [nil, []],
          do: {:error, "Kiro didn't say which models it has."},
          else: {:ok, options}
      end
    rescue
      e -> {:error, Exception.message(e)}
    after
      Wire.close(port)
    end
  end

  defp send_json(port, msg), do: Wire.send_json(port, Map.put(msg, :jsonrpc, "2.0"))

  # Waits for the reply to request `id`, at most @timeout in all however much else Kiro
  # sends meanwhile. `mark` is where this kiro-cli's lines begin in its log.
  defp await(port, id, mark),
    do: await(port, id, mark, "", System.monotonic_time(:millisecond) + @timeout)

  defp await(port, id, mark, buffer, deadline) do
    receive do
      {^port, {:data, data}} ->
        case Wire.read(buffer, data) do
          {:partial, buffer} ->
            await(port, id, mark, buffer, deadline)

          {:message, %{"id" => ^id, "result" => result}} ->
            {:ok, result}

          {:message, %{"id" => ^id, "error" => error}} ->
            {:error, error["message"] || inspect(error)}

          _ ->
            await(port, id, mark, "", deadline)
        end

      {^port, {:exit_status, status}} ->
        {:error, Kiro.stop_reason("catalog.log", mark, status)}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, "Kiro didn't answer within #{div(@timeout, 1000)} seconds."}
    end
  end
end
