defmodule Factory.Kiro.Permission do
  @moduledoc false

  # ACP permits cancellation when none of the offered options matches the decision.
  def outcome(options, decision) do
    case Enum.find(options, &String.starts_with?(&1["kind"] || "", decision)) do
      %{"optionId" => id} when is_binary(id) -> %{outcome: "selected", optionId: id}
      _ -> %{outcome: "cancelled"}
    end
  end
end
