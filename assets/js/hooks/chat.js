// Message box: Enter sends, Shift+Enter adds a line, the box grows with its text.
export const ChatInput = {
  mounted() {
    this.resize = () => {
      this.el.style.height = "auto"
      this.el.style.height = Math.min(this.el.scrollHeight, 200) + "px"
    }
    this.el.addEventListener("input", this.resize)
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault()
        this.el.form.requestSubmit()
      }
    })
    this.handleEvent("chat:sent", () => {
      this.el.value = ""
      this.resize()
    })
    this.handleEvent("chat:fill", ({ text }) => {
      this.el.value = text
      this.el.focus()
      this.el.setSelectionRange(text.length, text.length)
      this.el.dispatchEvent(new Event("input", { bubbles: true }))
    })
  },
}

// Keeps the message list scrolled to the newest message.
export const ChatScroll = {
  mounted() {
    this.scroller = this.el.closest("[data-scroll]")
    this.toBottom()
    this.observer = new MutationObserver(() => this.toBottom())
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  toBottom() {
    this.scroller.scrollTop = this.scroller.scrollHeight
  },
  destroyed() {
    this.observer.disconnect()
  },
}
