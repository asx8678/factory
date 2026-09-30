// Kiro's questions: A, B, C… pick an option, unless you're typing an answer of your own,
// and Enter moves to the next question (the form's submit). The shortcuts only apply
// while nothing outside the form has the focus, and never take a key from a control
// that uses it itself (links, buttons, menus, text boxes).
export const CONTROLS = "input, textarea, select, button, summary, a, [contenteditable], [role=menuitem]"

export const QuestionKeys = {
  mounted() {
    this.onKey = (e) => {
      const inside = this.el.contains(e.target)
      if (!inside && e.target !== document.body) return
      if (e.key === "Enter") {
        if (inside && e.target.closest("button, textarea, input:not([type=radio]), a, summary, [role=menuitem]")) return
        e.preventDefault()
        this.el.requestSubmit()
        return
      }
      if (e.metaKey || e.ctrlKey || e.altKey) return
      // Letters still pick while an option's own radio has the focus.
      if (e.target.closest(CONTROLS) && !e.target.matches("input[type=radio]")) return
      const option = this.el.querySelector(`[data-key="${e.key.toLowerCase()}"]`)
      if (!option) return
      e.preventDefault()
      const radio = option.querySelector("input[type=radio]")
      radio.checked = true
      radio.dispatchEvent(new Event("input", { bubbles: true }))
      // "Something else" takes typing: put the cursor in its box.
      if (radio.value === "__other") option.querySelector("input:not([type=radio])")?.focus()
    }
    window.addEventListener("keydown", this.onKey)
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  },
}
