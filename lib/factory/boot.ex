defmodule Factory.Boot do
  @moduledoc """
  What Factory does once at start, before it serves a page (it's started before
  `FactoryWeb.Endpoint`): no page makes the standard workflows while it's viewed, and
  no run is resumed before the ones left over are paused.

  No Kiro session, review or run worker survives a restart: leftover context and
  statuses are cleared, and the runs left queued or running are paused, telling their
  chats (`Factory.Engine.recover/0`). The standard workflows are made, with the prompts
  Factory has now where nobody changed them. Off in tests, where the sandbox owns the
  database (`config :factory, :reset_on_boot`).

  Each step is on its own: one that fails is logged and the others still run. The CLI
  the agents run on (Kiro or pi, as chosen in Settings) is loaded first, so a failure
  later can't put someone who switched to pi back on Kiro.
  """
  require Logger

  def child_spec(_opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :temporary
    }

  @doc "Runs the steps, then lets the supervisor go on (`:ignore`): nothing stays running."
  def start_link do
    if Application.get_env(:factory, :reset_on_boot, true) do
      step(:runtime, &Factory.Runtime.load/0)
      step(:sessions, &Factory.Agents.reset_sessions/0)
      step(:reviews, &Factory.Specs.reset_reviews/0)
      step(:runs, &Factory.Engine.recover/0)
      step(:workflows, &Factory.Workflows.ensure_standard/0)
      step(:prompts, &Factory.Workflows.update_prompts/0)
      step(:current_workflow, &Factory.Workflows.current/0)
      step(:evidence, fn -> Factory.Evidence.sweep() end)
    end

    # The models Kiro offers: the last list at once, then a fresh check, in the background.
    step(:models, &Factory.Kiro.Catalog.load/0)

    if Application.get_env(:factory, :check_kiro_models, true),
      do: step(:model_check, &Factory.Kiro.Catalog.check_later/0)

    :ignore
  end

  defp step(name, fun) do
    fun.()
  rescue
    e ->
      Logger.error(
        "Factory's start (#{name}) failed: " <> Exception.format(:error, e, __STACKTRACE__)
      )
  catch
    kind, reason -> Logger.error("Factory's start (#{name}) failed: #{inspect({kind, reason})}")
  end
end
