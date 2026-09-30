<script>
  // One data source on the canvas. Drag from its green circle to an agent to attach
  // it: that agent then gets the source in its prompt. Click the card to edit it.
  import { Handle, Position } from "@xyflow/svelte"
  import { getContext } from "svelte"

  let { data, selected, isConnectable } = $props()
  const { readonly } = getContext("factory")

  // One icon per kind (same as FactoryWeb.SourceParts). Class names stay literal so
  // Tailwind's heroicons plugin generates them.
  const icons = {
    azure_devops: "hero-cloud-micro",
    git: "hero-code-bracket-square-micro",
    folder: "hero-folder-open-micro",
    instructions: "hero-document-text-micro",
    meta_index: "hero-map-micro",
    pageindex: "hero-rectangle-stack-micro",
  }

  let note = $derived(
    !data.enabled
      ? "Off"
      : data.status === "syncing"
        ? "Syncing…"
        : data.status === "error"
          ? "Needs attention"
          : data.attached === 0
            ? "Not attached"
            : `Attached to ${data.attached} ${data.attached === 1 ? "agent" : "agents"}`,
  )
</script>

<div
  class={[
    "group w-44 rounded-xl border bg-surface text-base-content shadow-sm transition-[box-shadow,border-color] hover:shadow-md",
    selected ? "border-success ring-2 ring-success/25" : "border-success/40 hover:border-success/70",
    !data.enabled && "opacity-60",
  ]}
  title={`${data.detail}\n${note}`}
>
  {#each [Position.Right, Position.Bottom, Position.Top, Position.Left] as side}
    <Handle
      type="source"
      id={side}
      position={side}
      {isConnectable}
      class={["source-handle", !isConnectable && "!hidden"]}
    />
  {/each}

  <div class="flex items-center gap-2 px-2 py-1.5">
    <span class="grid size-6 shrink-0 place-items-center rounded-md bg-success/12 text-success">
      <span class={[icons[data.kind], "size-3.5"]}></span>
    </span>
    <div class="min-w-0 flex-1 leading-tight">
      <div class="truncate text-xs font-semibold">{data.name}</div>
      <div class="truncate text-[10px] opacity-55">{data.label}</div>
    </div>
    {#if data.status === "syncing"}
      <span class="loading loading-spinner loading-xs text-info" role="status" aria-label="Syncing"></span>
    {:else if data.status === "error"}
      <span class="size-1.5 shrink-0 rounded-full bg-error"></span>
      <span class="sr-only">Needs attention</span>
    {:else if data.attached === 0 || !data.enabled}
      <span class="size-1.5 shrink-0 rounded-full bg-warning"></span>
      <span class="sr-only">{data.enabled ? "Not attached" : "Off"}</span>
    {:else}
      <span class="size-1.5 shrink-0 rounded-full bg-success"></span>
      <span class="sr-only">Attached</span>
    {/if}
  </div>

  {#if (data.attached === 0 && data.enabled) || data.status === "error"}
    <div class={["border-t border-base-content/10 px-2 py-1 text-[10px]", data.status === "error" ? "text-error" : "text-warning"]}>
      {data.status === "error" ? "Needs attention" : readonly ? "Not attached" : "Not attached · drag → agent"}
    </div>
  {/if}
</div>
