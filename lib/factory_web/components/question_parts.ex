defmodule FactoryWeb.QuestionParts do
  @moduledoc """
  Questions in the chat's messages (`FactoryWeb.ChatParts.message/1`), answered by
  picking: one a tool asks mid-turn (an MCP elicitation, `Factory.Kiro.Session`), and a
  planner's questions with options while the run is being planned. Events go to the
  chat LiveView: `elicit_answer` and `answer`.
  """
  use FactoryWeb, :html

  attr :id, :string, required: true
  attr :message, :map, required: true

  # A question a tool asks mid-turn (MCP elicitation, `Factory.Kiro.Session`): a form
  # from its schema while it's open (the agent waits), then what was answered.
  def elicitation(assigns) do
    e = assigns.message.meta["elicitation"]
    # The schema is the other MCP server's, as it wrote it: what isn't the shape a
    # schema has (a field that isn't an object, a choice of nothing) is left out.
    schema = map_or_empty(e["schema"])
    required = if is_list(schema["required"]), do: schema["required"], else: []
    props = map_or_empty(schema["properties"])

    # A planner's question with options comes with an answer of your own beside it
    # (`answer_N_other`, `Factory.PlanTools`): shown under its options, not on its own.
    fields =
      for {name, %{} = prop} <- props, not own_answer_field?(name, props) do
        other = if Map.has_key?(props, name <> "_other"), do: name <> "_other"
        options = choices(prop["enum"])

        %{
          name: name,
          label: prop["title"] || prop["description"] || humanize(name),
          hint: if(prop["title"], do: prop["description"]),
          type: prop["type"],
          options: options,
          labels: choice_labels(prop["enumNames"], options),
          default: prop["default"],
          required: name in required,
          other: other
        }
      end
      |> Enum.sort_by(&natural(&1.name))

    assigns = assign(assigns, e: e, fields: fields)

    ~H"""
    <form
      :if={@e["status"] == "open"}
      id={@id}
      phx-submit="elicit_answer"
      class="task-card-active mt-3 rounded-xl border"
    >
      <input type="hidden" name="key" value={@e["key"]} />
      <input type="hidden" name="agent_id" value={@message.meta["agent_id"]} />
      <.question_head
        who={@message.author}
        count={length(@fields)}
        waiting
      />
      <ol class="divide-y divide-base-content/[0.07]">
        <.question_row
          :for={{f, n} <- Enum.with_index(@fields, 1)}
          n={n}
          question={f.label}
          hint={f.hint}
        >
          <%= cond do %>
            <% f.options -> %>
              <.option_list
                name={"fields[#{f.name}]"}
                options={Enum.zip(f.options, f.labels)}
                checked={f.default || List.first(f.options)}
                own={f.other && "fields[#{f.other}]"}
              />
            <% f.type == "boolean" -> %>
              <.option_list
                name={"fields[#{f.name}]"}
                options={[{"true", "Yes"}, {"false", "No"}]}
                checked={to_string(f.default == true)}
                recommend={false}
              />
            <% true -> %>
              <input
                type={if f.type in ["number", "integer"], do: "number", else: "text"}
                name={"fields[#{f.name}]"}
                value={f.default}
                required={f.required}
                autocomplete="off"
                class="h-8 w-full rounded-md border border-base-content/15 bg-base-100 px-2.5 text-[13px] outline-none focus:border-primary/50"
              />
          <% end %>
        </.question_row>
      </ol>
      <.question_foot note="It waits for your answers, then carries on.">
        <button
          type="submit"
          name="action"
          value="decline"
          formnovalidate
          class="btn btn-ghost btn-sm"
        >
          Decline
        </button>
        <button type="submit" name="action" value="accept" class="btn btn-primary btn-sm">
          Send answers
        </button>
      </.question_foot>
    </form>
    <div
      :if={@e["status"] == "answered"}
      id={@id}
      class="mt-3 rounded-xl border border-base-content/10 px-3.5 py-2.5 text-[13px]"
    >
      <p class="mb-1.5 flex items-center gap-1.5 text-xs font-medium text-base-content/60">
        <.icon name="hero-check-circle-mini" class="size-4 text-success" /> You answered
      </p>
      <ol class="space-y-2">
        <li :for={{question, answer} <- answers(@e["answer"], @e["schema"])} class="leading-snug">
          <p class="text-xs text-base-content/50">{elem(split_question(question), 0)}</p>
          <p class="mt-0.5">{answer}</p>
        </li>
      </ol>
    </div>
    <p
      :if={@e["status"] not in ["open", "answered"]}
      id={@id}
      class="mt-2 text-xs text-base-content/55"
    >
      {if @e["status"] == "declined",
        do: "You declined to answer.",
        else: "No longer waiting: the turn ended before an answer."}
    </p>
    """
  end

  # Each answer with its question's title, or its field name when it has none: the
  # option picked, with the answer of your own written beside it.
  defp answers(answer, schema) when is_map(answer) do
    props = map_or_empty(map_or_empty(schema)["properties"])

    answer
    |> Enum.reject(fn {k, _} -> own_answer_field?(k, props) end)
    |> Enum.sort_by(&natural(elem(&1, 0)))
    |> Enum.map(fn {k, v} ->
      # "Different content (please describe)" reads as "Different content".
      v =
        case option_label(v) do
          {words, "please" <> _} -> words
          _ -> v
        end

      v =
        [v, answer[k <> "_other"]]
        |> Enum.map(&String.trim(to_string(&1 || "")))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(": ")

      title = with %{"title" => title} <- props[k], do: title, else: (_ -> nil)
      {title || humanize(k), v}
    end)
  end

  defp answers(_answer, _schema), do: []

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_other), do: %{}

  # A question's options, when it has some to pick from.
  defp choices([_ | _] = options) do
    case Enum.filter(options, &(is_binary(&1) or is_number(&1) or is_boolean(&1))) do
      [] -> nil
      options -> options
    end
  end

  defp choices(_options), do: nil

  # What each option is called, when the schema names them all; else the options.
  defp choice_labels(names, options)
       when is_list(names) and is_list(options) and length(names) == length(options),
       do: names

  defp choice_labels(_names, options), do: options

  defp humanize(name), do: name |> to_string() |> String.replace("_", " ") |> String.capitalize()

  @doc """
  A planner's questions with options can be answered by picking, while the run is
  still being planned.
  """
  def answerable?(%{meta: meta}, run) do
    run != nil and run.status == "draft" and questions(meta) != []
  end

  # The planner's questions that have options, each with its place among all of them.
  defp questions(%{"questions" => [_ | _] = questions}) do
    for {%{} = q, i} <- Enum.with_index(questions),
        options = choices(q["options"]),
        do: {Map.put(q, "options", options), i}
  end

  defp questions(_meta), do: []

  attr :id, :string, required: true
  attr :message, :map, required: true

  # The planner's questions as choices: pick one option per question, or write your
  # own, then send them all as one message to the planner.
  def question_form(assigns) do
    assigns = assign(assigns, questions: questions(assigns.message.meta))

    ~H"""
    <form id={@id} phx-submit="answer" class="task-card-active mt-3 rounded-xl border">
      <input type="hidden" name="message_id" value={@message.id} />
      <.question_head who={@message.author} count={length(@questions)} />
      <ol class="divide-y divide-base-content/[0.07]">
        <.question_row :for={{q, i} <- @questions} n={i + 1} question={q["question"]}>
          <.option_list
            name={"answers[#{i}]"}
            options={Enum.map(q["options"], &{&1, &1})}
            checked={List.first(q["options"])}
            own={"others[#{i}]"}
          />
        </.question_row>
      </ol>
      <.question_foot note="Your answers go to the planner as one message.">
        <button type="submit" class="btn btn-primary btn-sm">Send answers</button>
      </.question_foot>
    </form>
    """
  end

  attr :who, :string, required: true
  attr :count, :integer, required: true
  attr :waiting, :boolean, default: false

  # A question card's header: who's asking, and whether they're waiting now.
  defp question_head(assigns) do
    ~H"""
    <header class="flex items-center gap-2 border-b border-base-content/10 px-3.5 py-2.5">
      <.icon name="hero-question-mark-circle-mini" class="size-4 shrink-0 text-primary" />
      <h3 class="min-w-0 flex-1 truncate text-sm font-medium">
        {@who} has {if @count == 1, do: "a question", else: "#{@count} questions"}
      </h3>
      <span :if={@waiting} class="flex shrink-0 items-center gap-1.5 text-xs text-primary">
        <span class="size-1.5 animate-pulse rounded-full bg-primary"></span> Waiting for you
      </span>
    </header>
    """
  end

  attr :n, :integer, required: true
  attr :question, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  # One question, numbered like a plan's tasks: its first sentence in bold, the rest
  # under it, then how to answer.
  defp question_row(assigns) do
    {title, rest} = split_question(assigns.question)
    assigns = assign(assigns, title: title, rest: rest)

    ~H"""
    <li class="flex gap-2.5 px-3.5 py-3">
      <span class="w-4 shrink-0 pt-px text-right text-xs tabular-nums text-base-content/40">
        {@n}
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-sm font-medium leading-snug">{@title}</p>
        <p :if={@rest} class="mt-0.5 text-[13px] leading-snug text-base-content/60">{@rest}</p>
        <p :if={@hint} class="mt-0.5 text-xs text-base-content/50">{@hint}</p>
        <div class="mt-2">{render_slot(@inner_block)}</div>
      </div>
    </li>
    """
  end

  attr :name, :string, required: true
  attr :options, :list, required: true, doc: "[{value, label}]"
  attr :checked, :any, default: nil
  attr :recommend, :boolean, default: true, doc: "whether the first option is the recommended one"
  attr :own, :string, default: nil, doc: "the field for an answer of your own, as the last row"

  # A question's options as one list, a row each; the first is the one the agent
  # recommends. What an option says in brackets ("please specify", a path) is shown
  # lighter, after it. An answer of your own is the list's last row.
  defp option_list(assigns) do
    ~H"""
    <div class="divide-y divide-base-content/[0.07] overflow-hidden rounded-lg border border-base-content/10">
      <label
        :for={{{value, label}, j} <- Enum.with_index(@options)}
        class="group/opt flex cursor-pointer items-center gap-2.5 px-3 py-2 text-[13px] leading-snug transition-colors hover:bg-base-content/[0.03] has-[input:checked]:bg-primary/[0.08]"
      >
        <input
          type="radio"
          name={@name}
          value={value}
          checked={to_string(value) == to_string(@checked)}
          class="peer sr-only"
        />
        <span class="size-3.5 shrink-0 rounded-full border border-base-content/30 transition-all peer-checked:border-[4px] peer-checked:border-primary peer-focus-visible:ring-2 peer-focus-visible:ring-primary/40"></span>
        <span class="min-w-0 flex-1">
          <span class="text-base-content/85 group-has-[input:checked]/opt:text-base-content">
            {elem(option_label(label), 0)}
          </span>
          <span :if={elem(option_label(label), 1)} class="ml-1 text-base-content/45">
            {elem(option_label(label), 1)}
          </span>
          <span
            :if={@recommend and j == 0}
            class="ml-1.5 inline-block rounded bg-primary/10 px-1.5 align-[1px] text-[10.5px] font-medium text-primary"
          >
            Recommended
          </span>
        </span>
        <.icon
          name="hero-check-mini"
          class="size-4 shrink-0 text-primary opacity-0 transition-opacity group-has-[input:checked]/opt:opacity-100"
        />
      </label>
      <label
        :if={@own}
        class="flex items-center gap-2.5 px-3 py-1.5 focus-within:bg-base-content/[0.03]"
      >
        <.icon name="hero-pencil-square-micro" class="size-3.5 shrink-0 text-base-content/35" />
        <input
          type="text"
          name={@own}
          autocomplete="off"
          placeholder="Add details, or write your own answer"
          class="h-6 min-w-0 flex-1 bg-transparent text-[13px] outline-none placeholder:text-base-content/35"
        />
      </label>
    </div>
    """
  end

  # A question's first sentence, and the rest of it: "Where does it go? The invoices
  # page is the obvious place…"
  defp split_question(question) do
    case Regex.run(~r/\A(.+?\?)\s+(\S.*)\z/s, String.trim(question || "")) do
      [_, title, rest] -> {title, rest}
      _ -> {question, nil}
    end
  end

  # An option's words, and what it says in brackets at the end, shown lighter:
  # "Supplementary documentation (please specify what)".
  defp option_label(label) do
    case Regex.run(~r/\A(.+?)\s*\(([^()]+)\)\s*\z/, to_string(label)) do
      [_, words, aside] -> {words, aside}
      _ -> {label, nil}
    end
  end

  attr :note, :string, required: true
  slot :inner_block, required: true

  defp question_foot(assigns) do
    ~H"""
    <footer class="flex flex-wrap items-center gap-2 border-t border-base-content/10 px-3.5 py-2.5">
      <span class="mr-auto text-xs text-base-content/55">{@note}</span>
      {render_slot(@inner_block)}
    </footer>
    """
  end

  # A field that holds the answer of your own to another field's options.
  defp own_answer_field?(name, props) do
    String.ends_with?(name, "_other") and
      Map.has_key?(props, String.trim_trailing(name, "_other"))
  end

  # Field names in reading order: answer_2 before answer_10.
  defp natural(name) do
    for part <- Regex.split(~r/(\d+)/, name, include_captures: true, trim: true) do
      case Integer.parse(part) do
        {n, ""} -> {0, n}
        _ -> {1, part}
      end
    end
  end
end
