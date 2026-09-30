defmodule Factory.Repo.Migrations.AddReviewLoopsToStandardWorkflows do
  use Ecto.Migration

  # Standard workflows now come with an arrow from the Reviewer back to the agent that
  # builds (Factory.Workflows), so a reviewer can send work back. Give it to the ones
  # already made, where there's exactly one reviewer and one builder to join. Nothing
  # is removed; an arrow that's already there is left as it is.
  def up do
    execute("""
    INSERT INTO links (source_id, target_id, source_handle, target_handle, prompt, inserted_at, updated_at)
    SELECT r.id, c.id, 'right', 'right', '', now(), now()
    FROM workflows w
    JOIN agents r ON r.workflow_id = w.id AND r.kind = 'reviewer'
    JOIN agents c ON c.workflow_id = w.id AND c.kind = 'coder'
    WHERE w.key IS NOT NULL
      AND (SELECT count(*) FROM agents a WHERE a.workflow_id = w.id AND a.kind = 'reviewer') = 1
      AND (SELECT count(*) FROM agents a WHERE a.workflow_id = w.id AND a.kind = 'coder') = 1
    ON CONFLICT (source_id, target_id) DO NOTHING
    """)
  end

  # The arrows can't be told from ones a person drew, so they stay.
  def down, do: :ok
end
