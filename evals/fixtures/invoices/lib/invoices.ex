defmodule Invoices do
  @moduledoc "Invoices: %{number: string, lines: [%{name: string, qty: integer, price: integer}]}, in cents."
  def render(invoice) do
    lines = Enum.map_join(invoice.lines, "\n", &"#{&1.name} x#{&1.qty}")
    "Invoice #{invoice.number}\n#{lines}"
  end
end
