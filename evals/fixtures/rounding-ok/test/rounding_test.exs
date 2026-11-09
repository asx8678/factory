defmodule RoundingTest do
  use ExUnit.Case
  test "whole amounts" do
    assert Rounding.to_cents(2.0) == 200
  end

  test "rounds half up" do
    assert Rounding.to_cents(1.005 + 0.001) == 101
  end
end
