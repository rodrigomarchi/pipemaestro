---
paths:
  - "apps/claude_control_plane_web/lib/**"
  - "apps/claude_control_plane_web/assets/**"
---

# UI

Screens are built with petal_components. Before writing any HEEx, read
[`docs/guias/ui-petal.md`](../../docs/guias/ui-petal.md).

- Use a Petal component before raw Tailwind markup for any UI primitive.
- Check a component's real `attr`/`slot` declarations before using it; never guess.
- Verify a screen visually (light and dark) before calling it done: a green test
  suite does not show a collapsed input or an overflowing column.
