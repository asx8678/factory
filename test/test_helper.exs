# Each run's Kiro logs replace the last run's: without this they pile up by the thousand.
File.rm_rf(Application.fetch_env!(:factory, :kiro)[:log_dir])
File.mkdir_p(Application.fetch_env!(:factory, :kiro)[:log_dir])

# Evals cost credits: `mix test --only eval`, see test/eval/eval_test.exs.
ExUnit.start(exclude: [:eval])
Ecto.Adapters.SQL.Sandbox.mode(Factory.Repo, :manual)
