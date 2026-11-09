defmodule InvoicesTest do
  use ExUnit.Case
  test "lists its lines" do
    assert Invoices.render(%{number: "1", lines: [%{name: "a", qty: 2, price: 100}]}) =~ "a x2"
  end
end
