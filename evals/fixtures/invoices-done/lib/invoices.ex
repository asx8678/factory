defmodule Invoices do
  def subtotal(invoice), do: invoice.lines |> Enum.map(&(&1.qty * &1.price)) |> Enum.sum()
end
