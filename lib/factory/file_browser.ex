defmodule Factory.FileBrowser do
  @moduledoc """
  Lists folders (and text files) on the machine Factory runs on, so a person can pick
  a path instead of typing it. Factory runs on the person's own machine, so these
  are their files. Hidden entries are left out unless asked for.
  """

  @text_ext ~w(.md .markdown .txt .rst .adoc .json .yaml .yml .toml)
  @max_entries 500

  @doc "Where browsing usually starts: home, Desktop, Documents, projects, this app."
  def places do
    home = System.user_home!()

    [
      {"Home", home},
      {"Desktop", Path.join(home, "Desktop")},
      {"Documents", Path.join(home, "Documents")},
      {"Projects", Path.join(home, "projects")},
      {"Downloads", Path.join(home, "Downloads")}
    ]
    |> Enum.filter(fn {_, path} -> File.dir?(path) end)
  end

  @doc "A good folder to start in: the one given (or a file's folder), else home."
  def start_dir(nil), do: System.user_home!()

  def start_dir(path) do
    path = Path.expand(path)

    cond do
      File.dir?(path) -> path
      File.dir?(Path.dirname(path)) -> Path.dirname(path)
      true -> System.user_home!()
    end
  end

  @doc """
  The entries of a folder: `{:ok, %{dir:, parent:, crumbs:, entries: [%{name:, path:, dir?:}]}}`
  with folders first. Options: `files: true` to include files (text files, or `ext: [".json"]`, or
  `ext: :any`), `hidden: true`.
  """
  def list(dir, opts \\ []) do
    dir = Path.expand(dir)

    case File.ls(dir) do
      {:ok, names} ->
        entries =
          names
          |> Enum.reject(&(String.starts_with?(&1, ".") and !opts[:hidden]))
          |> Enum.map(fn name ->
            path = Path.join(dir, name)
            %{name: name, path: path, dir?: File.dir?(path)}
          end)
          |> Enum.filter(&(&1.dir? or (opts[:files] && wanted?(&1.name, opts[:ext]))))
          |> Enum.sort_by(&{!&1.dir?, String.downcase(&1.name)})

        {:ok,
         %{
           dir: dir,
           parent: if(dir == "/", do: nil, else: Path.dirname(dir)),
           crumbs: crumbs(dir),
           entries: Enum.take(entries, @max_entries),
           more: max(length(entries) - @max_entries, 0)
         }}

      {:error, reason} ->
        {:error, "Can't open #{dir}: #{:file.format_error(reason)}"}
    end
  end

  def text_file?(name), do: String.downcase(Path.extname(name)) in @text_ext

  # `ext`: nil for text files, :any for every file, or a list like [".json"].
  defp wanted?(name, nil), do: text_file?(name)
  defp wanted?(_name, :any), do: true
  defp wanted?(name, exts), do: String.downcase(Path.extname(name)) in exts

  # "/Users/ann/docs" -> [{"/", "/"}, {"Users", "/Users"}, {"ann", "/Users/ann"}, {"docs", …}]
  defp crumbs(dir) do
    dir
    |> Path.split()
    |> Enum.scan({nil, nil}, fn part, {_, acc} ->
      {part, if(acc, do: Path.join(acc, part), else: part)}
    end)
  end
end
