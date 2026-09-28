// A text box you can drop files on: each text file's contents go into the box, where
// the cursor is (or at the end), and LiveView hears the change as if typed.
const TEXT = /\.(md|markdown|txt|text|rst|adoc|json|ya?ml|toml|csv|feature|html?)$/i
const MAX = 2_000_000

export const DropText = {
  mounted() {
    const el = this.el
    const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes("Files")
    const off = () => el.classList.remove("drop-active")

    el.addEventListener("dragover", (e) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      e.stopPropagation()
      el.classList.add("drop-active")
    })
    el.addEventListener("dragleave", off)
    el.addEventListener("drop", async (e) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      e.stopPropagation()
      off()

      const files = [...e.dataTransfer.files]
      const texts = []
      for (const file of files) {
        if (!TEXT.test(file.name) || file.size > MAX) {
          this.pushEvent("drop_rejected", { name: file.name })
          continue
        }
        texts.push((await file.text()).trim())
      }
      if (texts.length === 0) return

      const added = texts.join("\n\n")
      const at = el.selectionStart ?? el.value.length
      const before = el.value.slice(0, at).replace(/\s*$/, "")
      const after = el.value.slice(at).replace(/^\s*/, "")
      el.value = [before, added, after].filter((s) => s !== "").join("\n\n")
      el.dispatchEvent(new Event("input", { bubbles: true }))
      el.focus()
    })
  },
}
