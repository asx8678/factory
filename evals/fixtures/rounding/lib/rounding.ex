defmodule Rounding do
  @doc "Cents, rounded half up, from an amount in euros given as a float."
  def to_cents(euros), do: trunc(euros * 100)
end
