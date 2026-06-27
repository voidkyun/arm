# MVP Scope

ARM MVP is a Haskell library for defining Web API endpoints as typed algebraic
pipelines, executed over real HTTP via WAI/Warp and real SQL via PostgreSQL.

The MVP must demonstrate the core claim of ARM:

```text
Map relational data to domain algebra, not rows to objects.
```

## Primary Goal

The first usable version of ARM should make it possible to define backend API
endpoints as named observations and transitions over a domain algebra.

The framework should separate:

1. HTTP decoding and encoding.
2. SQL-backed context loading.
3. Pure domain decisions.
4. SQL command construction and execution.
5. Response construction.

The important external proof is that a sample API can be called over HTTP and
can read and write a real PostgreSQL database.

## Core Abstractions

The MVP should center on two endpoint kinds:

```haskell
data Observation input context domainError output
data Transition input context domainError decision result output
```

An observation represents:

```text
input -> SQL query -> context -> pure observation -> output
```

A transition represents:

```text
input -> SQL query -> context -> pure decision -> SQL command -> result -> output
```

The earlier generic endpoint shape remains useful, but in the MVP it should be
split semantically:

```haskell
data Observation input context domainError output = Observation
  { name       :: EndpointName
  , decode     :: RawRequest -> Either ApiError input
  , buildQuery :: input -> DBQuery context
  , observe    :: context -> input -> Either domainError output
  , encode     :: output -> RawResponse
  }

data Transition input context domainError decision result output = Transition
  { name         :: EndpointName
  , decode       :: RawRequest -> Either ApiError input
  , buildQuery   :: input -> DBQuery context
  , decide       :: context -> input -> Either domainError decision
  , buildCommand :: decision -> DBCommand result
  , respond      :: context -> result -> Either ApiError output
  , encode       :: output -> RawResponse
  }
```

The concrete domain error type is supplied by the application and translated to
`ApiError` only at the execution boundary. The exact Haskell API can evolve, but
the MVP should preserve this separation.

## HTTP Target

The MVP should target:

```text
WAI adapter
Warp example server
```

ARM should not implement HTTP from scratch.

WAI gives ARM a stable boundary:

```haskell
Request -> IO Response
```

Warp can run the sample application.

Servant integration is out of scope for the MVP because Servant already imposes
its own type-level API model. ARM should first demonstrate its own endpoint
model clearly.

## SQL Target

The MVP should target PostgreSQL first.

The SQL layer should be real enough to support a working application, but it
should not attempt to become a full ORM or a complete SQL DSL in the first
version.

The initial SQL design should provide:

1. `DBQuery a` for SQL-backed reads.
2. `DBCommand a` for SQL-backed writes.
3. PostgreSQL interpreters for executing queries and commands.
4. Parameterized SQL usage.
5. Structured error handling at the API boundary.

Domain decision functions must not run SQL directly.

## Sample Application

The MVP should include a task management sample application.

The sample should use ARM-style operation URLs rather than REST-style object
URLs.

Initial observation endpoints:

```text
GET /open-tasks
GET /project-task-state
GET /assignee-inbox
```

Initial transition endpoints:

```text
POST /create-task
POST /close-task
POST /assign-task
```

The sample should be complex enough to demonstrate:

1. Multiple entity sets, such as users, projects, tasks, and statuses.
2. Mappings, such as task owner, assignee, project, and status.
3. Constraints, such as valid status transitions.
4. SQL-backed context loading.
5. Pure domain decisions.
6. SQL-backed state changes.

## Out Of Scope

The MVP should not include:

1. Object-relational mapping.
2. Active record APIs.
3. Lazy-loaded associations.
4. Migration tooling.
5. Schema introspection.
6. A complete SQL query builder.
7. A complete authorization framework.
8. Servant integration.
9. Generic frontend tooling.

These can be revisited after the core ARM model is working.

## Success Criteria

The MVP is successful when:

1. A Haskell library exposes the core ARM endpoint abstractions.
2. A WAI/Warp adapter can serve ARM endpoints over HTTP.
3. A PostgreSQL interpreter can execute `DBQuery` and `DBCommand`.
4. The sample task API can be run locally.
5. HTTP clients can call observation and transition URLs.
6. At least one transition performs a real SQL read, pure domain decision, and
   real SQL write.
7. Domain decision functions can be unit-tested without HTTP or database IO.
8. The README explains why ARM endpoints are named observations and transitions,
   not object resources.

## MVP Statement

ARM MVP is a Haskell library for defining Web API endpoints as typed algebraic
pipelines, where public URLs name domain observations and transitions, WAI/Warp
provides real HTTP execution, PostgreSQL provides real SQL execution, and pure
domain decisions remain separated from effectful interpreters.
