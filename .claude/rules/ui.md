---
paths:
  - "apps/pipe_maestro_web/lib/**"
  - "apps/pipe_maestro_web/assets/**"
---

# UI

Screens are built with petal_components. Before writing any HEEx, read
[`docs/guias/ui-petal.md`](../../docs/guias/ui-petal.md).

- Use a Petal component before raw Tailwind markup for any UI primitive.
- Check a component's real `attr`/`slot` declarations before using it; never guess.
- Give every element a test touches a `data-testid` (conventions in
  [`e2e/README.md`](../../e2e/README.md)).
- Verify a screen with `make e2e.shots` and read the screenshots (light and dark)
  before calling it done: a green suite does not show a collapsed input or an
  overflowing column. Never drive a browser by hand to check a screen.
