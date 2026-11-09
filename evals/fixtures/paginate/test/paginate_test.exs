defmodule PaginateTest do
  use ExUnit.Case
  test "the first page starts at the first item" do
    assert Paginate.page([1, 2, 3, 4], 1, 2) == [1, 2]
  end
end
