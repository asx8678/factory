defmodule Factory.Kiro.Shell do
  @moduledoc """
  Reads a shell command the way the shell will, for `Factory.Kiro.Permission`: quotes and
  backslashes taken out of each word, pipes and `;` found only where they really are.
  `ls \\\\| rm x` is two commands, `find . "-delete"` has the word `-delete`, and
  `grep "a|b" f` is one command.

  It doesn't run anything or expand anything. What it can't be sure of is `:error`, and
  the caller refuses that: a here-document, a subshell, unbalanced quotes.

  A command is `%{words: [word], redirects: [redirect]}`. A word is
  `%{text:, substitution:, variable:, glob:, brace:, tilde:}`: `text` with its quoting
  gone, and flags for what the shell would expand in it (only what wasn't quoted away).
  A redirect is `%{op:, target:}`, `target` a word's text, or nil when it's a copy of
  another stream (`2>&1`).
  """

  @doc "The commands in `text`: `{:ok, [command]}` or `:error`."
  def parse(text) when is_binary(text) do
    case scan(text, new(), %{word: nil, words: [], redirects: []}) do
      {:ok, commands} -> {:ok, Enum.reject(commands, &(&1.words == [] and &1.redirects == []))}
      :error -> :error
    end
  end

  defp new, do: []

  defp word,
    do: %{text: "", substitution: false, variable: false, glob: false, brace: false, tilde: false}

  # End of the text.
  defp scan("", done, cur), do: {:ok, Enum.reverse([close(cur) | done])}

  # A backslash and a newline join two lines.
  defp scan(<<?\\, ?\n, rest::binary>>, done, cur), do: scan(rest, done, cur)

  defp scan(<<?\\, c::utf8, rest::binary>>, done, cur),
    do: scan(rest, done, add(cur, <<c::utf8>>))

  defp scan(<<?\\>>, _done, _cur), do: :error

  defp scan(<<?', rest::binary>>, done, cur) do
    case String.split(rest, "'", parts: 2) do
      [quoted, rest] -> scan(rest, done, add(cur, quoted))
      _ -> :error
    end
  end

  defp scan(<<?", rest::binary>>, done, cur) do
    with {:ok, cur, rest} <- double(rest, ensure(cur)), do: scan(rest, done, cur)
  end

  defp scan(<<?`, _::binary>> = rest, done, cur) do
    <<_, after_it::binary>> = rest
    scan(after_it, done, flag(cur, :substitution))
  end

  defp scan(<<"$(", rest::binary>>, done, cur), do: scan(rest, done, flag(cur, :substitution))
  defp scan(<<"<(", _::binary>>, _done, _cur), do: :error
  defp scan(<<">(", _::binary>>, _done, _cur), do: :error
  defp scan(<<"<<", _::binary>>, _done, _cur), do: :error

  # `$'…'` spells anything; `$"…"` is a plain string, but nobody needs it here.
  defp scan(<<?$, q, rest::binary>>, done, cur) when q in [?', ?"],
    do: scan(rest, done, cur |> flag(:variable) |> add(<<q>>))

  defp scan(<<?$, c, rest::binary>>, done, cur)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c == ?{ or c in ?0..?9,
       do: scan(rest, done, cur |> flag(:variable) |> add(<<?$, c>>))

  defp scan(<<c, _::binary>> = text, done, cur) when c in [?\s, ?\t] do
    <<_, rest::binary>> = text
    scan(rest, done, end_word(cur))
  end

  # A comment: `#` where a word would start, to the end of the line.
  defp scan(<<?#, rest::binary>>, done, %{word: nil} = cur) do
    case String.split(rest, "\n", parts: 2) do
      [_comment, after_it] -> scan("\n" <> after_it, done, cur)
      [_comment] -> scan("", done, cur)
    end
  end

  defp scan(<<"&&", rest::binary>>, done, cur), do: next_command(rest, done, cur)
  defp scan(<<"||", rest::binary>>, done, cur), do: next_command(rest, done, cur)
  defp scan(<<"|&", rest::binary>>, done, cur), do: next_command(rest, done, cur)
  defp scan(<<"&>>", rest::binary>>, done, cur), do: redirect(rest, done, end_word(cur), "&>>")
  defp scan(<<"&>", rest::binary>>, done, cur), do: redirect(rest, done, end_word(cur), "&>")

  defp scan(<<c, rest::binary>>, done, cur) when c in [?;, ?&, ?|, ?\n],
    do: next_command(rest, done, cur)

  defp scan(<<c, _::binary>>, _done, _cur) when c in [?(, ?)], do: :error

  defp scan(<<">", _::binary>> = text, done, cur) do
    {op, rest} = out_op(text)
    redirect(rest, done, drop_fd(cur), op)
  end

  defp scan(<<"<", rest::binary>>, done, cur), do: redirect(rest, done, drop_fd(cur), "<")

  defp scan(<<c, rest::binary>>, done, cur) when c in [?*, ??, ?[],
    do: scan(rest, done, cur |> flag(:glob) |> add(<<c>>))

  defp scan(<<?{, rest::binary>>, done, cur),
    do: scan(rest, done, cur |> flag(:brace) |> add("{"))

  defp scan(<<?~, rest::binary>>, done, %{word: nil} = cur),
    do: scan(rest, done, cur |> flag(:tilde) |> add("~"))

  defp scan(<<c::utf8, rest::binary>>, done, cur), do: scan(rest, done, add(cur, <<c::utf8>>))
  defp scan(_invalid, _done, _cur), do: :error

  # Inside double quotes: only `$`, backticks and `\` still mean something.
  defp double("", _cur), do: :error
  defp double(<<?", rest::binary>>, cur), do: {:ok, cur, rest}

  defp double(<<?\\, c, rest::binary>>, cur) when c in [?$, ?`, ?", ?\\],
    do: double(rest, add(cur, <<c>>))

  defp double(<<?\\, ?\n, rest::binary>>, cur), do: double(rest, cur)
  defp double(<<"$(", rest::binary>>, cur), do: double(rest, flag(cur, :substitution))
  defp double(<<?`, rest::binary>>, cur), do: double(rest, flag(cur, :substitution))

  defp double(<<?$, c, rest::binary>>, cur)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c == ?{ or c in ?0..?9,
       do: double(rest, cur |> flag(:variable) |> add(<<?$, c>>))

  defp double(<<c::utf8, rest::binary>>, cur), do: double(rest, add(cur, <<c::utf8>>))
  defp double(_invalid, _cur), do: :error

  defp out_op(<<">>", rest::binary>>), do: {">>", rest}
  defp out_op(<<">&", rest::binary>>), do: {">&", rest}
  defp out_op(<<">|", rest::binary>>), do: {">", rest}
  defp out_op(<<">", rest::binary>>), do: {">", rest}

  # What a redirect goes to: the next word, read with the same rules on its own.
  defp redirect(rest, done, cur, op) do
    rest = String.trim_leading(rest, " ")

    case target(rest, "") do
      {:ok, text, rest} ->
        scan(rest, done, %{cur | redirects: [%{op: op, target: text} | cur.redirects]})

      :error ->
        :error
    end
  end

  # A redirect's target as plain text. Anything fancy in it (quotes, `$`) isn't something
  # that only looks, so it's left in for the caller to refuse.
  defp target("", acc) when acc != "", do: {:ok, acc, ""}
  defp target("", _acc), do: :error

  defp target(<<c, _::binary>> = rest, acc) when c in [?\s, ?\t, ?\n, ?;, ?|, ?&, ?(, ?)] do
    # `2>&1` has the `&` in its operator, so one here ends the target.
    if acc == "", do: :error, else: {:ok, acc, rest}
  end

  defp target(<<c::utf8, rest::binary>>, acc), do: target(rest, acc <> <<c::utf8>>)
  defp target(_invalid, _acc), do: :error

  # A word made only of digits right before `>` is the stream's number, not an argument.
  defp drop_fd(%{word: %{text: text}} = cur) do
    if Regex.match?(~r/^\d+$/, text), do: %{cur | word: nil}, else: end_word(cur)
  end

  defp drop_fd(cur), do: cur

  defp next_command(rest, done, cur),
    do: scan(rest, [close(cur) | done], %{word: nil, words: [], redirects: []})

  defp close(cur) do
    cur = end_word(cur)
    %{words: Enum.reverse(cur.words), redirects: Enum.reverse(cur.redirects)}
  end

  defp end_word(%{word: nil} = cur), do: cur
  defp end_word(%{word: w} = cur), do: %{cur | word: nil, words: [w | cur.words]}

  defp ensure(%{word: nil} = cur), do: %{cur | word: word()}
  defp ensure(cur), do: cur

  defp add(cur, text) do
    cur = ensure(cur)
    %{cur | word: %{cur.word | text: cur.word.text <> text}}
  end

  defp flag(cur, name) do
    cur = ensure(cur)
    %{cur | word: Map.put(cur.word, name, true)}
  end

  @doc """
  A word's spellings after brace expansion, as the shell does it: `{a,b}/c` is `a/c` and
  `b/c`. `nil` when there would be more than 64.
  """
  def expand_braces(text) do
    case Regex.run(~r/\{([^{}]*,[^{}]*)\}/, text, return: :index) do
      nil ->
        [text]

      [{at, len}, {inner_at, inner_len}] ->
        before = binary_part(text, 0, at)
        rest = binary_part(text, at + len, byte_size(text) - at - len)
        inner = binary_part(text, inner_at, inner_len)

        Enum.reduce_while(String.split(inner, ","), [], fn option, acc ->
          case expand_braces(before <> option <> rest) do
            nil -> {:halt, nil}
            more when length(acc) + length(more) > 64 -> {:halt, nil}
            more -> {:cont, Enum.uniq(acc ++ more)}
          end
        end)
    end
  end
end
