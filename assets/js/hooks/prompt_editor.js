// The prompt editor's text box: grows with its content (the window scrolls, so the
// line numbers beside it stay aligned), and ⌘S / Ctrl+S / ⌘↵ save.
// With data-drop, a .md or .txt file dropped on it replaces its text. With
// data-autofocus, it takes the focus when it appears, cursor at the end.
import {acceptDrops} from "./drop_text"

export const PromptEditor = {
  mounted() {
    this.resize = () => {
      this.el.style.height = "auto"
      this.el.style.height = this.el.scrollHeight + "px"
    }
    this.el.addEventListener("input", this.resize)
    this.el.addEventListener("keydown", (e) => {
      const mod = e.metaKey || e.ctrlKey
      if (mod && (e.key === "s" || e.key === "Enter")) {
        e.preventDefault()
        this.el.form.requestSubmit()
      }
    })
    if (this.el.dataset.drop !== undefined) {
      acceptDrops(this, {
        one: true,
        accept: (file) => /\.(md|markdown|txt)$/i.test(file.name),
        apply: ([text], [file]) => {
          const el = this.el
          if (el.value.trim() && !confirm(`Replace what's written here with ${file.name}?`)) return
          el.value = text
          el.dispatchEvent(new Event("input", { bubbles: true }))
          this.resize()
        },
      })
    }
    this.resize()
    if (this.el.dataset.autofocus !== undefined) {
      this.el.focus()
      this.el.setSelectionRange(this.el.value.length, this.el.value.length)
    }
  },
  updated() {
    this.resize()
  },
}
