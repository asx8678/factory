defmodule Factory.Runs.Messages do
  @moduledoc """
  Reads of a run's chat messages for the chat page (`FactoryWeb.ChatLive`): a page of
  its history, the messages on screen read again, a tool's open question, and the
  planner's latest reply.
  """
  import Ecto.Query, only: [from: 2]
  alias Factory.Repo
  alias Factory.Runs.Message

  @doc """
  The newest `limit` messages of a run, oldest first, and whether there are earlier
  ones: `{messages, earlier?}`. Options: `agent:` keeps only the messages sent to that
  agent or written by it; `before:` pages back from that message id.
  """
  def page_messages(run_id, limit, opts \\ []) do
    query = from m in Message, where: m.run_id == ^run_id

    query =
      case opts[:agent] do
        nil ->
          query

        agent ->
          id = to_string(agent.id)

          from m in query,
            where:
              fragment("?->>'agent_id'", m.meta) == ^id or
                fragment("?->>'to_agent_id'", m.meta) == ^id
      end

    query =
      case opts[:before] do
        nil -> query
        before_id -> from m in query, where: m.id < ^before_id
      end

    messages = Repo.all(from m in query, order_by: [desc: m.id], limit: ^(limit + 1))
    {messages |> Enum.take(limit) |> Enum.reverse(), length(messages) > limit}
  end

  @doc "The messages with these ids, oldest first."
  def messages_by_ids([]), do: []

  def messages_by_ids(ids),
    do: Repo.all(from m in Message, where: m.id in ^ids, order_by: m.id)

  @doc "One message by id, or nil (an id that isn't a number is nil too)."
  def get_message(id) when is_integer(id), do: Repo.get(Message, id)

  def get_message(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> get_message(n)
      _ -> nil
    end
  end

  def get_message(_id), do: nil

  @doc """
  The fields of the question a tool asked mid-turn (`Factory.Kiro.Session`), by the
  question's key: its JSON schema's `properties`, or an empty map when it isn't there.
  """
  def elicitation_schema(run_id, key) do
    # The schema comes from another MCP server as it wrote it, so anything odd is none.
    case Repo.one(
           from m in Message,
             where: m.run_id == ^run_id and fragment("?->'elicitation'->>'key'", m.meta) == ^key,
             limit: 1
         ) do
      %Message{meta: %{"elicitation" => %{"schema" => %{"properties" => %{} = props}}}} -> props
      _ -> %{}
    end
  end

  @doc "The latest message an agent wrote in a run (the planner's, for its scope check), or nil."
  def latest_planner_message(run_id, planner_id) do
    Repo.one(
      from m in Message,
        where:
          m.run_id == ^run_id and not is_nil(m.author) and
            fragment("?->>'agent_id'", m.meta) == ^to_string(planner_id),
        order_by: [desc: m.id],
        limit: 1
    )
  end
end
