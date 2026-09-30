defmodule FactoryWeb.FolderBrowser do
  @moduledoc """
  The folder (or file) picker's state on a LiveView's socket, drawn by
  `FactoryWeb.SourceParts.browser/1`: `%{mode:, hidden:, listing:, error:}` in the
  `browser` assign, nil while closed. A page opens it with `open/3`, moves it with
  `go/2` (`browse_go`), `toggle_hidden/1` (`browse_hidden`) and `close/1`
  (`browse_cancel`), and handles `browse_pick` itself.
  """
  import Phoenix.Component, only: [assign: 2, update: 3]
  alias Factory.FileBrowser

  @doc """
  Opens the browser at `current` (a path, or nil for the home folder). `attrs` go into
  the browser's map: `mode:` is `"dir"` (folders only, the default), `"file"`, `"json"`
  or `"any"`; a page may add its own, such as the field being filled.
  """
  def open(socket, current, attrs \\ %{}) do
    browser = Map.merge(%{mode: "dir", hidden: false, listing: nil, error: nil}, Map.new(attrs))
    assign(socket, browser: browse(browser, FileBrowser.start_dir(current)))
  end

  @doc "Shows the folder at `path`."
  def go(socket, path), do: update(socket, :browser, &browse(&1, path))

  @doc "Shows or hides hidden files and folders, staying where it is."
  def toggle_hidden(socket) do
    update(socket, :browser, fn browser ->
      browser = %{browser | hidden: !browser.hidden}
      browse(browser, browser.listing && browser.listing.dir)
    end)
  end

  @doc "Closes the browser."
  def close(socket), do: assign(socket, browser: nil)

  @doc "The browser showing `dir` (nil for the home folder), or its error when it can't be read."
  def browse(browser, dir) do
    case FileBrowser.list(dir || System.user_home!(),
           files: browser.mode != "dir",
           ext:
             case browser.mode do
               "json" -> [".json"]
               "any" -> :any
               _ -> nil
             end,
           hidden: browser.hidden
         ) do
      {:ok, listing} -> %{browser | listing: listing, error: nil}
      {:error, reason} -> %{browser | error: reason}
    end
  end
end
