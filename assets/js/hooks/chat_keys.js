// Chat shortcuts: ⌘K / Ctrl+K puts you in the message box; P opens Plan (when you're
// not typing somewhere).
export const ChatKeys = {
  mounted() {
    this.onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault()
        document.getElementById("chat-input")?.focus()
        return
      }
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (e.target.closest("input, textarea, select, [contenteditable]")) return
      if (e.key === "p" || e.key === "P") {
        e.preventDefault()
        this.pushEvent("tasks", {})
      }
    }
    window.addEventListener("keydown", this.onKey)
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  },
}
