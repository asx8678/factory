Code.require_file("lib/invoices.ex")
i = %{number: "1", lines: [%{name: "a", qty: 2, price: 100}, %{name: "b", qty: 1, price: 50}]}
250 = Invoices.subtotal(i)
25 = Invoices.tax(i, 0.1)
275 = Invoices.total(i, 0.1)
true = Invoices.render(i, 0.1) =~ "275"
