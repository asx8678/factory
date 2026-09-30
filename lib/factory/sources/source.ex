defmodule Factory.Sources.Source do
  @moduledoc """
  A data source of a workflow. What `config` holds depends on the kind:

    * `azure_devops` - `org`, `project`, `repo`, `branch` (optional), `pat_env`
      (optional: the name of an environment variable holding a personal access token)
    * `git` - `url`, `branch` (optional)
    * `folder` - `path`
    * `instructions` - `path` (optional; else the text is in `content`)
    * `pageindex` - `path` to a PageIndex tree (JSON), `document` (optional: the
      document it indexes, e.g. the PDF). See `Factory.Sources.PageIndex`.
    * `meta_index` - `path` to the index file (optional; else it's in `content`) and
      `root` (optional: the folder the index's paths are relative to)

  Repositories are cloned into a local folder (`Factory.Sources.local_path/1`);
  `status` is "ready", "syncing" or "error".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(azure_devops git folder instructions meta_index pageindex)

  schema "data_sources" do
    belongs_to :workflow, Factory.Agents.Workflow
    field :kind, :string
    field :name, :string
    field :config, :map, default: %{}
    field :content, :string, default: ""
    field :enabled, :boolean, default: true
    field :status, :string, default: "ready"
    field :error, :string
    field :synced_at, :utc_datetime
    # Where its card sits on the canvas.
    field :x, :float, default: 0.0
    field :y, :float, default: 0.0
    has_many :links, Factory.Sources.Link
    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:workflow_id, :kind, :name, :config, :content, :enabled, :x, :y])
    |> update_change(:name, &String.trim/1)
    |> update_change(:content, &(&1 || ""))
    |> validate_required([:workflow_id, :kind, :name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, max: 80)
    |> validate_length(:content, max: 200_000)
    |> validate_config()
  end

  def status_changeset(source, attrs),
    do: cast(source, attrs, [:status, :error, :synced_at])

  # Errors go on :config with the config key in `field:`, so the form can show them
  # next to the right input.
  defp validate_config(changeset) do
    config = get_field(changeset, :config) || %{}
    content = get_field(changeset, :content) || ""

    changeset
    |> get_field(:kind)
    |> config_errors(config, content)
    |> Enum.reduce(changeset, fn {key, msg}, cs ->
      add_error(cs, :config, msg, field: key)
    end)
  end

  defp config_errors("azure_devops", config, _),
    do: for(key <- ~w(org project repo), blank?(config[key]), do: {key, "is required"})

  defp config_errors("git", config, _) do
    cond do
      blank?(config["url"]) ->
        [{"url", "is required"}]

      not Regex.match?(~r{^(https?://|git@|ssh://|file://)}, config["url"]) ->
        [{"url", "must be an https, ssh, git@ or file:// URL"}]

      true ->
        []
    end
  end

  defp config_errors("folder", config, _) do
    cond do
      blank?(config["path"]) -> [{"path", "is required"}]
      not File.dir?(Path.expand(config["path"])) -> [{"path", "isn't a folder on this machine"}]
      true -> []
    end
  end

  defp config_errors(kind, config, content) when kind in ["instructions", "meta_index"] do
    cond do
      not blank?(config["path"]) and not File.regular?(Path.expand(config["path"])) ->
        [{"path", "isn't a file on this machine"}]

      blank?(config["path"]) and String.trim(content) == "" ->
        [{"content", "write, paste or upload it, or give a file path"}]

      not blank?(config["root"]) and not File.dir?(Path.expand(config["root"])) ->
        [{"root", "isn't a folder on this machine"}]

      true ->
        []
    end
  end

  defp config_errors("pageindex", config, _) do
    cond do
      blank?(config["path"]) ->
        [{"path", "is required"}]

      not File.regular?(Path.expand(config["path"])) ->
        [{"path", "isn't a file on this machine"}]

      true ->
        # Read once: a tree can be large.
        case Factory.Sources.PageIndex.load(config["path"]) do
          {:error, why} ->
            [{"path", why}]

          {:ok, _tree} ->
            if not blank?(config["document"]) and
                 not File.regular?(Path.expand(config["document"])),
               do: [{"document", "isn't a file on this machine"}],
               else: []
        end
    end
  end

  defp config_errors(_kind, _config, _content), do: []

  defp blank?(v), do: String.trim(to_string(v || "")) == ""
end
