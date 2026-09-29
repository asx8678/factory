# The standard workflows (Build a feature, Fix a bug…) are made on first use, with
# their agents (Factory.Workflows.ensure_standard/0). Run with: mix run priv/repo/seeds.exs
Factory.Workflows.ensure_standard()

# Example base specs (coding standards, testing, security…) to include in runs.
Factory.Specs.Examples.install()
