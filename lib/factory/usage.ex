defmodule Factory.Usage do
  @moduledoc """
  What Kiro costs. Every call to Kiro, from a chat turn to a one-line task
  suggestion, is recorded as a `Factory.Usage.Event` with its credits (from Kiro)
  and estimated tokens, tagged with the run, spec or agent it was for.

  A "session" here is what the calls belong to: a run, else a spec, else "Other".
  Days are local days in the configured time zone (see `timezone/0`).
  """
  import Ecto.Query
  alias Factory.Repo
  alias Factory.Usage.Event

  @topic "usage"

  @sources %{
    "agent_turn" => "Agent chat",
    "review" => "Spec review",
    "plan_questions" => "Task suggestions: reading",
    "plan_tasks" => "Task suggestions: writing",
    "improve_task" => "Improve task",
    "draft_task" => "Refine new task",
    "plan_run" => "Plan run",
    "plan_chat" => "Plan in chat",
    "run_step" => "Run step",
    "title" => "Chat title",
    "other" => "Other"
  }

  # The local date of a timestamp column, in `timezone/0`.
  defmacrop local_date(field) do
    quote do
      fragment(
        "((? AT TIME ZONE 'UTC') AT TIME ZONE ?)::date",
        unquote(field),
        ^timezone()
      )
    end
  end

  defmacrop local_time_of(field) do
    quote do
      fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE ?)", unquote(field), ^timezone())
    end
  end

  @doc "Labels for each source, the kinds of work Kiro is used for."
  def sources, do: @sources
  def source_label(source), do: Map.get(@sources, source, source)

  @doc "Subscribes to `{:usage_recorded, event}` for every call to Kiro."
  def subscribe, do: Phoenix.PubSub.subscribe(Factory.PubSub, @topic)

  @doc """
  Records one call to Kiro. `attrs` has `:source` and any of `:run_id`, `:spec_id`,
  `:agent_id`, `:model`, `:credits`, `:input_tokens`, `:output_tokens`, `:ms`, `:ok`.
  Never fails the caller: a problem saving is logged and ignored.
  """
  def record(attrs) do
    attrs = Map.new(attrs)

    event =
      struct(Event, Map.take(attrs, ~w(run_id spec_id agent_id source model credits
        input_tokens output_tokens ms ok)a))

    event = %{event | source: event.source || "other", credits: (event.credits || 0) / 1}

    # Work on a factory run's spec is part of that run.
    event =
      if is_nil(event.run_id) and event.spec_id,
        do: %{event | run_id: home_run_id(event.spec_id)},
        else: event

    case Repo.insert(event) do
      {:ok, event} ->
        Phoenix.PubSub.broadcast(Factory.PubSub, @topic, {:usage_recorded, event})
        {:ok, event}

      {:error, reason} = error ->
        require Logger
        Logger.warning("Couldn't record Kiro usage: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      require Logger
      Logger.warning("Couldn't record Kiro usage: #{Exception.message(e)}")
      {:error, e}
  end

  defp home_run_id(spec_id) do
    Repo.one(
      from r in Factory.Runs.Run,
        where: r.spec_id == ^spec_id and not is_nil(r.kind),
        order_by: r.id,
        limit: 1,
        select: r.id
    )
  end

  @doc "A rough token count for text: about four characters per token."
  def estimate_tokens(nil), do: 0
  def estimate_tokens(text), do: div(String.length(text) + 3, 4)

  @doc """
  The time zone days are counted in: `config :factory, :timezone`, else the TZ
  environment variable, else the system's zone, else UTC.
  """
  def timezone do
    Application.get_env(:factory, :timezone) || System.get_env("TZ") || system_zone() || "UTC"
  end

  defp system_zone do
    with {:ok, target} <- File.read_link("/etc/localtime"),
         [_, zone] <- Regex.run(~r{zoneinfo/(.+)$}, target) do
      zone
    else
      _ -> nil
    end
  end

  @doc "Today's date in `timezone/0`."
  def today do
    %{rows: [[date]]} =
      Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [timezone()])

    date
  end

  # Totals

  @doc """
  Totals for a scope: `:today`, `{:month, date}`, `{:run, id}` or `{:spec, id}`.
  Returns `%{credits:, tokens:, calls:}`.
  """
  def totals(scope) do
    Event
    |> scoped(scope)
    |> select([e], %{
      credits: coalesce(sum(e.credits), 0.0),
      tokens: coalesce(sum(e.input_tokens + e.output_tokens), 0),
      calls: count(e.id)
    })
    |> Repo.one()
    |> normalize()
  end

  defp scoped(query, :today), do: scoped(query, today())
  defp scoped(query, {:run, id}), do: where(query, [e], e.run_id == ^id)
  defp scoped(query, {:spec, id}), do: where(query, [e], e.spec_id == ^id)

  defp scoped(query, %Date{} = day), do: between_dates(query, day, Date.add(day, 1))

  defp scoped(query, {:month, %Date{} = date}) do
    between_dates(query, Date.beginning_of_month(date), Date.add(Date.end_of_month(date), 1))
  end

  defp between_dates(query, first, next) do
    # Use PostgreSQL's time zone database once for the two local midnights. Keep
    # the indexed column bare, and convert both ends separately for DST changes.
    %{rows: [[from, until]]} =
      Repo.query!(
        "SELECT $1::date::timestamp AT TIME ZONE $3, $2::date::timestamp AT TIME ZONE $3",
        [first, next, timezone()]
      )

    where(
      query,
      [e],
      e.inserted_at >= ^from and e.inserted_at < ^until
    )
  end

  @doc """
  Every day of the month containing `date`, oldest first, each with its totals:
  `[%{date:, credits:, tokens:, calls:}]`. Days without calls are zero.
  """
  def days(%Date{} = date, filters \\ %{}) do
    by_day =
      Event
      |> scoped({:month, date})
      |> filtered(filters)
      |> select([e], %{
        day: selected_as(local_date(e.inserted_at), :day),
        credits: coalesce(sum(e.credits), 0.0),
        tokens: coalesce(sum(e.input_tokens + e.output_tokens), 0),
        calls: count(e.id)
      })
      |> group_by([e], selected_as(:day))
      |> Repo.all()
      |> Map.new(fn %{day: day} = t -> {day, t |> Map.delete(:day) |> normalize()} end)

    for day <- Date.range(Date.beginning_of_month(date), Date.end_of_month(date)) do
      Map.merge(%{date: day}, Map.get(by_day, day, %{credits: 0.0, tokens: 0, calls: 0}))
    end
  end

  @doc """
  The sessions that used Kiro on `date` (or across the month with `{:month, date}`):
  runs, specs worked on outside a run, and "Other". Each is
  `%{key:, title:, kind:, credits:, tokens:, calls:, first_at:, last_at:, by_source:}`.

  Filters: `"source"` keeps only calls of that kind of work; `"type"` keeps only runs
  of that type (`Factory.Runs.Types`, or `"chat"` for plain chats); `"sort"` is
  `"most"` (default), `"least"` or `"latest"`.
  """
  def sessions(when_, filters \\ %{}) do
    query =
      case when_ do
        %Date{} = day -> scoped(Event, day)
        {:month, date} -> scoped(Event, {:month, date})
      end

    events =
      query
      |> filtered(filters)
      |> with_local_time()
      |> preload([:run, :spec])
      |> Repo.all()

    events
    |> Enum.group_by(&session_key/1)
    |> Enum.map(fn {key, events} -> summarize(key, events) end)
    |> sort(filters["sort"])
  end

  @doc "The calls in one session on a day, a month (`{:month, date}`) or `:all` time, newest first."
  def calls(key, when_) do
    query =
      case when_ do
        %Date{} = day -> scoped(Event, day)
        {:month, date} -> scoped(Event, {:month, date})
        :all -> Event
      end

    query =
      case key do
        {:run, id} -> where(query, [e], e.run_id == ^id)
        {:spec, id} -> where(query, [e], is_nil(e.run_id) and e.spec_id == ^id)
        :other -> where(query, [e], is_nil(e.run_id) and is_nil(e.spec_id))
      end

    query
    |> order_by(desc: :inserted_at, desc: :id)
    |> with_local_time()
    |> preload(:agent)
    |> Repo.all()
  end

  defp with_local_time(query),
    do:
      select_merge(query, [e], %{
        local_at: type(local_time_of(e.inserted_at), :naive_datetime_usec)
      })

  @doc "A local time (from an event's `local_at`) as \"14:05\"."
  def local_time(%NaiveDateTime{} = t), do: Calendar.strftime(t, "%H:%M")

  defp filtered(query, filters) do
    query
    |> filter_source(filters["source"])
    |> filter_type(filters["type"])
  end

  defp filter_source(query, source) when source in [nil, ""], do: query
  defp filter_source(query, source), do: where(query, [e], e.source == ^source)

  defp filter_type(query, type) when type in [nil, ""], do: query

  defp filter_type(query, "chat") do
    from e in query,
      join: r in Factory.Runs.Run,
      on: r.id == e.run_id,
      where: is_nil(r.kind)
  end

  defp filter_type(query, type) do
    from e in query, join: r in Factory.Runs.Run, on: r.id == e.run_id, where: r.kind == ^type
  end

  defp session_key(%Event{run_id: id}) when not is_nil(id), do: {:run, id}
  defp session_key(%Event{spec_id: id}) when not is_nil(id), do: {:spec, id}
  defp session_key(_), do: :other

  defp summarize(key, [first | _] = events) do
    {title, kind} =
      case key do
        {:run, _} ->
          {(first.run && first.run.title) || "Deleted run",
           if(first.run && first.run.kind,
             do: Factory.Runs.Types.short(first.run.kind),
             else: "Chat"
           )}

        {:spec, _} ->
          {(first.spec && first.spec.name) || "Deleted spec", "Spec"}

        :other ->
          {"Other", "Other"}
      end

    times = Enum.map(events, & &1.local_at)

    %{
      key: key,
      title: title,
      kind: kind,
      credits: events |> Enum.map(& &1.credits) |> Enum.sum(),
      tokens: events |> Enum.map(&(&1.input_tokens + &1.output_tokens)) |> Enum.sum(),
      calls: length(events),
      first_at: Enum.min(times, NaiveDateTime),
      last_at: Enum.max(times, NaiveDateTime),
      by_source:
        events
        |> Enum.group_by(& &1.source)
        |> Map.new(fn {s, es} -> {s, es |> Enum.map(& &1.credits) |> Enum.sum()} end)
    }
  end

  defp sort(sessions, "least"), do: Enum.sort_by(sessions, &{&1.credits, &1.tokens})
  defp sort(sessions, "latest"), do: Enum.sort_by(sessions, & &1.last_at, {:desc, NaiveDateTime})
  defp sort(sessions, _most), do: Enum.sort_by(sessions, &{&1.credits, &1.tokens}, :desc)

  defp normalize(t), do: %{t | credits: t.credits / 1, tokens: to_int(t.tokens)}

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n), do: n

  @doc "The key of a session as a string for URLs and ids, and back."
  def key_to_param({kind, id}), do: "#{kind}-#{id}"
  def key_to_param(:other), do: "other"

  def param_to_key("other"), do: :other

  def param_to_key(param) do
    case String.split(param, "-", parts: 2) do
      ["run", id] -> {:run, String.to_integer(id)}
      ["spec", id] -> {:spec, String.to_integer(id)}
      _ -> nil
    end
  end
end
