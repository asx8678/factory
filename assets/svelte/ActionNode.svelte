<script>
  // An action on the canvas (commit and push, open a PR, email…): a step that isn't an
  // agent. Arrows into it mean "when that's done, do this"; arrows out go on to the next.
  import { Handle, Position } from "@xyflow/svelte"

  let { data, selected, isConnectable } = $props()

  // One icon per action type (same as FactoryWeb.ActionParts). Class names stay
  // literal so Tailwind's heroicons plugin generates them.
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

  let type = $derived(data.action?.type)
  let missing = $derived(data.missing ?? [])
</script>

<div
  class={[
    "group w-48 rounded-xl border bg-surface text-base-content shadow-sm transition-[box-shadow,border-color] hover:shadow-md",
    selected ? "border-warning ring-2 ring-warning/25" : "border-warning/45 hover:border-warning/75",
  ]}
>
  {#each [Position.Top, Position.Right, Position.Bottom, Position.Left] as side}
    <Handle type="source" id={side} position={side} {isConnectable} class={[!isConnectable && "!hidden"]} />
  {/each}

  <div class="flex items-center gap-2 px-2 py-1.5">
    <span class="grid size-6 shrink-0 place-items-center rounded-md bg-warning/15 text-warning">
      <span class={[icons[type] ?? "hero-bolt-micro", "size-3.5"]}></span>
    </span>
    <div class="min-w-0 flex-1 leading-tight">
      <div class="truncate text-xs font-semibold">{data.name}</div>
      <div class="truncate text-[10px] opacity-55">Action</div>
    </div>
    {#if data.status === "running"}
      <span class="loading loading-spinner loading-xs text-info"></span>
    {:else if data.status === "error"}
      <span class="size-1.5 shrink-0 rounded-full bg-error" title={data.activity}></span>
    {:else if data.status === "done"}
      <span class="hero-check-micro size-3.5 text-success" title={data.activity}></span>
    {:else if missing.length}
      <span class="size-1.5 shrink-0 rounded-full bg-warning"></span>
    {/if}
  </div>

  {#if missing.length}
    <div class="border-t border-base-content/10 px-2 py-1 text-[10px] text-warning">Needs setup: {missing.join(", ")}</div>
  {/if}
</div>
