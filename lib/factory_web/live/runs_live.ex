defmodule FactoryWeb.RunsLive do
  use FactoryWeb, :live_view
  alias Factory.Runs

  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()
    {:ok, assign(socket, page_title: "Runs", runs: Runs.list_runs())}
  end

  def handle_info({:runs_changed}, socket), do: {:noreply, assign(socket, runs: Runs.list_runs())}

  # The server doesn't know the viewer's time zone, so show how long ago instead of a clock time.
  defp ago(time) do
    case DateTime.diff(DateTime.utc_now(), time) do
      s when s < 60 -> "just now"
      s when s < 3600 -> "#{div(s, 60)} min ago"
      s when s < 86_400 -> "#{div(s, 3600)} h ago"
      s -> "#{div(s, 86_400)} d ago"
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:runs}>
      <Layouts.page_title
        title="Runs"
        subtitle="Every chat with the factory and the spec it works on, newest first."
      >
        <:actions>
          <.link navigate={~p"/"} class="btn btn-primary btn-sm"><.icon
            name="hero-plus-mini"
            class="size-4"
          /> New chat</.link>
        </:actions>
      </Layouts.page_title>

      <p :if={@runs == []} class="border-y border-base-300 py-6 text-sm text-base-content/55">
        No runs yet. Start a chat and drop a spec into it.
      </p>

      <div :if={@runs != []} class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead class="text-left text-[13px] text-base-content/55">
            <tr class="border-b border-base-300">
              <th class="py-2 pr-4 font-normal">Run</th>
              <th class="py-2 pr-4 font-normal">Status</th>
              <th class="py-2 pr-4 font-normal">Tasks</th>
              <th class="py-2 pr-4 font-normal">Spec</th>
              <th class="py-2 text-right font-normal">Updated</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={r <- @runs}
              phx-click={JS.navigate(~p"/chat/#{r.id}")}
              class="cursor-pointer border-b border-base-300 hover:bg-base-200"
            >
              <td class="py-3 pr-4">
                <.link navigate={~p"/chat/#{r.id}"} class="font-medium">{r.title}</.link>
              </td>
              <td class="py-3 pr-4"><Layouts.status_badge status={r.status} /></td>
              <td class="py-3 pr-4 tabular-nums text-base-content/75">
                {if r.tasks == [],
                  do: "–",
                  else: "#{Enum.count(r.tasks, &(&1.status == "done"))} of #{length(r.tasks)} done"}
              </td>
              <td class="py-3 pr-4 text-base-content/60">{Enum.join(r.spec_files, ", ")}</td>
              <td class="whitespace-nowrap py-3 text-right text-base-content/55">
                {ago(r.updated_at)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
