// Text boxes you can drop files on. `acceptDrops` wires the drag-and-drop: the box gets
// `drop-active` while a file hovers, files `accept` turns down (or over 2 MB, or that
// can't be read) push `drop_rejected`, and the rest are read and handed to `apply` as text. `one: true`
// looks only at the first file dropped.
const MAX = 2_000_000

export function acceptDrops(hook, {accept, apply, one = false}) {
  const el = hook.el
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

    const files = one ? [...e.dataTransfer.files].slice(0, 1) : [...e.dataTransfer.files]
    const texts = []
    for (const file of files) {
      if (!accept(file) || file.size > MAX) {
        hook.pushEvent("drop_rejected", { name: file.name })
        continue
      }
      try {
        texts.push(await file.text())
      } catch {
        hook.pushEvent("drop_rejected", { name: file.name })
      }
    }
    if (texts.length === 0) return
    apply(texts, files)
  })
}

// A text box you can drop files on: each text file's contents go into the box, where
// the cursor is (or at the end), and LiveView hears the change as if typed.
const TEXT = /\.(md|markdown|txt|text|rst|adoc|json|ya?ml|toml|csv|feature|html?)$/i

export const DropText = {
  mounted() {
    const el = this.el
    acceptDrops(this, {
      accept: (file) => TEXT.test(file.name),
      apply: (texts) => {
        const added = texts.map((t) => t.trim()).join("\n\n")
        const at = el.selectionStart ?? el.value.length
        const before = el.value.slice(0, at).replace(/\s*$/, "")
        const after = el.value.slice(at).replace(/^\s*/, "")
        el.value = [before, added, after].filter((s) => s !== "").join("\n\n")
        el.dispatchEvent(new Event("input", { bubbles: true }))
        el.focus()
      },
    })
  },
}
