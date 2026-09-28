defmodule Factory.Context.Dialogue do
  @moduledoc """
  The protected recent dialogue of a compacted conversation, ported from pi-fabric
  (`src/compaction/dialogue.ts`): the last three user messages from the summarized
  part, each with the agent reply that came before it, kept whole when they fit.

  Recency counts user messages, not tool calls. A message wholly in the word-for-word
  tail takes no slot; one whose preceding reply was summarized still gets its reply
  kept here, with the message itself marked "retained raw".
  """
  alias Factory.Context.Bounds

  @max_exchanges 3
  # Three exchanges plus the section heading fit the 12 KiB section.
  @max_exchange_bytes 3968

  @doc "The exchanges to keep: `[%{user: msg, assistant: msg | nil}]`, oldest first."
  def recent(events, tail \\ []) do
    {exchanges, _} =
      Enum.reduce(
        Enum.map(events, &{&1, false}) ++ Enum.map(tail, &{&1, true}),
        {[], nil},
        fn
          {%{kind: :assistant, text: text} = e, retained}, {acc, last} ->
            if String.trim(text) == "",
              do: {acc, last},
              else: {acc, %{id: e.id, who: e.who, text: text, retained: retained}}

          {%{kind: :user} = e, retained}, {acc, last} ->
            acc =
              if not retained or (last != nil and not last.retained) do
                user = %{id: e.id, who: e.who, text: e.text, retained: retained}
                Enum.take(acc ++ [%{user: user, assistant: last}], -@max_exchanges)
              else
                acc
              end

            {acc, nil}

          _other, state ->
            state
        end
      )

    exchanges
  end

  @doc "Each exchange as text (the reply first, then the message), and bytes left out."
  def project(exchanges) do
    Enum.map_reduce(exchanges, 0, fn exchange, omitted ->
      {parts, more} = excerpts(exchange)

      {Enum.map_join(parts, "\n\n", fn {heading, text} -> heading <> "\n" <> text end),
       omitted + more}
    end)
  end

  defp excerpts(%{user: user, assistant: assistant}) do
    user_heading = heading("Message to #{user.who}", user)

    reply_heading =
      assistant &&
        heading("Earlier reply from #{assistant.who} (not a verified outcome)", assistant)

    available = max(@max_exchange_bytes - byte_size(user_heading <> (reply_heading || "")) - 8, 0)
    user_text = if user.retained, do: "", else: user.text
    reply_bytes = if assistant && not assistant.retained, do: byte_size(assistant.text), else: 0

    # At least half for the person's own words; a short message leaves the rest for the reply.
    user_budget =
      if assistant, do: max(div(available, 2), available - reply_bytes), else: available

    {user_part, user_omitted} = Bounds.excerpt(user_text, user_budget)

    if assistant do
      reply_text = if assistant.retained, do: "", else: assistant.text
      {reply_part, reply_omitted} = Bounds.excerpt(reply_text, available - byte_size(user_part))

      {[{reply_heading, reply_part}, {user_heading, user_part}], user_omitted + reply_omitted}
    else
      {[{user_heading, user_part}], user_omitted}
    end
  end

  defp heading(role, msg),
    do: "#{role} [entry #{msg.id}#{if msg.retained, do: "; retained raw"}]:"
end
