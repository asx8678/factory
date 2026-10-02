defmodule Factory.Background do
  @moduledoc """
  Work done in a background task that somebody waits on: a status that says "running",
  a spinner, a chat bubble. Should the work raise, it's logged and comes back as
  `{:error, why}` like any other failure, so what waits always hears how it ended
  instead of staying "running" until a restart.
  """
  require Logger

  @doc "`fun`'s result, or `{:error, why}` when it raised or exited. `what` names it in the log."
  def guard(what, fun) do
    fun.()
  rescue
    e ->
      Logger.error("#{what} failed: " <> Exception.format(:error, e, __STACKTRACE__))

      {:error,
       "Factory hit an error while it worked on this (#{Exception.message(e)}). Try again."}
  catch
    :exit, reason ->
      Logger.error("#{what} failed: #{inspect(reason)}")
      {:error, "Factory hit an error while it worked on this. Try again."}
  end
end
