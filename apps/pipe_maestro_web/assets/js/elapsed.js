// phx-hook="Elapsed" on a time the notification center shows (Layouts.app):
// `data-since` is when it started (ISO 8601) and `data-format` how to say it,
// "elapsed" ("3 min 12 s", every second) or "ago" ("há 5 min", every
// minute). The server renders the first text, so the page never flickers;
// the browser only keeps it going.

const elapsed = seconds => {
  if (seconds < 60) return `${seconds} s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ${seconds % 60} s`
  return `${Math.floor(seconds / 3600)} h ${Math.floor((seconds % 3600) / 60)} min`
}

const ago = seconds => {
  if (seconds < 60) return "agora"
  if (seconds < 3600) return `há ${Math.floor(seconds / 60)} min`
  if (seconds < 86400) return `há ${Math.floor(seconds / 3600)} h`
  return `há ${Math.floor(seconds / 86400)} d`
}

export const Elapsed = {
  mounted() { this.start() },
  updated() { this.start() },
  destroyed() { clearInterval(this.timer) },

  start() {
    clearInterval(this.timer)
    const since = Date.parse(this.el.dataset.since || "")
    if (Number.isNaN(since)) return
    const format = this.el.dataset.format === "ago" ? ago : elapsed
    const tick = () => {
      const seconds = Math.max(0, Math.floor((Date.now() - since) / 1000))
      this.el.textContent = format(seconds)
    }
    tick()
    this.timer = setInterval(tick, this.el.dataset.format === "ago" ? 60000 : 1000)
  },
}
