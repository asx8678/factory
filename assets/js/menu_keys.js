// Keyboard behaviour for a popover with role="menu" (the role picker on an agent card,
// the "attach to" list on the canvas). Used as a Svelte attachment on the menu element:
//
//     <div role="menu" {@attach menuKeys(() => (open = false))}>
//
// When the menu appears its first item gets the focus; ArrowUp/ArrowDown move through
// the items and wrap around, Home/End jump to the ends, Escape closes it. When the menu
// goes away the focus returns to where it was before, usually the button that opened it.
export function menuKeys(close) {
  return (menu) => {
    const opener = document.activeElement
    const items = () => [...menu.querySelectorAll('[role="menuitem"]:not([disabled])')]
    const focusItem = (i) => {
      const list = items()
      if (list.length) list[(i + list.length) % list.length].focus()
    }
    const onKey = (e) => {
      const list = items()
      const at = list.indexOf(document.activeElement)
      switch (e.key) {
        case "ArrowDown":
          focusItem(at + 1)
          break
        case "ArrowUp":
          focusItem(at < 0 ? list.length - 1 : at - 1)
          break
        case "Home":
          focusItem(0)
          break
        case "End":
          focusItem(list.length - 1)
          break
        case "Escape":
          close()
          break
        default:
          return
      }
      e.preventDefault()
      e.stopPropagation()
    }
    menu.addEventListener("keydown", onKey)
    focusItem(0)
    return () => {
      menu.removeEventListener("keydown", onKey)
      if (opener && opener !== document.body && opener.isConnected) opener.focus()
    }
  }
}
