// Number keys pick: pressing 1–9 while you're not typing clicks the element inside
// with that data-key, e.g. a workflow on the start screen.
export const NumberKeys = {
  mounted() {
    this.onKey = (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest("input, textarea, select, [contenteditable]")) return
      const target = this.el.querySelector(`[data-key="${e.key}"]`)
      if (target) {
        e.preventDefault()
        target.click()
      }
    }
    window.addEventListener("keydown", this.onKey)
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  },
}
