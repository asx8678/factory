defmodule Factory.Prefs do
  @moduledoc """
  Things Factory remembers between visits, like the project folder picked last. Each
  is a key and a JSON value.
  """
  use Ecto.Schema
  alias Factory.Repo

  @primary_key {:key, :string, autogenerate: false}
  schema "preferences" do
    field :value, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  @doc "A remembered value, or `default`."
  def get(key, default \\ nil) do
    case Repo.get(__MODULE__, key) do
      %{value: %{"v" => v}} -> v
      _ -> default
    end
  end

  @doc "Remembers a value."
  def put(key, value) do
    now = DateTime.utc_now(:second)

    Repo.insert!(%__MODULE__{key: key, value: %{"v" => value}, inserted_at: now, updated_at: now},
      on_conflict: [set: [value: %{"v" => value}, updated_at: now]],
      conflict_target: :key
    )

    value
  end

  @doc "The project folder picked last, if it's still there."
  def project_dir do
    dir = get("project_dir")
    if is_binary(dir) and File.dir?(dir), do: dir
  end

  def remember_project_dir(dir) when is_binary(dir) and dir != "",
    do: put("project_dir", Path.expand(dir))

  def remember_project_dir(_dir), do: nil
end
