defmodule Factory.Sources.PageIndex do
  @moduledoc """
  Reads a PageIndex tree (https://github.com/VectifyAI/PageIndex): the JSON table of
  contents PageIndex builds for a long document, one node per section:

      %{"title" => …, "node_id" => "0003", "start_index" => 12, "end_index" => 18,
        "summary" => …, "text" => … (optional), "nodes" => [child, …]}

  The file is either that list of top-level nodes, or an object holding it under
  "structure" (with "doc_name" beside it). Markdown trees use "line_num" instead of
  page numbers.

  Agents get the outline (ids, titles, pages, short summaries) and open only the
  sections a task needs: each section's text, when the tree has it, is written to a
  file of its own (`write_sections/2`).
  """

  @max_outline 30_000

  @doc "Reads a tree file: `{:ok, %{doc_name:, nodes:, count:, text?:}}` or `{:error, reason}`."
  def load(path) do
    with {:ok, body} <- read(path),
         {:ok, data} <- decode(body),
         {name, nodes} when is_list(nodes) and nodes != [] <- structure(data) do
      nodes = Enum.filter(nodes, &is_map/1)
      all = flatten(nodes)

      {:ok,
       %{
         doc_name: name || Path.basename(path, ".json"),
         nodes: nodes,
         count: length(all),
         text?: Enum.any?(all, &(is_binary(&1["text"]) and String.trim(&1["text"]) != ""))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "isn't a PageIndex tree: no sections found"}
    end
  end

  defp read(path) do
    case File.read(Path.expand(path)) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "can't be read: #{:file.format_error(reason)}"}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, "isn't valid JSON"}
    end
  end

  defp structure(list) when is_list(list), do: {nil, list}

  defp structure(%{} = map) do
    nodes = map["structure"] || map["nodes"] || map["tree"] || map["result"]
    {map["doc_name"] || map["title"], nodes}
  end

  defp structure(_), do: nil

  defp flatten(nodes),
    do:
      Enum.flat_map(
        nodes,
        &[&1 | flatten(Enum.filter(List.wrap(&1["nodes"]), fn n -> is_map(n) end))]
      )

  @doc """
  The tree as an indented outline: `- [0003] Setup (p. 12–18): summary…`.
  With `sections_dir`, each line names the file holding that section's text.
  """
  def outline(nodes, sections_dir \\ nil) do
    nodes
    |> lines(0, sections_dir)
    |> Enum.join("\n")
    |> String.slice(0, @max_outline)
  end

  defp lines(nodes, depth, dir) do
    Enum.flat_map(nodes, fn node ->
      children = node |> Map.get("nodes") |> List.wrap() |> Enum.filter(&is_map/1)
      [line(node, depth, dir) | lines(children, depth + 1, dir)]
    end)
  end

  defp line(node, depth, dir) do
    id = if node["node_id"], do: "[#{node["node_id"]}] ", else: ""
    where = where(node)
    summary = summary(node)
    file = if dir && has_text?(node), do: " → #{Path.join(dir, file_name(node))}", else: ""

    "#{String.duplicate("  ", depth)}- #{id}#{node["title"] || "Untitled"}#{where}#{summary}#{file}"
  end

  defp where(%{"start_index" => a, "end_index" => b}) when is_integer(a) and is_integer(b),
    do: if(a == b, do: " (p. #{a})", else: " (p. #{a}–#{b})")

  defp where(%{"line_num" => n}) when is_integer(n), do: " (line #{n})"
  defp where(_), do: ""

  defp summary(node) do
    case node["summary"] || node["prefix_summary"] do
      s when is_binary(s) and s != "" ->
        s = s |> String.replace(~r/\s+/, " ") |> String.trim()
        ": " <> if(String.length(s) > 180, do: String.slice(s, 0, 177) <> "…", else: s)

      _ ->
        ""
    end
  end

  defp has_text?(node), do: is_binary(node["text"]) and String.trim(node["text"]) != ""

  @doc "Writes each section's text to its own markdown file in `dir` (replacing what was there)."
  def write_sections(nodes, dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    for node <- flatten(nodes), has_text?(node) do
      body = "# #{node["title"] || "Untitled"}#{where(node)}\n\n#{String.trim(node["text"])}\n"
      File.write!(Path.join(dir, file_name(node)), body)
    end

    :ok
  end

  defp file_name(node) do
    slug =
      (node["title"] || "section")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 50)

    "#{node["node_id"] || "x"}-#{slug}.md"
  end
end
