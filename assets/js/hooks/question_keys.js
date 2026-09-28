// Kiro's questions: A, B, C… pick an option, unless you're typing an answer of your own,
// and Enter moves to the next question (the form's submit).
export const QuestionKeys = {
  mounted() {
    this.onKey = (e) => {
      if (e.key === "Enter" && !e.target.closest("button, textarea, input:not([type=radio])")) {
        e.preventDefault()
        this.el.requestSubmit()
        return
      }
      if (e.metaKey || e.ctrlKey || e.altKey || e.target.matches("input[type=text], input:not([type]), textarea")) return
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
