defmodule FactoryWeb.Usage do
  @moduledoc """
  Formats a Kiro session's context use for display. Credits and tokens are formatted
  by `FactoryWeb.UsageMeter`.
  """
  import FactoryWeb.UsageMeter, only: [tokens: 1]

  def pct(nil), do: "0%"
  def pct(p) when p < 10, do: "#{:erlang.float_to_binary(p / 1, decimals: 1)}%"
  def pct(p), do: "#{round(p)}%"

  @doc ~s{"19k of ≈1M tokens (1.9%)", or just the percentage when the window is unknown.}
  def context(%{"context_pct" => pct} = u) when is_number(pct) do
    base =
      case u["window"] do
        nil -> "#{pct(pct)} of context"
        window -> "#{tokens(u["context_tokens"])} of ≈#{tokens(window)} tokens (#{pct(pct)})"
      end

    # The first reply after compacting shows how big the context was before.
    if is_number(u["compacted_from"]),
      do: base <> ", compacted from #{pct(u["compacted_from"])}",
      else: base
  end

  def context(%{"compacted_from" => from}) when is_number(from),
    do: "compacted from #{pct(from)}, new size after the next reply"

  def context(_), do: nil

  @doc "Context use at which a Kiro session compacts before its next message (`Factory.Context`)."
  def compact_at, do: Factory.Context.config(:compact_at)

  @doc "Context percentages where severity becomes mid or high, for meters and graph data."
  def thresholds do
    high = compact_at()
    %{mid: high * 0.6, high: high}
  end

  @doc ~s{How full a context is: "low", "mid" (from 60% of the way to compacting) or "high" (compacts next).}
  def level(pct) when is_number(pct) do
    thresholds = thresholds()

    cond do
      pct >= thresholds.high -> "high"
      pct >= thresholds.mid -> "mid"
      true -> "low"
    end
  end

  def level(_), do: nil
end
