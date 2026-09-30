defmodule FactoryWeb.UsageLive do
  @moduledoc """
  What Kiro cost: a month at a time, day by day, then the sessions (runs and specs)
  of a day and the calls in each. Filters by the kind of work and sorts by use.
  Everything lives in the URL, so a view can be shared and survives a reload.
  """
  use FactoryWeb, :live_view
  alias Factory.Usage
  alias FactoryWeb.Usage, as: Fmt

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Usage")}
  end

  def handle_params(params, _uri, socket) do
    today = Usage.today()
    month = parse_month(params["month"]) || Date.beginning_of_month(today)

    filters = %{
      "source" => params["source"] || "",
      "type" => params["type"] || "",
      "sort" => params["sort"] || "most"
    }

    days = Usage.days(month, filters)

    # Opens on today when today has calls, else on the whole month.
    day =
      case params["day"] do
        "all" -> nil
        nil -> Enum.find_value(days, &(&1.date == today and &1.calls > 0 and today))
        d -> parse_day(d, month)
      end

    when_ = day || {:month, month}
    sessions = Usage.sessions(when_, filters)
    open = params["open"] && Usage.param_to_key(params["open"])

    {:noreply,
     assign(socket,
       today: today,
       month: month,
       day: day,
       picked: params["day"] not in [nil, "all"],
       filters: filters,
       filter_form: to_form(filters),
       view: if(params["view"] == "table", do: "table", else: "chart"),
       days: days,
       totals: sum(days),
       sessions: sessions,
       open: open,
       calls: if(open, do: Usage.calls(open, when_), else: [])
     )}
  end

  @doc "New calls to Kiro show up as they happen (called by FactoryWeb.UsageMeter)."
  def usage_recorded(_event, socket) do
    %{month: month, day: day, filters: filters, open: open} = socket.assigns
    days = Usage.days(month, filters)
    when_ = day || {:month, month}

    assign(socket,
      days: days,
      totals: sum(days),
      sessions: Usage.sessions(when_, filters),
      calls: if(open, do: Usage.calls(open, when_), else: [])
    )
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         usage_path(socket.assigns,
           source: params["source"],
           type: params["type"],
           sort: params["sort"],
           open: nil
         )
     )}
  end

  defp sum(days) do
    %{
      credits: days |> Enum.map(& &1.credits) |> Enum.sum(),
      tokens: days |> Enum.map(& &1.tokens) |> Enum.sum(),
      calls: days |> Enum.map(& &1.calls) |> Enum.sum(),
      active: Enum.count(days, &(&1.calls > 0))
    }
  end

  # The URL for the current view with some parts changed (nil drops a part).
  defp usage_path(a, changes) do
    current = [
      month: Calendar.strftime(a.month, "%Y-%m"),
      day: if(a.day, do: Date.to_iso8601(a.day), else: "all"),
      source: a.filters["source"],
      type: a.filters["type"],
      sort: a.filters["sort"],
      view: a.view,
      open: a.open && Usage.key_to_param(a.open)
    ]

    query =
      current
      |> Keyword.merge(changes)
      |> Enum.reject(fn {k, v} ->
        v in [nil, ""] or (k == :sort and v == "most") or (k == :view and v == "chart")
      end)

    ~p"/usage?#{query}"
  end

  defp parse_month(nil), do: nil

  defp parse_month(s) do
    case Date.from_iso8601(s <> "-01") do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_day(s, month) do
    case Date.from_iso8601(s) do
      {:ok, d} -> if same_month?(d, month), do: d
      _ -> nil
    end
  end

  defp same_month?(a, b), do: a.year == b.year and a.month == b.month

  defp shift_month(month, by),
    do: month |> Date.shift(month: by) |> Date.beginning_of_month()

  def render(assigns) do
    max = assigns.days |> Enum.map(& &1.credits) |> Enum.max(fn -> 0 end)
    peak = Enum.max_by(assigns.days, & &1.credits, fn -> nil end)

    assigns =
      assign(assigns,
        max: max,
        scale: nice_max(max),
        peak: if(peak && peak.credits > 0, do: peak.date),
        future?: fn d -> Date.compare(d, assigns.today) == :gt end
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      usage={@usage_meter}
      active_runs={@active_runs}
      kiro={@kiro}
      active={:usage}
    >
      <Layouts.page_title
        title="Usage"
        subtitle="Every call to Kiro, from agent chats to one-line task suggestions. Credits come from Kiro; tokens are estimated (≈)."
      />

      <div class="mb-6 flex flex-wrap items-center gap-3">
        <div class="flex items-center gap-1">
          <.link
            patch={
              usage_path(assigns,
                month: Calendar.strftime(shift_month(@month, -1), "%Y-%m"),
                day: "all",
                open: nil
              )
            }
            class="grid size-8 place-items-center rounded-md text-base-content/60 hover:bg-base-200 hover:text-base-content"
            aria-label="Previous month"
          >
            <.icon name="hero-chevron-left-mini" class="size-5" />
          </.link>
          <h2 class="min-w-36 text-center text-lg font-medium">
            {Calendar.strftime(@month, "%B %Y")}
          </h2>
          <.link
            patch={
              usage_path(assigns,
                month: Calendar.strftime(shift_month(@month, 1), "%Y-%m"),
                day: "all",
                open: nil
              )
            }
            class="grid size-8 place-items-center rounded-md text-base-content/60 hover:bg-base-200 hover:text-base-content"
            aria-label="Next month"
          >
            <.icon name="hero-chevron-right-mini" class="size-5" />
          </.link>
        </div>

        <.form
          for={@filter_form}
          id="usage-filters"
          phx-change="filter"
          class="ml-auto flex flex-wrap items-center gap-2"
        >
          <.input
            field={@filter_form[:source]}
            type="select"
            id="usage-filter-source"
            aria-label="Kind of work"
            options={source_options()}
            class="select select-sm w-auto"
            wrapper_class="contents"
          />
          <.input
            field={@filter_form[:type]}
            type="select"
            id="usage-filter-type"
            aria-label="Type of run"
            options={type_options()}
            class="select select-sm w-auto"
            wrapper_class="contents"
          />
          <.input
            field={@filter_form[:sort]}
            type="select"
            id="usage-filter-sort"
            aria-label="Sort sessions"
            options={[
              {"Most used first", "most"},
              {"Least used first", "least"},
              {"Latest first", "latest"}
            ]}
            class="select select-sm w-auto"
            wrapper_class="contents"
          />
        </.form>
      </div>

      <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.tile label="Credits" value={Fmt.credits(@totals.credits)} note="exact, from Kiro" />
        <.tile label="Tokens" value={"≈" <> Fmt.tokens(@totals.tokens)} note="estimated" />
        <.tile
          label="Calls to Kiro"
          value={to_string(@totals.calls)}
          note={"on #{@totals.active} #{if @totals.active == 1, do: "day", else: "days"}"}
        />
        <.tile
          label="Average per active day"
          value={if @totals.active > 0, do: Fmt.credits(@totals.credits / @totals.active), else: "–"}
          note="credits"
        />
      </div>

      <section class="mt-6 rounded-xl border border-base-300/70 bg-base-200/30 p-4 sm:p-5">
        <div class="mb-4 flex items-center justify-between gap-3">
          <h3 class="text-sm font-medium">Credits per day</h3>
          <div class="flex rounded-md bg-base-200 p-0.5 text-xs" role="tablist">
            <.link
              patch={usage_path(assigns, view: "chart")}
              role="tab"
              aria-selected={to_string(@view == "chart")}
              class={["rounded px-2.5 py-1", @view == "chart" && "bg-base-100 font-medium shadow-sm"]}
            >
              Chart
            </.link>
            <.link
              patch={usage_path(assigns, view: "table")}
              role="tab"
              aria-selected={to_string(@view == "table")}
              class={["rounded px-2.5 py-1", @view == "table" && "bg-base-100 font-medium shadow-sm"]}
            >
              Table
            </.link>
          </div>
        </div>

        <div :if={@view == "chart"} id="usage-chart" class="relative">
          <%!-- Gridlines at 0, half and the top of the scale --%>
          <div class="pointer-events-none absolute inset-x-0 top-0 h-48" aria-hidden="true">
            <div
              :for={f <- [1, 0.5]}
              class="absolute inset-x-0 border-t border-dashed border-base-content/10"
              style={"top: #{(1 - f) * 100}%"}
            >
              <span class="absolute -top-2 right-0 bg-base-100 pl-1 text-[10px] tabular-nums text-base-content/45">
                {Fmt.credits(@scale * f)}
              </span>
            </div>
          </div>

          <ol class="relative flex h-48 items-end gap-[2px] border-b border-base-content/20 pr-10">
            <li :for={d <- @days} class="group relative flex h-full flex-1 items-end">
              <.link
                patch={usage_path(assigns, day: Date.to_iso8601(d.date), open: nil)}
                aria-label={"#{Calendar.strftime(d.date, "%a %-d %b")}: #{Fmt.credits(d.credits)} credits, #{d.calls} calls"}
                class="flex h-full w-full items-end rounded-t-[4px] hover:bg-base-content/[0.04]"
              >
                <span
                  :if={d.credits > 0}
                  class={[
                    "block w-full rounded-t-[4px] bg-primary transition-opacity",
                    @picked && @day != d.date && "opacity-45 group-hover:opacity-80"
                  ]}
                  style={"height: max(3px, #{d.credits / max(@scale, 0.0001) * 100}%)"}
                ></span>
              </.link>
              <span
                :if={d.date == @peak and @scale > 0}
                class="pointer-events-none absolute left-1/2 -translate-x-1/2 whitespace-nowrap text-[11px] font-medium tabular-nums text-base-content/70"
                style={"bottom: calc(#{d.credits / @scale * 100}% + 4px)"}
              >
                {Fmt.credits(d.credits)}
              </span>
              <%!-- Tooltip --%>
              <span class="pointer-events-none absolute bottom-full left-1/2 z-10 mb-2 hidden -translate-x-1/2 whitespace-nowrap rounded-lg border border-base-content/10 bg-surface px-2.5 py-1.5 text-xs shadow-lg group-hover:block">
                <span class="block font-medium">{Calendar.strftime(d.date, "%a %-d %b")}</span>
                <span class="block tabular-nums text-base-content/70">
                  {Fmt.credits(d.credits)} credits · ≈{Fmt.tokens(d.tokens)} tokens
                </span>
                <span class="block tabular-nums text-base-content/55">
                  {d.calls} {if d.calls == 1, do: "call", else: "calls"}
                </span>
              </span>
            </li>
          </ol>
          <ol
            class="mt-1.5 flex gap-[2px] pr-10 text-[10px] tabular-nums text-base-content/45"
            aria-hidden="true"
          >
            <li
              :for={d <- @days}
              class={[
                "flex-1 text-center",
                d.date == @day && "font-semibold text-base-content",
                d.date == @today && d.date != @day && "text-base-content/80"
              ]}
            >
              {if d.date.day == 1 or rem(d.date.day, 5) == 0 or d.date == @day or d.date == @today,
                do: d.date.day}
            </li>
          </ol>
        </div>

        <div :if={@view == "table"} class="max-h-96 overflow-y-auto">
          <table id="usage-days" class="w-full text-sm">
            <thead class="sticky top-0 bg-base-100 text-left text-xs text-base-content/55">
              <tr>
                <th class="py-1.5 font-normal">Day</th>
                <th class="py-1.5 text-right font-normal">Calls</th>
                <th class="py-1.5 text-right font-normal">≈ Tokens</th>
                <th class="py-1.5 text-right font-normal">Credits</th>
              </tr>
            </thead>
            <tbody class="tabular-nums">
              <tr
                :for={d <- Enum.reverse(@days)}
                :if={!@future?.(d.date)}
                class={[
                  "border-t border-base-300/60",
                  d.date == @day && "bg-primary/[0.07]"
                ]}
              >
                <td class="py-1.5">
                  <.link
                    patch={usage_path(assigns, day: Date.to_iso8601(d.date), open: nil)}
                    class="hover:underline"
                  >
                    {Calendar.strftime(d.date, "%a %-d %b")}
                  </.link>
                </td>
                <td class="py-1.5 text-right text-base-content/70">{d.calls}</td>
                <td class="py-1.5 text-right text-base-content/70">{Fmt.tokens(d.tokens)}</td>
                <td class="py-1.5 text-right font-medium">{Fmt.credits(d.credits)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="mt-8">
        <div class="mb-3 flex flex-wrap items-baseline justify-between gap-2">
          <h3 class="text-lg font-medium">
            {if @day,
              do: "Sessions on #{Calendar.strftime(@day, "%A %-d %B")}",
              else: "Sessions in #{Calendar.strftime(@month, "%B")}"}
          </h3>
          <.link
            :if={@day}
            patch={usage_path(assigns, day: "all", open: nil)}
            class="text-sm text-base-content/60 hover:text-base-content"
          >
            Show the whole month
          </.link>
        </div>

        <p
          :if={@sessions == []}
          class="rounded-xl border border-dashed border-base-300 px-4 py-10 text-center text-sm text-base-content/55"
        >
          No calls to Kiro {if @day, do: "on this day", else: "this month"}{if @filters["source"] !=
                                                                                 "",
                                                                               do: " of this kind"}.
        </p>

        <ol
          id="usage-sessions"
          class="divide-y divide-base-300/70 overflow-hidden rounded-lg border border-base-300/70 empty:hidden"
        >
          <li
            :for={s <- @sessions}
            id={"session-#{Usage.key_to_param(s.key)}"}
            class={[
              "transition-colors",
              if(@open == s.key,
                do: "bg-primary/[0.05]",
                else: "hover:bg-base-content/[0.03]"
              )
            ]}
          >
            <.link
              patch={
                usage_path(assigns,
                  open: if(@open == s.key, do: nil, else: Usage.key_to_param(s.key))
                )
              }
              class="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2"
            >
              <span class={[
                "rounded px-1.5 py-0.5 text-[11px] font-medium",
                kind_class(s.kind)
              ]}>
                {s.kind}
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate text-[14px] font-medium">{s.title}</span>
                <span class="block text-xs text-base-content/50">
                  {time_range(s)} · {sources_summary(s.by_source)}
                </span>
              </span>
              <span class="flex items-center gap-4 text-sm tabular-nums">
                <span class="text-base-content/55">{s.calls} {if s.calls == 1,
                  do: "call",
                  else: "calls"}</span>
                <span class="text-base-content/55">≈{Fmt.tokens(s.tokens)}</span>
                <span class="flex min-w-16 items-center justify-end gap-1 font-medium">
                  <.icon name="hero-bolt-micro" class="size-3.5 text-base-content/40" />{Fmt.credits(
                    s.credits
                  )}
                </span>
              </span>
              <.icon
                name="hero-chevron-right-mini"
                class={[
                  "size-4 text-base-content/40 transition-transform",
                  @open == s.key && "rotate-90"
                ]}
              />
            </.link>

            <div :if={@open == s.key} class="border-t border-base-300/60 px-4 pb-3 pt-2">
              <div class="mb-2 flex items-center justify-between text-xs">
                <span class="text-base-content/55">Every call, newest first</span>
                <.link
                  :if={link_for(s.key)}
                  navigate={link_for(s.key)}
                  class="text-base-content/60 hover:text-base-content"
                >
                  Open {if match?({:spec, _}, s.key), do: "spec", else: "run"} →
                </.link>
              </div>
              <div class="overflow-x-auto">
                <table class="w-full text-[13px]">
                  <thead class="text-left text-[11px] text-base-content/50">
                    <tr>
                      <th class="py-1 pr-3 font-normal">Time</th>
                      <th class="py-1 pr-3 font-normal">Kind of work</th>
                      <th class="py-1 pr-3 font-normal">Agent</th>
                      <th class="py-1 pr-3 text-right font-normal">≈ In</th>
                      <th class="py-1 pr-3 text-right font-normal">≈ Out</th>
                      <th class="py-1 pr-3 text-right font-normal">Took</th>
                      <th class="py-1 text-right font-normal">Credits</th>
                    </tr>
                  </thead>
                  <tbody class="tabular-nums">
                    <tr :for={c <- @calls} class="border-t border-base-300/50">
                      <td class="py-1.5 pr-3 text-base-content/60">{local_time(c.local_at)}</td>
                      <td class="py-1.5 pr-3">
                        {Usage.source_label(c.source)}
                        <span :if={!c.ok} class="ml-1 text-xs text-error">failed</span>
                      </td>
                      <td class="py-1.5 pr-3 text-base-content/60">
                        {(c.agent && c.agent.name) || "–"}
                      </td>
                      <td class="py-1.5 pr-3 text-right text-base-content/60">
                        {Fmt.tokens(c.input_tokens)}
                      </td>
                      <td class="py-1.5 pr-3 text-right text-base-content/60">
                        {Fmt.tokens(c.output_tokens)}
                      </td>
                      <td class="py-1.5 pr-3 text-right text-base-content/60">{duration(c.ms)}</td>
                      <td class="py-1.5 text-right font-medium">{Fmt.credits(c.credits)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end

  # The filters' choices, as `{label, value}` for the selects.
  defp source_options do
    sources = Usage.sources() |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(fn {s, l} -> {l, s} end)
    [{"All kinds of work", ""} | sources]
  end

  defp type_options do
    types = for t <- Factory.Runs.Types.all(), do: {t.short, t.id}
    [{"All runs and specs", ""}] ++ types ++ [{"Plain chats", "chat"}]
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil

  defp tile(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300/70 bg-base-200/30 px-4 py-3">
      <div class="text-xs text-base-content/55">{@label}</div>
      <div class="mt-1 text-2xl font-semibold tabular-nums tracking-tight">{@value}</div>
      <div :if={@note} class="text-[11px] text-base-content/45">{@note}</div>
    </div>
    """
  end

  # A round top for the scale: 0.37 -> 0.4, 2.3 -> 2.5, 13 -> 15.
  defp nice_max(max) when max <= 0, do: 0

  defp nice_max(max) do
    magnitude = :math.pow(10, Float.floor(:math.log10(max)))
    step = Enum.find([1, 2, 2.5, 5, 10], &(&1 * magnitude >= max))
    step * magnitude
  end

  defp kind_class("Spec"), do: "bg-info/15 text-info"
  defp kind_class(k) when k in ["Other", "Chat"], do: "bg-base-content/10 text-base-content/60"
  defp kind_class(_run_type), do: "bg-base-content/[0.07] text-base-content/75"

  defp link_for({:run, id}), do: ~p"/runs/#{id}"
  defp link_for({:spec, id}), do: ~p"/specs/#{id}"
  defp link_for(_), do: nil

  defp time_range(%{first_at: a, last_at: b}) do
    if local_time(a) == local_time(b),
      do: local_time(a),
      else: "#{local_time(a)}–#{local_time(b)}"
  end

  # The top kinds of work in a session by credits: "Agent chat 0.62 · Spec review 0.10".
  defp sources_summary(by_source) do
    by_source
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(3)
    |> Enum.map_join(" · ", fn {s, c} -> "#{Usage.source_label(s)} #{Fmt.credits(c)}" end)
  end

  defp local_time(t), do: Usage.local_time(t)

  defp duration(nil), do: "–"
  defp duration(ms) when ms < 1000, do: "#{ms} ms"
  defp duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)} s"
  defp duration(ms), do: "#{div(ms, 60_000)} min #{rem(div(ms, 1000), 60)} s"
end
