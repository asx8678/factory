defmodule FactoryWeb.Usage do
  @moduledoc "Formats Kiro usage numbers (credits, tokens, context) for display."

  def credits(nil), do: "0"
  def credits(n) when n >= 10, do: :erlang.float_to_binary(n / 1, decimals: 1)
  def credits(n), do: :erlang.float_to_binary(n / 1, decimals: 2)

  def tokens(nil), do: "?"
  def tokens(n) when n >= 999_500, do: "#{trim(n / 1_000_000)}M"
  def tokens(n) when n >= 1000, do: "#{round(n / 1000)}k"
  def tokens(n), do: "#{n}"

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

  defp trim(x) do
    s = :erlang.float_to_binary(x, decimals: 1)
    String.trim_trailing(s, ".0")
  end
end
