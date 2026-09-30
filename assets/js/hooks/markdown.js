import hljs from "highlight.js/lib/common"
import elixir from "highlight.js/lib/languages/elixir"
import erlang from "highlight.js/lib/languages/erlang"
import dockerfile from "highlight.js/lib/languages/dockerfile"

// The common bundle has JS, Python, Rust, Go, SQL, shell and more, but not these.
hljs.registerLanguage("elixir", elixir)
hljs.registerLanguage("erlang", erlang)
hljs.registerLanguage("dockerfile", dockerfile)

// Finishes a rendered message: highlights code blocks, gives each a header with
// its language and a Copy button, and opens links in a new tab.
export const Markdown = {
  mounted() {
    this.el.querySelectorAll("pre > code").forEach((code) => {
      const pre = code.parentElement
      if (pre.dataset.ready) return
      pre.dataset.ready = "true"
      const lang = [...code.classList].find((c) => c.startsWith("language-"))?.slice(9)
      hljs.highlightElement(code)

      const bar = document.createElement("div")
      bar.className = "code-bar"
      const label = document.createElement("span")
      label.textContent = lang || "code"
      const button = document.createElement("button")
      button.type = "button"
      button.textContent = "Copy"
      button.addEventListener("click", () => copy(code.innerText, button))
      bar.append(label, button)

      // One rounded frame holding the header and the code.
      const frame = document.createElement("div")
      frame.className = "code-frame"
      pre.replaceWith(frame)
      frame.append(bar, pre)
    })
    this.el.querySelectorAll("a[href]").forEach((a) => {
      a.target = "_blank"
      a.rel = "noopener noreferrer"
    })
  },
}

export function copy(text, button) {
  const label = button?.textContent
  const say = (word) => {
    if (!button) return
    button.textContent = word
    setTimeout(() => (button.textContent = label), 1500)
  }
  if (!navigator.clipboard) return say("Copy failed")
  navigator.clipboard.writeText(text).then(() => say("Copied"), () => say("Copy failed"))
}
