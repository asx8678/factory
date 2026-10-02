# Each run's Kiro logs replace the last run's: without this they pile up by the thousand.
File.rm_rf(Application.fetch_env!(:factory, :kiro)[:log_dir])
File.mkdir_p(Application.fetch_env!(:factory, :kiro)[:log_dir])

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Factory.Repo, :manual)
