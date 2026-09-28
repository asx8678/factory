// The prompt editor's text box: grows with its content (the window scrolls, so the
// line numbers beside it stay aligned), and ⌘S / Ctrl+S / ⌘↵ save.
// With data-drop, a .md or .txt file dropped on it replaces its text.
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
    if (this.el.dataset.drop !== undefined) this.acceptDrops()
    this.resize()
    this.el.focus()
    this.el.setSelectionRange(this.el.value.length, this.el.value.length)
  },
  updated() {
    this.resize()
  },
  acceptDrops() {
    const el = this.el
    const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes("Files")
    const off = () => el.classList.remove("drop-active")
    el.addEventListener("dragover", (e) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      el.classList.add("drop-active")
    })
    el.addEventListener("dragleave", off)
    el.addEventListener("drop", async (e) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      off()
      const file = e.dataTransfer.files[0]
      if (!/\.(md|markdown|txt)$/i.test(file.name) || file.size > 2_000_000) {
        this.pushEvent("drop_rejected", { name: file.name })
        return
      }
      const text = await file.text()
      if (el.value.trim() && !confirm(`Replace what's written here with ${file.name}?`)) return
      el.value = text
      el.dispatchEvent(new Event("input", { bubbles: true }))
      this.resize()
    })
  },
}
