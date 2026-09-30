defmodule Factory.Evidence do
  @moduledoc """
  Files attached to a troubleshooting run (logs, exports, traces), kept whole in a folder
  of the run's own for its agents to search, rather than put into their prompts, where a
  big one would be cut. The agents that only read may look there without asking
  (`Factory.Kiro.Permission.ask_first/5`); the ones that search the web aren't told
  where it is, and are asked about it like anything outside the project.
  """

  @doc "The folder a run's files are kept in."
  def dir(%{id: id}), do: dir(id)
  def dir(id), do: Path.join(root(), "run-#{id}")

  @doc "The folder every run's files are kept under."
  def root do
    Application.get_env(:factory, :evidence_dir) ||
      Path.join(Path.dirname(Factory.Kiro.config(:workspace)), "evidence")
  end

  @doc """
  Keeps `files` (`[{name, content}]`) for the run, each under a name that's safe as a
  file name and not taken yet. Returns the names they're kept under.
  """
  def save(run, files) do
    folder = dir(run)
    File.mkdir_p!(folder)

    for {name, content} <- files do
      name = unique(folder, safe(name))
      File.write!(Path.join(folder, name), content)
      name
    end
  end

  @doc "The run's files, `[{name, bytes}]` by name."
  def list(run) do
    folder = dir(run)

    case File.ls(folder) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            {:ok, %{size: size, type: :regular}} <- [File.stat(Path.join(folder, name))],
            do: {name, size}

      {:error, _} ->
        []
    end
  end

  @doc "Where the run's files are and how to use them, for its agents; nil with none."
  def describe(run) do
    case list(run) do
      [] ->
        nil

      files ->
        "Files the person attached, kept whole in #{dir(run)}: " <>
          Enum.map_join(files, ", ", fn {name, bytes} -> "#{name} (#{size(bytes)})" end) <>
          ". Search them with rg or grep, and read parts with sed -n, head or tail: they " <>
          "can be large, so don't read one whole."
    end
  end

  @doc "The start of each of the run's files, `bytes` of each at most, to look through."
  def heads(run, bytes \\ 16 * 1024 * 1024) do
    for {name, _size} <- list(run),
        {:ok, text} when is_binary(text) <-
          [File.open(Path.join(dir(run), name), [:read, :binary], &IO.binread(&1, bytes))],
        do: text
  end

  @doc "Removes the run's files."
  def delete(run), do: File.rm_rf(dir(run))

  @doc "A byte count in words: 812 B, 14 KB, 2.3 MB."
  def size(bytes) when bytes < 1024, do: "#{bytes} B"
  def size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"
  def size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  # A file name from what was uploaded: its last part, plain characters only.
  defp safe(name) do
    name
    |> to_string()
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim_leading(".")
    |> String.slice(0, 100)
    |> case do
      "" -> "file"
      name -> name
    end
  end

  defp unique(folder, name) do
    if File.exists?(Path.join(folder, name)) do
      ext = Path.extname(name)
      base = Path.rootname(name)

      Stream.iterate(2, &(&1 + 1))
      |> Enum.map(&"#{base}-#{&1}#{ext}")
      |> Enum.find(&(not File.exists?(Path.join(folder, &1))))
    else
      name
    end
  end
end
