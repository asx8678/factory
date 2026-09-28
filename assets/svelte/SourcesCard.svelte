<script>
  // Under the canvas toolbar: a small green button to add a data source. Each source
  // then shows as its own card on the canvas.
  import { getContext } from "svelte"

  let { sources } = $props()
  const { push } = getContext("factory")
</script>

<div class="inline-flex items-center gap-1 rounded-2xl border border-base-content/10 bg-surface p-1 shadow-md">
  <button
    type="button"
    class="group inline-flex h-8 items-center gap-1.5 rounded-xl border border-success/45 bg-success/10 pl-1.5 pr-3 text-sm font-medium transition-colors hover:border-success/70 hover:bg-success/20"
    onclick={() => push("sources_open", { add: "true" })}
  >
    <span class="grid size-5 place-items-center rounded-full bg-success text-success-content transition-transform group-hover:scale-110">
      <span class="hero-plus-micro size-3.5"></span>
    </span>
    Add data source
  </button>
  {#if sources.length}
    <button
      type="button"
      class="h-8 rounded-xl px-2.5 text-xs text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content"
      onclick={() => push("sources_open", {})}
    >
      Manage {sources.length}
    </button>
  {/if}
</div>
