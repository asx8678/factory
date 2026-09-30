<script>
  // On the right of the canvas: the kinds of action to add, by group. Clicking one
  // adds it next to the selected agent (or after the last one); draw arrows to place it.
  let { types, onadd } = $props()
  let open = $state(true)

  const icons = {
    git_push: "hero-arrow-up-on-square-micro",
    github_pr: "hero-arrows-right-left-micro",
    azure_pr: "hero-arrows-right-left-micro",
    azure_item_update: "hero-pencil-square-micro",
    azure_item_close: "hero-check-badge-micro",
    github_issue: "hero-check-badge-micro",
    email: "hero-envelope-micro",
    webhook: "hero-chat-bubble-left-right-micro",
    api_request: "hero-globe-alt-micro",
    command: "hero-command-line-micro",
  }

  let groups = $derived(
    types.reduce((acc, t) => {
      ;(acc[t.group] ??= []).push(t)
      return acc
    }, {}),
  )
</script>

<div class="w-56 rounded-xl border border-base-content/10 bg-surface p-1.5 shadow-md">
  <button
    type="button"
    class="flex w-full items-center gap-1.5 rounded-lg px-1.5 py-1 text-left"
    onclick={() => (open = !open)}
    aria-expanded={open}
  >
    <span class="hero-bolt-micro size-3.5 text-warning"></span>
    <span class="text-[11px] font-semibold text-base-content/65">Actions</span>
    <span class={["hero-chevron-down-micro ml-auto size-3.5 opacity-50 transition-transform", !open && "-rotate-90"]}></span>
  </button>

  {#if open}
    <p class="px-1.5 pb-1 text-[10.5px] leading-snug text-base-content/50">
      Add one, then draw an arrow from the agent it follows.
    </p>
    {#each Object.entries(groups) as [group, items]}
      <p class="px-1.5 pb-0.5 pt-1.5 text-[11px] font-medium text-base-content/40">{group}</p>
      {#each items as t (t.type)}
        <button
          type="button"
          class="flex w-full items-center gap-2 rounded-lg px-1.5 py-1 text-left text-[12.5px] transition-colors hover:bg-warning/10"
          title={t.blurb}
          onclick={() => onadd(t.type)}
        >
          <span class="grid size-5 shrink-0 place-items-center rounded-md bg-warning/15 text-warning">
            <span class={[icons[t.type] ?? "hero-bolt-micro", "size-3"]}></span>
          </span>
          <span class="truncate">{t.label}</span>
          <span class="hero-plus-micro ml-auto size-3.5 opacity-40"></span>
        </button>
      {/each}
    {/each}
  {/if}
</div>
