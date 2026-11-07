// phx-hook="Sidebar" on the app's sidebar (Layouts.app): it opens or closes to
// a rail of icons, and the choice made with the trigger is kept in this
// browser for every page. A page that follows work in progress (a run, a task
// running, a proposal being written) asks for focus (data-focus="true"): the
// server renders it closed, and it closes when the work starts while the page
// is open. The page leaves `data-collapsed` to the browser after mount
// (JS.ignore_attributes), so a patch never undoes the person's choice.

const KEY = "pipemaestro:sidebar-collapsed"

const read = () => {
  try { return window.localStorage.getItem(KEY) } catch (_error) { return null }
}

const write = value => {
  try { window.localStorage.setItem(KEY, value) } catch (_error) { /* private window: not kept */ }
}

export const Sidebar = {
  mounted() {
    this.focus = this.el.dataset.focus === "true"
    const saved = read()
    if (!this.focus && (saved === "true" || saved === "false")) {
      this.el.setAttribute("data-collapsed", saved)
    }

    // The trigger toggles the attribute itself (Petal's JS command); the
    // choice is read once it is applied.
    this.onClick = event => {
      const trigger = event.target.closest(".pc-sidebar-trigger--collapse")
      if (trigger && trigger.getAttribute("aria-controls") === this.el.id) {
        setTimeout(() => write(this.el.getAttribute("data-collapsed")), 0)
      }
    }
    document.addEventListener("click", this.onClick)
  },

  updated() {
    const focus = this.el.dataset.focus === "true"
    if (focus && !this.focus) this.el.setAttribute("data-collapsed", "true")
    this.focus = focus
  },

  destroyed() {
    document.removeEventListener("click", this.onClick)
  },
}
