defmodule Factory.Engine.Credits do
  @moduledoc """
  A run's credit limit (`Factory.Engine`): how much it may use before it pauses to ask
  whether to go on, counted from when it started, and checked between its steps and
  between a step's tasks.
  """
  alias Factory.Runs
  alias Factory.Runs.Run

  @doc """
  How many credits a run may use before it pauses to ask whether to go on: the limit in
  Settings (`"run_credit_limit"` in `Factory.Prefs`), else `config :factory,
  :run_credit_limit` (10). 0 means no limit.
  """
  def limit do
    case Factory.Prefs.get("run_credit_limit") do
      n when is_number(n) and n >= 0 -> n
      _ -> Application.get_env(:factory, :run_credit_limit, 10)
    end
  end

  @doc "How many credits the run may use before it pauses next, or nil with no limit."
  def allowance(%Run{} = run) do
    case limit() do
      limit when limit > 0 -> (run.progress || %{})["credits_allowed"] || limit
      _ -> nil
    end
  end

  # What the run has used and may use, once it has used that much.
  def over(run) do
    with allowed when allowed != nil <- allowance(run),
         %{credits: used} when used >= allowed <- Factory.Usage.totals({:run, run.id}),
         do: {used, allowed},
         else: (_ -> nil)
  end

  # Paused between steps or tasks, like a person's pause: what it has done stays.
  def pause(run, step, {used, allowed}, before \\ nil) do
    Runs.with_locked_run(run.id, fn run ->
      if run.status == "running" do
        progress = Map.put(run.progress, "credit_pause", true)
        {:ok, run} = Runs.update_run(run, %{status: "paused", progress: progress})

        Runs.post(
          run,
          "factory",
          "This run has used #{credits(used)} credits, past its limit of #{credits(allowed)}, " <>
            "so it's paused before #{before || step.name}. Continue lets it use " <>
            "#{credits(limit())} more; the limit is in Settings → Runs.",
          actions: ["continue"]
        )
      end

      {:ok, run}
    end)

    nil
  end

  # A run that paused at its credit limit may use as much again when it goes on, however
  # it was resumed.
  def allow_more(%{"credit_pause" => true} = progress, run) do
    used = Factory.Usage.totals({:run, run.id}).credits

    progress
    |> Map.delete("credit_pause")
    |> Map.put("credits_allowed", used + limit())
  end

  def allow_more(progress, _run), do: progress

  # A run that starts from the start counts its credits from then: what planning it in
  # the chat used, or its earlier go, isn't held against its limit. One that goes on
  # (its progress has what it has done) keeps what it was allowed.
  def from_now(progress, run) do
    limit = limit()

    if limit > 0 and not Map.has_key?(run.progress || %{}, "done") and
         not Map.has_key?(progress, "credits_allowed") do
      used = Factory.Usage.totals({:run, run.id}).credits
      Map.put(progress, "credits_allowed", used + limit)
    else
      progress
    end
  end

  defp credits(n), do: :erlang.float_to_binary(n / 1, decimals: 1)
end
