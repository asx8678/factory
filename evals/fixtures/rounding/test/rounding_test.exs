defmodule RoundingTest do
  use ExUnit.Case
  test "whole amounts" do
    assert Rounding.to_cents(2.0) == 200
  end
end
