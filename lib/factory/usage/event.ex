defmodule Factory.Usage.Event do
  @moduledoc """
  One call to Kiro. Credits come from Kiro; tokens are estimated from the text sent
  and received, because Kiro doesn't report token counts.
  """
  use Ecto.Schema

  schema "usage_events" do
    belongs_to :run, Factory.Runs.Run
    belongs_to :spec, Factory.Specs.Spec
    belongs_to :agent, Factory.Agents.Agent
    field :source, :string
    field :model, :string
    field :credits, :float, default: 0.0
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :ms, :integer
    field :ok, :boolean, default: true
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
    # When it happened in `Factory.Usage.timezone/0`; filled in by Usage's queries.
    field :local_at, :naive_datetime_usec, virtual: true
  end
end
