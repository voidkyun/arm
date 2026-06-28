# arm
Algebra Relational Mapping

ARM maps relational data to domain algebra, not rows to objects. At the core
algebraic level, every endpoint is a transition over the current domain algebra
extension. A public observation is the safe zero-delta transition, while a
public transition may produce a non-zero delta and apply it through an explicit
interpreter.

## Design Notes

- [URL Design](docs/url-design.md)
- [MVP Scope](docs/mvp-scope.md)

## Package Boundaries

ARM starts as a Cabal multi-package workspace:

- `arm-core`: reusable core library for ARM concepts. It must not depend on
  WAI, Warp, PostgreSQL, or the task example.
- `arm-wai`: HTTP adapter boundary for WAI/Warp integration.
- `arm-postgresql`: SQL interpreter boundary for PostgreSQL integration.
- `arm-example-task`: sample task management application that depends on the
  reusable ARM libraries.

The initial package split keeps the domain and endpoint core independent from
HTTP and database interpreters. Concrete endpoint types, WAI routing, and
PostgreSQL execution are added in later MVP issues.
