// Closes a flash message after data-dismiss-after milliseconds by clicking it, which
// clears it on the server too. Hovering pauses the countdown so it can be read.
export const AutoDismiss = {
  mounted() {
    this.ms = parseInt(this.el.dataset.dismissAfter, 10) || 4000
    this.start = () => {
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.el.click(), this.ms)
    }
    this.el.addEventListener("mouseenter", () => clearTimeout(this.timer))
    this.el.addEventListener("mouseleave", this.start)
    this.start()
  },
  updated() {
    this.start()
  },
  destroyed() {
    clearTimeout(this.timer)
  },
}
