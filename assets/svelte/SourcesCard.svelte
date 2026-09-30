<script>
  // Under the canvas toolbar: a small green button to add a data source. Each source
  // then shows as its own card on the canvas.
  import { getContext } from "svelte"

  let { sources } = $props()
  const { push } = getContext("factory")
</script>

<div class="inline-flex items-center gap-0.5 rounded-lg border border-base-content/10 bg-surface p-0.5 shadow-sm">
  <button
    type="button"
    class="inline-flex h-7 items-center gap-1 rounded-md px-2 text-sm font-medium text-success transition-colors hover:bg-success/10"
    onclick={() => push("sources_open", { add: "true" })}
  >
    <span class="grid place-items-center">
      <span class="hero-plus-micro size-3.5"></span>
    </span>
    Add data source
  </button>
  {#if sources.length}
    <button
      type="button"
      class="h-7 rounded-md px-2 text-sm text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content"
      onclick={() => push("sources_open", {})}
    >
      Manage {sources.length}
    </button>
  {/if}
</div>
