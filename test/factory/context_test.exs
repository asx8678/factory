defmodule Factory.ContextTest do
  use ExUnit.Case, async: true
  alias Factory.Context
  alias Factory.Context.Bounds

  # A Kiro session's log: each turn a message, a read and an edit, and a reply.
  # Every `big`-th reply is long; every `denied`-th edit is denied.
  defp log(turns, opts \\ []) do
    big = opts[:big] || 5
    denied = opts[:denied] || 7
    long = String.duplicate("A line of notes about the invoices page.\n", 400)

    Enum.flat_map(1..turns, fn n ->
      id = fn k -> "e#{4 * n + k}" end
      at = "2026-09-28T10:00:#{String.pad_leading("#{rem(n, 60)}", 2, "0")}Z"
      path = "/proj/lib/app/mod_#{n}.ex"

      [
        %{
          kind: :user,
          id: id.(0),
          at: at,
          who: "Coder",
          text: "Request #{n}: change mod_#{n}\nDetails."
        },
        %{
          kind: :tool,
          id: id.(1),
          at: at,
          who: "Coder",
          tool: "read",
          title: "Read",
          paths: [path],
          outcome: "ok"
        },
        %{
          kind: :tool,
          id: id.(2),
          at: at,
          who: "Coder",
          tool: "edit",
          title: "Edit",
          paths: [path],
          outcome: if(rem(n, denied) == 0, do: "denied", else: "ok")
        },
        %{
          kind: :assistant,
          id: id.(3),
          at: at,
          who: "Coder",
          text: "Done #{n}.\n" <> if(rem(n, big) == 0, do: long, else: "")
        }
      ]
    end)
  end

  defp summary(text) do
    case Regex.run(~r/<summary>\n(.*)\n<\/summary>/s, text) do
      [_, summary] -> summary
      nil -> ""
    end
  end

  test "the same log compacts to the same bytes" do
    events = log(40)
    assert {:ok, a} = Context.compact(events, keep_recent_tokens: 6000)
    assert {:ok, b} = Context.compact(Enum.map(events, &Map.new(&1)), keep_recent_tokens: 6000)
    assert a.text == b.text
    assert a.sha256 == b.sha256
  end

  test "the latest entries stay word for word within the tail budget" do
    events = log(40)
    assert {:ok, c} = Context.compact(events, keep_recent_tokens: 6000)
    assert c.summarized + c.kept == length(events)
    assert c.kept > 0
    [_, recent] = String.split(c.text, "<recent>\n")
    assert Context.tokens(recent) <= 6000 + 20

    for e <- Enum.take(events, -c.kept), e.kind in [:user, :assistant] do
      assert recent =~ e.text
    end

    # The tail starts at a message or a reply, never a tool.
    assert %{kind: kind} = Enum.find(events, &(&1.id == c.cut))
    assert kind in [:user, :assistant]
  end

  test "a reply too big for the tail budget means everything is summarized" do
    events = log(10, big: 10)
    assert {:ok, c} = Context.compact(events, keep_recent_tokens: 1000)
    assert c.kept == 0
    refute c.text =~ "<recent>"
    assert summary(c.text) =~ "Message to Coder [entry e40]"
  end

  test "the summary stays within 32 KiB however long the conversation" do
    events = log(600, big: 2)
    assert {:ok, c} = Context.compact(events, keep_recent_tokens: 2000)
    assert byte_size(summary(c.text)) <= 32 * 1024
    assert summary(c.text) =~ "… omitted"
    assert summary(c.text) =~ "cumulative source entries e4 → "
  end

  test "sections come from the log's structure: files, failures, turns, status" do
    events = log(8)
    assert {:ok, c} = Context.compact(events, keep_recent_tokens: 0)
    s = summary(c.text)

    assert s =~ "[Recent messages and replies]"
    assert s =~ "Earlier reply from Coder (not a verified outcome) [entry e31]:"
    assert s =~ "[Files]\n(under /proj/lib/app/)\nModified:\n  mod_1.ex [entry e6]"
    # Only mod_7 was read and not changed: its edit was denied.
    assert s =~ "Read:\n  mod_7.ex [entry e29]"
    assert s =~ "[Failures]\n- edit /proj/lib/app/mod_7.ex: denied (Coder) [entry e30]"
    assert s =~ ~s{"Request 1: change mod_1" → Coder | read:1 edit:1 [entry e4]}
    assert s =~ "Last message: Request 8: change mod_8 (to Coder)"
  end

  test "a failure counts as resolved once the same tool works on the same file" do
    events =
      log(7) ++
        [
          %{
            kind: :tool,
            id: "e99",
            at: nil,
            who: "Coder",
            tool: "edit",
            title: "Edit",
            paths: ["/proj/lib/app/mod_7.ex"],
            outcome: "ok"
          }
        ]

    assert {:ok, c} = Context.compact(events, keep_recent_tokens: 0)
    assert summary(c.text) =~ "mod_7.ex: denied (Coder) [RESOLVED] [entry e30]"
  end

  test "compacting that wouldn't make the context smaller is refused" do
    assert {:error, :no_gain} = Context.compact(log(3), tokens_before: 50)
    assert {:error, :empty} = Context.compact([])
  end

  describe "fit/2" do
    test "parts that fit are joined unchanged" do
      parts = [
        "Intro",
        %{head: "<spec>\n", body: "The spec.", tail: "\n</spec>", max: 1000},
        "End"
      ]

      assert %{text: "Intro\n\n<spec>\nThe spec.\n</spec>\n\nEnd", omitted_bytes: 0} =
               Context.fit(parts, 10_000)
    end

    test "too much is shortened in proportion, keeping tags and fixed lines whole" do
      spec = String.duplicate("s", 6000)
      handoff = String.duplicate("h", 2000)

      result =
        Context.fit(
          [
            "Intro",
            %{head: "<spec>\n", body: spec, tail: "\n</spec>", max: 100_000},
            %{head: "<handoff>\n", body: handoff, tail: "\n</handoff>", max: 100_000},
            "End"
          ],
          4000
        )

      assert result.bytes <= 4000
      assert result.omitted_bytes > 0
      assert result.text =~ ~r/\AIntro\n\n<spec>\ns+\n\[omitted \d+ UTF-8 bytes\]\n<\/spec>/
      assert result.text =~ ~r/<handoff>\nh+\n\[omitted \d+ UTF-8 bytes\]\n<\/handoff>\n\nEnd\z/
      assert result.sha256 == Context.fit([result.text], 4000).sha256
    end

    test "a part's own ceiling applies even when there's room" do
      result =
        Context.fit([%{head: "", body: String.duplicate("x", 500), tail: "", max: 200}], 10_000)

      assert result.bytes <= 200
      assert result.text =~ "[omitted"
    end
  end

  test "clipping never splits a character" do
    # "é" takes two bytes: two bytes can't hold "hé", so only "h" fits.
    assert Bounds.clip("héllo wörld", 2, "") == "h"
    assert Bounds.clip("héllo wörld", 3, "") == "hé"
    assert Bounds.clip("héllo wörld", 5, "…") == "h…"
    assert String.valid?(Bounds.clip(String.duplicate("żółw ", 50), 101))
  end
end
