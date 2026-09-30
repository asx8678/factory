// Chat shortcuts: ⌘K / Ctrl+K puts you in the message box; P opens Plan (when you're
// not typing somewhere, and no link, button or menu has the focus).
import { CONTROLS } from "./question_keys.js"

export const ChatKeys = {
  mounted() {
    this.onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault()
        document.getElementById("chat-input")?.focus()
        return
      }
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (!this.el.contains(e.target) && e.target !== document.body) return
      if (e.target.closest(CONTROLS)) return
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
