defmodule Rounding do
  @doc "Cents, rounded half up, from an amount in euros given as a float."
  def to_cents(euros), do: round(euros * 100)
end
