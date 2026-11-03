// Highlights the code blocks of rendered Markdown (artifacts, answers):
// keywords, strings, comments and numbers, for the languages agents write
// most. Small on purpose: colors come from CSS classes (tok-*) with light and
// dark variants in app.css, so the page's theme applies.

const KEYWORDS = {
  elixir: "def defp defmodule do end fn if else unless case cond with when for import alias use require true false nil and or not in raise rescue try after receive quote unquote",
  javascript: "const let var function return if else for while do switch case break continue new class extends import export from default async await try catch finally throw typeof instanceof null undefined true false this",
  python: "def class return if elif else for while in not and or import from as with try except finally raise lambda None True False self pass yield async await",
  shell: "if then else elif fi for in do done while case esac function return export local echo cd exit",
  sql: "select from where join left right inner outer on group by order having insert into values update set delete create table alter drop index and or not null as limit",
  ruby: "def end class module if elsif else unless case when do while return yield require nil true false self",
  go: "func package import return if else for range switch case type struct interface map chan go defer var const nil true false",
  rust: "fn let mut pub struct enum impl trait use mod match if else for while loop return self Self true false None Some Ok Err",
}
KEYWORDS.typescript = KEYWORDS.javascript + " interface type enum implements readonly"
KEYWORDS.js = KEYWORDS.javascript
KEYWORDS.ts = KEYWORDS.typescript
KEYWORDS.ex = KEYWORDS.exs = KEYWORDS.heex = KEYWORDS.elixir
KEYWORDS.py = KEYWORDS.python
KEYWORDS.bash = KEYWORDS.sh = KEYWORDS.zsh = KEYWORDS.shell

const COMMENT = {elixir: "#", python: "#", shell: "#", ruby: "#", sql: "--"}
const commentFor = lang => COMMENT[lang] || (/(^|_)(ex|exs|heex|py|bash|sh|zsh)$/.test(lang) ? "#" : "//")

const escape = text => text.replace(/[&<>]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;"}[c]))
const span = (cls, text) => `<span class="tok-${cls}">${escape(text)}</span>`

export function highlight(code, lang) {
  const keywords = new Set((KEYWORDS[lang] || "").split(" ").filter(Boolean))
  const comment = commentFor(lang).replace(/[/-]/g, "\\$&")
  const token = new RegExp(
    `(${comment}.*$)|("(?:\\\\.|[^"\\\\])*"|'(?:\\\\.|[^'\\\\])*'|\`(?:\\\\.|[^\`\\\\])*\`)|(\\b\\d+(?:\\.\\d+)?\\b)|(:[a-z_][\\w?!]*|\\b[A-Za-z_][\\w?!]*\\b)`,
    "gm"
  )
  let html = ""
  let last = 0
  for (const match of code.matchAll(token)) {
    html += escape(code.slice(last, match.index))
    const [text, com, str, num, word] = match
    if (com) html += span("com", com)
    else if (str) html += span("str", str)
    else if (num) html += span("num", num)
    else if (word.startsWith(":")) html += span("atom", word)
    else if (keywords.has(word)) html += span("kw", word)
    else html += escape(word)
    last = match.index + text.length
  }
  return html + escape(code.slice(last))
}

// phx-hook="Highlight": highlights the code inside the element on mount and on
// every update, and marks it (data-highlighted) once done.
export const Highlight = {
  mounted() { this.run() },
  updated() { this.run() },
  run() {
    this.el.querySelectorAll("pre code[class*='language-']").forEach(code => {
      if (code.dataset.highlighted) return
      const lang = (code.className.match(/language-([\w+-]+)/) || [])[1] || ""
      code.innerHTML = highlight(code.textContent, lang.toLowerCase())
      code.dataset.highlighted = "true"
    })
    this.el.dataset.highlighted = "true"
  },
}
