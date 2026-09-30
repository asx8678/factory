defmodule FactoryWeb.FolderBrowser do
  @moduledoc """
  The folder browser window (`FactoryWeb.SourceParts.browser/1`) as the chat (its project
  folder) and the Workflows page (a data source's folder or file) keep it in `@browser`:
  `%{mode:, hidden:, listing:, error:}`, plus whatever the page adds, like the field a
  picked path goes into. `mode` is what can be picked: "dir", "file", "json" or "any".

  Moving around, showing hidden files and closing are the same on both pages
  (`handle_event/3`); each page opens it and takes the picked path itself.
  """
  import Phoenix.Component, only: [assign: 3, update: 3]
  alias Factory.FileBrowser

  @doc "A browser for folders (or what `extra` sets), open at `dir`."
  def open(dir, extra \\ %{}) do
    %{mode: "dir", hidden: false, listing: nil, error: nil}
    |> Map.merge(extra)
    |> list(dir)
  end

  @doc """
  The window's `browse_go`, `browse_hidden` and `browse_cancel`. Once it's closed (a
  late or double click), they change nothing.
  """
  def handle_event(_event, _params, %{assigns: %{browser: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("browse_go", %{"path" => path}, socket),
    do: {:noreply, update(socket, :browser, &list(&1, path))}

  def handle_event("browse_hidden", _params, socket) do
    browser = %{socket.assigns.browser | hidden: !socket.assigns.browser.hidden}
    {:noreply, assign(socket, :browser, list(browser, browser.listing && browser.listing.dir))}
  end

  def handle_event("browse_cancel", _params, socket),
    do: {:noreply, assign(socket, :browser, nil)}

  # The folder's contents: folders, and files too when a file is being picked.
  defp list(browser, dir) do
    case FileBrowser.list(dir || System.user_home!(),
           files: browser.mode != "dir",
           ext: ext(browser.mode),
           hidden: browser.hidden
         ) do
      {:ok, listing} -> %{browser | listing: listing, error: nil}
      {:error, reason} -> %{browser | error: reason}
    end
  end

  defp ext("json"), do: [".json"]
  defp ext("any"), do: :any
  defp ext(_mode), do: nil
end
