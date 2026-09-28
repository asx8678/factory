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

// Follow new replies only while the reader stays near the bottom.
export const ChatScroll = {
  mounted() {
    this.scroller = this.el.closest("[data-scroll]")
    this.jump = this.el.closest("#chat").querySelector("#jump-to-latest")
    this.following = true
    this.onScroll = () => {
      this.following = this.el.dataset.history !== "true" &&
        this.scroller.scrollHeight - this.scroller.clientHeight - this.scroller.scrollTop <= 80
      this.showJump()
    }
    this.onJump = () => {
      if (this.el.dataset.history === "true") this.pushEvent("latest", {})
      else this.toBottom()
    }
    this.scroller.addEventListener("scroll", this.onScroll, { passive: true })
    this.jump.addEventListener("click", this.onJump)
    this.handleEvent("chat:latest", () => this.toBottom())
    this.toBottom()
    this.observer = new MutationObserver(() => {
      if (this.following) this.toBottom()
      else this.showJump()
    })
    // Watch the whole scroll area: agent replies stream in below the message list.
    this.observer.observe(this.scroller, { childList: true, subtree: true, characterData: true })
  },
  beforeUpdate() {
    // Anchor the first visible message when an earlier page is prepended.
    const top = this.scroller.getBoundingClientRect().top
    const element = Array.from(this.el.children).find((child) => child.getBoundingClientRect().bottom > top)
    this.anchor = element && { element, top: element.getBoundingClientRect().top }
  },
  updated() {
    if (this.el.dataset.history === "true") this.following = false
    if (!this.following && this.anchor?.element.isConnected) {
      this.scroller.scrollTop += this.anchor.element.getBoundingClientRect().top - this.anchor.top
    }
    this.anchor = null
    this.showJump()
  },
  showJump() {
    this.jump.hidden = this.following && this.el.dataset.history !== "true"
  },
  toBottom() {
    this.following = true
    this.scroller.scrollTop = this.scroller.scrollHeight
    this.showJump()
  },
  destroyed() {
    this.observer.disconnect()
    this.scroller.removeEventListener("scroll", this.onScroll)
    this.jump.removeEventListener("click", this.onJump)
  },
}
