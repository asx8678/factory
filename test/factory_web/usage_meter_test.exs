defmodule FactoryWeb.UsageMeterTest do
  use ExUnit.Case, async: true
  alias FactoryWeb.UsageMeter

  test "credits keep two decimals under ten, one from ten up" do
    assert UsageMeter.credits(0) == "0.00"
    assert UsageMeter.credits(0.08) == "0.08"
    assert UsageMeter.credits(1.2) == "1.20"
    assert UsageMeter.credits(9.99) == "9.99"
    assert UsageMeter.credits(10) == "10.0"
    assert UsageMeter.credits(12.4) == "12.4"
    assert UsageMeter.credits(125.76) == "125.8"
  end

  test "tokens are rounded to what fits in the header" do
    assert UsageMeter.tokens(0) == "0"
    assert UsageMeter.tokens(840) == "840"
    assert UsageMeter.tokens(999) == "999"
    assert UsageMeter.tokens(1000) == "1.0k"
    assert UsageMeter.tokens(12_400) == "12.4k"
    assert UsageMeter.tokens(100_000) == "100k"
    assert UsageMeter.tokens(310_000) == "310k"
    assert UsageMeter.tokens(1_000_000) == "1.0M"
    assert UsageMeter.tokens(1_260_000) == "1.3M"
  end

  test "the label says what the figure covers" do
    assert UsageMeter.label({:run, 7}) == "This run"
    assert UsageMeter.label({:spec, 7}) == "This spec"
    assert UsageMeter.label(:today) == "Today"
  end
end
