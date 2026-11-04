// phx-hook="MarkdownEditor" (ClaudeControlPlaneWeb.EditorComponents): a
// toolbar over the editor's textarea. Buttons with data-md-action format the
// selection, buttons with data-md-insert put their text at the cursor; ⌘/Ctrl
// B, I and K are bold, italic and link. The textarea grows with its text. Each
// change fires an "input" event, so the form's phx-change sees it as typing.

// Around the selection: before, after, and the text used when nothing is selected.
const WRAPS = {
  bold: ["**", "**", "negrito"],
  italic: ["_", "_", "itálico"],
  code: ["`", "`", "código"],
  link: ["[", "](https://)", "texto do link"],
}

// At the start of each selected line.
const PREFIXES = {
  heading: () => "## ",
  bullet: () => "- ",
  numbered: n => `${n + 1}. `,
  quote: () => "> ",
}

const SHORTCUTS = {b: "bold", i: "italic", k: "link"}

export const MarkdownEditor = {
  mounted() {
    this.el.addEventListener("click", event => {
      const button = event.target.closest("[data-md-action], [data-md-insert]")
      if (!button || !this.el.contains(button)) return
      event.preventDefault()

      if (button.dataset.mdInsert) this.insert(button.dataset.mdInsert)
      else this.format(button.dataset.mdAction)

      const menu = button.closest("details")
      if (menu) menu.open = false
    })

    this.el.addEventListener("keydown", event => {
      if (event.target !== this.textarea() || !(event.metaKey || event.ctrlKey)) return
      const action = SHORTCUTS[event.key.toLowerCase()]
      if (!action) return
      event.preventDefault()
      this.format(action)
    })

    this.el.addEventListener("input", event => {
      if (event.target === this.textarea()) this.grow()
    })

    this.grow()
  },

  updated() { this.grow() },

  textarea() { return this.el.querySelector("textarea") },

  format(action) {
    if (WRAPS[action]) this.wrap(...WRAPS[action])
    else if (PREFIXES[action]) this.prefix(PREFIXES[action])
  },

  wrap(before, after, placeholder) {
    const textarea = this.textarea()
    const {selectionStart: start, selectionEnd: end, value} = textarea
    const text = value.slice(start, end) || placeholder
    textarea.setRangeText(before + text + after, start, end, "end")
    // The wrapped text stays selected, ready to be typed over.
    textarea.setSelectionRange(start + before.length, start + before.length + text.length)
    this.changed(textarea)
  },

  prefix(prefixFor) {
    const textarea = this.textarea()
    const {selectionStart, selectionEnd, value} = textarea
    const start = value.lastIndexOf("\n", selectionStart - 1) + 1
    const lines = value.slice(start, selectionEnd).split("\n")
    const text = lines.map((line, n) => prefixFor(n) + line).join("\n")
    textarea.setRangeText(text, start, selectionEnd, "select")
    this.changed(textarea)
  },

  insert(text) {
    const textarea = this.textarea()
    textarea.setRangeText(text, textarea.selectionStart, textarea.selectionEnd, "end")
    this.changed(textarea)
  },

  changed(textarea) {
    textarea.focus()
    textarea.dispatchEvent(new Event("input", {bubbles: true}))
  },

  // Hidden (the preview is showing): nothing to measure.
  grow() {
    const textarea = this.textarea()
    if (!textarea || textarea.offsetParent === null) return
    textarea.style.height = "auto"
    textarea.style.height = `${textarea.scrollHeight + 2}px`
  },
}
