defmodule Factory.Repo.Migrations.AddTurnDetailsToUsageEvents do
  use Ecto.Migration

  def change do
    alter table(:usage_events) do
      add :stop_reason, :string
      add :tool_calls, :integer
      add :session_ref, :string
      add :error, :text
      # False when a turn was stopped before Kiro said what it cost.
      add :credits_known, :boolean, default: true, null: false
      # How full the context really was, as Kiro reports it. Unlike the estimates in
      # input_tokens and output_tokens, this counts everything the model was sent.
      add :context_tokens, :integer
      add :prompt_sha, :string
    end
  end
end
