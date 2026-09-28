<script>
  import { Handle, Position } from "@xyflow/svelte"
  import { getContext } from "svelte"

  let { id, data, selected, isConnectable } = $props()
  const { push, readonly } = getContext("factory")

  // One icon per agent kind (same list as FactoryWeb.AgentKinds). Class names must stay
  // literal so Tailwind's heroicons plugin generates them.
  const icons = {
    general: "hero-cpu-chip",
    orchestrator: "hero-rectangle-group",
    planner: "hero-clipboard-document-list",
    coder: "hero-code-bracket",
    tester: "hero-beaker",
    reviewer: "hero-magnifying-glass",
    researcher: "hero-book-open",
    writer: "hero-pencil-square",
  }

  const tone = { running: "text-info", waiting: "text-warning", error: "text-error", done: "text-success" }
  const dot = { running: "bg-info", waiting: "bg-warning", error: "bg-error", done: "bg-success" }
  const label = { running: "Running", waiting: "Waiting", error: "Failed", done: "Done" }

  const roles = [
    ["general", "General"],
    ["orchestrator", "Orchestrator"],
    ["planner", "Planner"],
    ["coder", "Coder"],
    ["tester", "Tester"],
    ["reviewer", "Reviewer"],
    ["researcher", "Researcher"],
    ["writer", "Writer"],
  ]
  let roleMenu = $state(false)
  let roleBox = $state()

  function pickRole(kind) {
    roleMenu = false
    if (kind !== data.kind) push("kind", { id, kind })
  }

  // Close the role menu on a click outside it or Escape.
  $effect(() => {
    if (!roleMenu) return
    const away = (e) => roleBox && !roleBox.contains(e.target) && (roleMenu = false)
    const esc = (e) => e.key === "Escape" && (roleMenu = false)
    window.addEventListener("pointerdown", away, true)
    window.addEventListener("keydown", esc)
    return () => {
      window.removeEventListener("pointerdown", away, true)
      window.removeEventListener("keydown", esc)
    }
  })

  const fmtTokens = (n) => (n >= 999500 ? (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M" : n >= 1000 ? Math.round(n / 1000) + "k" : `${n}`)
  let contextPct = $derived(data.usage?.context_pct)
  let contextTip = $derived(
    contextPct == null && data.usage?.compacted_from != null
      ? `Compacted from ${fmtPct(data.usage.compacted_from)} · new size shows after the next reply`
      : contextPct == null
      ? "No Kiro session right now"
      : data.usage.window
        ? `Context: ${fmtTokens(data.usage.context_tokens)} of ≈${fmtTokens(data.usage.window)} tokens (window estimated)`
        : `Context: ${contextPct}% used`,
  )
  let contextColor = $derived(contextPct >= 80 ? "bg-error" : contextPct >= 50 ? "bg-warning" : "bg-info")

  // "3 turns · 0.14 credits · 2% context", once the agent has done a turn on Kiro.
  const fmtCredits = (n) => (n >= 10 ? n.toFixed(1) : (n ?? 0).toFixed(2))
  const fmtPct = (p) => (p < 10 ? p.toFixed(1) : Math.round(p)) + "%"
  let usage = $derived(
    data.usage?.turns
      ? [
          `${data.usage.turns} ${data.usage.turns === 1 ? "turn" : "turns"}`,
          `${fmtCredits(data.usage.credits)} credits`,
          data.usage.context_pct != null && `${fmtPct(data.usage.context_pct)} context`,
        ]
          .filter(Boolean)
          .join(" · ")
      : null,
  )

  let status = $derived(
    data.status === "idle" || !label[data.status] ? "Idle" : data.activity ? `${label[data.status]}: ${data.activity}` : label[data.status],
  )
</script>

<div
  class={[
    "group w-60 rounded-2xl border bg-surface text-base-content shadow-sm transition-[box-shadow,border-color] hover:shadow-md",
    selected ? "border-primary/70 ring-2 ring-primary/20" : "border-base-content/10 hover:border-base-content/20",
  ]}
>
  {#each [Position.Top, Position.Right, Position.Bottom, Position.Left] as side}
    <Handle type="source" id={side} position={side} {isConnectable} class={[!isConnectable && "!hidden"]} />
  {/each}

  <div class="flex items-center gap-2.5 px-3 pt-3">
    <div class="relative shrink-0" bind:this={roleBox}>
      {#if readonly}
        <span class="grid size-9 place-items-center rounded-xl bg-base-content/[0.06]">
          <span class={[icons[data.kind] ?? icons.general, "size-5 opacity-75"]}></span>
        </span>
      {:else}
        <button
          type="button"
          title="Change role"
          aria-label="Change role"
          aria-expanded={roleMenu}
          class="nodrag grid size-9 place-items-center rounded-xl bg-base-content/[0.06] transition-colors hover:bg-base-content/10 hover:ring-1 hover:ring-base-content/15"
          onclick={(e) => {
            e.stopPropagation()
            roleMenu = !roleMenu
          }}
        >
          <span class={[icons[data.kind] ?? icons.general, "size-5 opacity-75"]}></span>
        </button>
      {/if}
      {#if roleMenu}
        <div class="nodrag nowheel absolute left-0 top-11 z-50 w-48 rounded-xl border border-base-content/10 bg-surface p-1 shadow-xl" role="menu">
          {#each roles as [kind, label]}
            <button
              type="button"
              role="menuitem"
              class={["flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-xs hover:bg-base-content/[0.06]", kind === (data.kind ?? "general") && "bg-base-content/[0.06] font-medium"]}
              onclick={(e) => {
                e.stopPropagation()
                pickRole(kind)
              }}
            >
              <span class={[icons[kind], "size-4 opacity-70"]}></span>
              <span class="flex-1">{label}</span>
              {#if kind === (data.kind ?? "general")}<span class="hero-check-mini size-4 opacity-60"></span>{/if}
            </button>
          {/each}
        </div>
      {/if}
    </div>
    <div class="min-w-0 flex-1">
      <div class="truncate text-sm font-semibold">{data.name}</div>
      <div class="truncate text-[11px] opacity-55">{data.kiro ? data.model : "Not connected"}</div>
    </div>
    {#if data.kiro}
      <span class="shrink-0 self-start rounded-md bg-primary/15 px-1.5 py-0.5 text-[10px] font-medium text-primary" title={data.shared ? "Talks in the shared Kiro session" : "Has its own Kiro session"}>{data.shared ? "Kiro · shared" : "Kiro"}</span>
    {/if}
  </div>

  {#if usage}
    <div class="mt-3 flex items-center gap-3 px-3 text-[11px] tabular-nums">
      <div class="group/ctx flex min-w-0 flex-1 items-center gap-2" title={contextTip}>
        {#if !readonly && contextPct != null && data.live}
          <button
            type="button"
            title="Compact context: Kiro summarizes the conversation so it takes less room"
            class="nodrag -my-1 -ml-1 hidden h-6 flex-1 items-center justify-center gap-1 rounded-md bg-error/10 px-1.5 font-medium text-error hover:bg-error/20 group-hover/ctx:flex"
            onclick={(e) => {
              e.stopPropagation()
              push("compact", { id })
            }}
          >
            <span class="hero-document-minus-mini size-3.5"></span>
            Compact
          </button>
        {/if}
        <span class={["opacity-50", contextPct != null && !readonly && data.live && "group-hover/ctx:hidden"]}>Context</span>
        <!-- While hovering, the Compact button takes the place of the whole indicator. -->
        <div class={["h-1 min-w-8 flex-1 overflow-hidden rounded-full bg-base-content/10", contextPct != null && !readonly && data.live && "group-hover/ctx:hidden"]}>
          {#if contextPct != null}
            <div class={["h-full rounded-full", contextColor]} style={`width: ${Math.max(contextPct, 2)}%`}></div>
          {/if}
        </div>
        <span class={["shrink-0 opacity-70", contextPct != null && !readonly && data.live && "group-hover/ctx:hidden"]}>{contextPct == null ? "–" : fmtPct(contextPct)}</span>
      </div>
      <span class="flex items-center gap-1 opacity-70" title={`${data.usage.turns} ${data.usage.turns === 1 ? "turn" : "turns"} with Kiro`}>
        <span class="hero-arrow-path-rounded-square-mini size-3.5 opacity-70"></span>{data.usage.turns}
      </span>
      <span class="flex items-center gap-1 opacity-70" title="Kiro credits used">
        <span class="hero-bolt-mini size-3.5 opacity-70"></span>{fmtCredits(data.usage.credits)}
      </span>
    </div>
  {/if}

  <div class="mt-3 flex h-9 items-center gap-2 border-t border-base-content/10 px-3 text-xs">
    <span class="relative flex size-2 shrink-0">
      {#if data.status === "running"}
        <span class="absolute inline-flex size-full animate-ping rounded-full bg-info opacity-60 motion-reduce:hidden"></span>
      {/if}
      <span class={["relative inline-flex size-2 rounded-full", dot[data.status] ?? "bg-base-content/30"]}></span>
    </span>
    <span class={["min-w-0 flex-1 truncate", tone[data.status] ?? "opacity-60"]} title={status}>{status}</span>
    {#if !readonly}
      <!-- Hidden with visibility (not display) so it keeps its space and nothing shifts on hover. -->
      <button
        type="button"
        class="nodrag invisible shrink-0 rounded-md px-2 py-1 font-medium hover:bg-base-content/[0.06] group-hover:visible"
        onclick={(e) => {
          e.stopPropagation()
          push("chat", { id })
        }}
      >
        Chat
      </button>
      <button
        type="button"
        title={data.has_context ? "Edit prompt" : "Add a prompt"}
        class={[
          // Calm by default, yellow on hover.
          "nodrag nopan relative -mr-1 flex h-7 shrink-0 items-center gap-1 rounded-lg border px-2 font-medium transition-colors",
          "hover:border-amber-400/50 hover:bg-amber-300/15 hover:text-amber-700 dark:hover:text-amber-200 [&:hover>.hero-document-text]:text-current",
          data.has_context
            ? "border-base-content/15 text-base-content/70 [&>.hero-document-text]:text-amber-600/70 dark:[&>.hero-document-text]:text-amber-200/60"
            : "border-base-content/10 text-base-content/45",
        ]}
        onclick={(e) => {
          e.stopPropagation()
          push("context", { id })
        }}
      >
        <span class="hero-document-text size-4"></span>
        Prompt
        {#if data.has_context}
          <span class="absolute -right-1 -top-1 size-1.5 rounded-full bg-amber-300/70 ring-2 ring-surface"></span>
        {/if}
      </button>
    {:else if data.has_context}
      <span class="hero-document-text size-4 shrink-0 text-amber-600/80 dark:text-amber-200/70" title="Has a prompt"></span>
    {/if}
  </div>
</div>
