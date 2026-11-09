defmodule Paginate do
  @doc "The items of page `page` (from 1), `size` to a page."
  def page(items, page, size), do: items |> Enum.drop(page * size) |> Enum.take(size)
end
