defmodule Factory.Kiro.Permit do
  @moduledoc """
  Whether a tool may run, for a CLI that never asks by itself: pi, whose extension
  (`priv/pi/factory.ts`) asks here before every tool pi runs, through `FactoryWeb.MCP`.
  The answer is by the rules Kiro's permission requests get (`Factory.Kiro.Permission`).

  The token says who asks: a session's own (`Factory.RunTools.grant_session/2`), judged
  by the turn under way (`Factory.Kiro.Session.permit/6`), or one made for a one-off
  question (`grant/3`, for `Factory.Kiro.Ask`), which carries what that question may do.
  Without a good token nothing is allowed.
  """
  alias Factory.Kiro
  alias Factory.Kiro.Permission

  @salt "pi permit"
  # A one-off question ends within the prompt timeout; a day is plenty.
  @max_age 86_400

  @doc """
  A token for a one-off question that may use the tool kinds in `allow` (as
  `Factory.Kiro.Ask` takes them, "look" for commands that only look) in `workdir` and
  `roots`.
  """
  def grant(allow, workdir, roots) do
    Phoenix.Token.sign(FactoryWeb.Endpoint, @salt, %{
      allow: allow,
      workdir: workdir,
      roots: roots
    })
  end

  @doc """
  Whether pi's tool `tool` may run with `input` (its arguments) in `cwd`: `:allow` or
  `{:deny, why}`.
  """
  def decide(token, tool, input, cwd) when is_binary(tool) and is_map(input) do
    {kind, command, paths} = request(tool, input, cwd)

    case Factory.RunTools.session_of(token) do
      {:ok, key, nonce} ->
        case Kiro.whereis(key) do
          nil ->
            {:deny, "its session has ended"}

          pid ->
            Kiro.Session.permit(pid, nonce, kind, command, paths, title(tool, command, paths))
        end

      :error ->
        one_off(token, kind, command, paths)
    end
  catch
    :exit, _ -> {:deny, "its session has ended"}
  end

  def decide(_token, _tool, _input, _cwd), do: {:deny, "the request wasn't understood"}

  # As `Factory.Kiro.Ask` answers Kiro: what a chat would ask the person about first is
  # a no, with nobody to ask.
  defp one_off(token, kind, command, paths) do
    case Phoenix.Token.verify(FactoryWeb.Endpoint, @salt, token || "", max_age: @max_age) do
      {:ok, %{allow: allow, workdir: workdir, roots: roots}} ->
        decision =
          Permission.decide(kind, command, paths, %{
            allowed: allow,
            looks: "look" in allow,
            reads_only: "execute" not in allow,
            web: false,
            mcp: false,
            folder: workdir,
            roots: roots
          })

        if decision == :allow,
          do: :allow,
          else: {:deny, "this question may not use #{kind} tools that way"}

      _ ->
        {:deny, "Factory doesn't know who is asking"}
    end
  end

  # pi's own tools as the kinds Factory judges, with the command or the paths named.
  # A tool Factory doesn't know is its own kind, which nothing allows.
  defp request("bash", input, _cwd), do: {"execute", text(input["command"]), []}
  defp request("read", input, cwd), do: {"read", nil, paths(input, cwd)}

  defp request(tool, input, cwd) when tool in ~w(grep find ls),
    do: {"search", nil, paths(input, cwd)}

  defp request(tool, input, cwd) when tool in ~w(edit write), do: {"edit", nil, paths(input, cwd)}
  defp request(tool, _input, _cwd), do: {tool, nil, []}

  # A search without a path looks in the folder pi works in.
  defp paths(input, cwd) do
    case text(input["path"] || input["file_path"]) do
      nil -> [cwd]
      path -> [Path.expand(path, cwd)]
    end
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp title(tool, command, paths),
    do: "#{tool} #{command || Enum.join(paths, ", ")}" |> String.slice(0, 200)
end
