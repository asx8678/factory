Code.require_file("lib/paginate.ex")
[3, 4] = Paginate.page([1, 2, 3, 4], 2, 2)
[] = Paginate.page([1, 2], 2, 2)
[1] = Paginate.page([1], 1, 5)
