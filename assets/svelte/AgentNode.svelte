<script>
  import { Handle, Position } from "@xyflow/svelte"

  let { data, selected, isConnectable } = $props()

  const dot = {
    running: "bg-info",
    waiting: "bg-warning",
    error: "bg-error",
    done: "bg-success",
  }
</script>

<div
  class={[
    "w-44 rounded-box border bg-base-100 px-3 py-2.5 text-base-content shadow-sm",
    selected ? "border-primary ring-2 ring-primary/30" : "border-base-300",
  ]}
>
  <Handle type="target" position={Position.Top} {isConnectable} class={[!isConnectable && "!opacity-0"]} />
  <div class="flex items-center gap-2">
    <span class={["size-2 shrink-0 rounded-full", dot[data.status] ?? "bg-base-content/30"]}></span>
    <span class="truncate text-sm font-semibold">{data.name}</span>
  </div>
  <div class="mt-0.5 truncate pl-4 font-mono text-[10px] opacity-60">{data.model}</div>
  <Handle type="source" position={Position.Bottom} {isConnectable} class={[!isConnectable && "!opacity-0"]} />
</div>
