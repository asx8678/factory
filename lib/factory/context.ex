defmodule Factory.Context do
  @moduledoc """
  Keeps what agents are sent within bounds, deterministically: the same input always
  gives byte-for-byte the same text, with no model in the loop. The algorithm is
  pi-fabric's compaction (`docs/compaction.md` there), fitted to Factory:

    * `compact/2` - a Kiro session's conversation, when its context fills up
      (`Factory.Kiro.Session`). Its bounded recent log is the source of truth; every
      compaction is rebuilt from it, never from an earlier summary, so summaries
      don't drift. The latest messages stay word for word within
      `keep_recent_tokens`; everything before them becomes bounded sections (recent
      dialogue, earlier messages, files, failures, earlier turns, status, transcript).
    * `fit/2` - a run step's prompt (`Factory.Engine`): the job, spec, hand-offs and
      sources share a byte budget, each shortened with an explicit "[omitted N UTF-8
      bytes]" marker rather than silently.

  Settings (`config :factory, :context`): `compact_at` (context use, in percent, that
  compacts a session before its next message; kept below Kiro's own 80% summarizer),
  `keep_recent_tokens`, `run_prompt_bytes`, `max_log_entries`, and `max_log_bytes`.
  """
  alias Factory.Context.{Bounds, Projections, Render}

  @defaults [
    compact_at: 70,
    keep_recent_tokens: 20_000,
    run_prompt_bytes: 256 * 1024,
    max_log_entries: 2000,
    max_log_bytes: 4 * 1024 * 1024
  ]

  def config(key) do
    :factory |> Application.get_env(:context, []) |> Keyword.get(key, @defaults[key])
  end

  @doc "Estimated tokens in `text` (as `Factory.Usage` counts them)."
  def tokens(text), do: Factory.Usage.estimate_tokens(text)

  @doc "SHA-256 of `text`, in lowercase hex."
  def sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @doc """
  Compacts a conversation log (events as `Factory.Context.Projections` describes them,
  oldest first, each with an `:at` timestamp). Options:

    * `:keep_recent_tokens` - the most the word-for-word tail may take
    * `:tokens_before` - how big the context is now, when known; a result that
      wouldn't be smaller than 95% of it is refused
    * `:omitted_entries` - older log entries dropped by the session's retention limit

  Returns `{:ok, %{text:, tokens:, sha256:, summarized:, kept:, cut:, omitted:}}`, or
  `{:error, :empty}` / `{:error, :no_gain}`.
  """
  def compact(events, opts \\ []) do
    budget = opts[:keep_recent_tokens] || config(:keep_recent_tokens)

    if events == [] do
      {:error, :empty}
    else
      cut = cut(events, budget)
      {summarized, tail} = Enum.split(events, cut)
      {summary, omitted} = summary(summarized, tail)
      dropped = opts[:omitted_entries] || 0
      omitted = if dropped > 0, do: Map.put(omitted, :log_entries, dropped), else: omitted
      text = wrap(summary, render_tail(tail), dropped)
      tokens = tokens(text)
      before = opts[:tokens_before]

      if before && tokens >= before * 0.95 do
        {:error, :no_gain}
      else
        {:ok,
         %{
           text: text,
           tokens: tokens,
           sha256: sha256(text),
           summarized: length(summarized),
           kept: length(tail),
           cut: List.first(tail, %{id: nil}).id,
           omitted: omitted
         }}
      end
    end
  end

  # The earliest message or reply from which the rest fits the budget: the largest tail
  # that fits. When even the last reply is too big, everything is summarized.
  defp cut(events, budget) do
    count = length(events)

    sizes =
      events
      |> Enum.with_index()
      |> Enum.map(fn {event, i} ->
        separator = if i < count - 1, do: "\n\n", else: ""
        {event.kind, i, String.length(tail_entry(event) <> separator)}
      end)

    {cut, _} =
      sizes
      |> Enum.reverse()
      |> Enum.reduce_while({count, 0}, fn {kind, i, size}, {cut, chars} ->
        chars = chars + size

        if div(chars + 3, 4) <= budget,
          do: {:cont, {if(kind in [:user, :assistant], do: i, else: cut), chars}},
          else: {:halt, {cut, chars}}
      end)

    cut
  end

  defp summary([], _tail), do: {"", %{}}

  defp summary(summarized, tail) do
    %{sections: sections, omitted: omitted} = Projections.project(summarized, tail)
    last = List.last(summarized)

    {text, dialogue_bytes} =
      Render.render(sections, range: {hd(summarized).id, last.id}, at: last[:at])

    {text, Map.put(omitted, :dialogue_bytes, dialogue_bytes)}
  end

  defp render_tail(events), do: Enum.map_join(events, "\n\n", &tail_entry/1)

  defp tail_entry(%{kind: :user} = e), do: "[entry #{e.id}] Message to #{e.who}:\n#{e.text}"
  defp tail_entry(%{kind: :assistant} = e), do: "[entry #{e.id}] Reply from #{e.who}:\n#{e.text}"

  defp tail_entry(%{kind: :tool} = e) do
    target = if e.paths != [], do: Enum.join(e.paths, ", "), else: e.title
    "[entry #{e.id}] #{e.who} used #{e.tool}: #{Bounds.truncate(target, 200)} → #{e.outcome}"
  end

  defp tail_entry(%{kind: :error} = e), do: "[entry #{e.id}] #{e.who}'s turn failed: #{e.text}"

  defp wrap(summary, tail, dropped) do
    [
      "<conversation-so-far>",
      "Factory compacted the earlier part of this conversation to save room: a summary " <>
        "built by fixed rules, then the latest messages word for word. Newer messages " <>
        "take precedence over the summary; earlier replies are not verified outcomes.",
      dropped > 0 &&
        "[omitted #{dropped} older log entries due to the session retention limit]",
      summary != "" && "<summary>\n#{String.trim_trailing(summary)}\n</summary>",
      tail != "" && "<recent>\n#{tail}\n</recent>",
      "</conversation-so-far>"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Fits a prompt's parts into `max_bytes` (default `run_prompt_bytes`), joined by blank
  lines. A part is a string, kept whole, or `%{head:, body:, tail:, max:}`, whose body
  is shortened to its `max` bytes (head and tail included). When the whole is still too
  long, the room left is shared fairly: smallest bodies first, each taking at most an
  equal share of what remains, so short parts stay whole and only the big ones are
  shortened. Returns
  `%{text:, parts:, bytes:, tokens:, sha256:, omitted_bytes:}`, where `parts` are the
  fitted parts in order (`text` is them joined).
  """
  def fit(parts, max_bytes \\ nil) do
    max_bytes = max_bytes || config(:run_prompt_bytes)
    parts = Enum.map(parts, &capped/1)
    separators = 2 * max(length(parts) - 1, 0)

    fixed =
      parts
      |> Enum.map(fn p -> if is_binary(p), do: byte_size(p), else: frame(p) end)
      |> Enum.sum()

    shares = shares(parts, max(max_bytes - separators - fixed, 0))

    {texts, omitted} =
      parts
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn
        {text, _i}, omitted when is_binary(text) ->
          {text, omitted}

        {part, i}, omitted ->
          {body, more} = Bounds.excerpt(part.body, shares[i])
          {part.head <> body <> part.tail, omitted + more}
      end)

    text = Enum.join(texts, "\n\n")

    %{
      text: text,
      parts: texts,
      bytes: byte_size(text),
      tokens: tokens(text),
      sha256: sha256(text),
      omitted_bytes: omitted
    }
  end

  # Bytes each body may keep, by part index: smallest first, each at most an equal
  # share of the room left (ties in part order).
  defp shares(parts, room) do
    bodies =
      for {part, i} <- Enum.with_index(parts), is_map(part), do: {part.body_budget, i}

    count = length(bodies)

    {shares, _} =
      bodies
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.map_reduce(room, fn {{size, i}, n}, room ->
        give = min(size, div(room, count - n))
        {{i, give}, room - give}
      end)

    Map.new(shares)
  end

  defp capped(text) when is_binary(text), do: text

  defp capped(%{body: body, max: max} = part) do
    Map.merge(part, %{
      head: part[:head] || "",
      tail: part[:tail] || "",
      body_budget: min(byte_size(body), max(max - frame(part), 0))
    })
  end

  defp frame(part), do: byte_size(part[:head] || "") + byte_size(part[:tail] || "")
end
