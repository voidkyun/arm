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

At the core algebraic level, every endpoint is a transition over the current
domain algebra extension. A public observation is the safe special case whose
delta is zero.

The framework should separate:

1. HTTP decoding and encoding.
2. SQL-backed context loading.
3. Pure domain delta decisions.
4. SQL command construction and execution.
5. Response construction.

The important external proof is that a sample API can be called over HTTP and
can read and write a real PostgreSQL database.

## Core Abstractions

The MVP should center on one core algebraic endpoint abstraction:

```haskell
data Transition input context domainError delta result output
```

A transition represents:

```text
input -> SQL query -> context -> pure delta decision -> SQL command -> result -> output
```

The `delta` is a typed description of the intended change to the domain algebra
extension. For example, a task creation transition does not merely construct a
`Task` object. It decides a well-formed algebra delta such as:

```text
+ Task(t)
+ title(t)     = input.title
+ project(t)   = input.project
+ status(t)    = Open
+ createdBy(t) = actor
+ createdAt(t) = now
+ assignee(t)  = input.assignee, when present
```

SQL execution is an interpreter for that delta. The relational schema stores the
extension of the algebra; it is not treated as object persistence.

Public ARM APIs still expose two semantic endpoint kinds:

```haskell
data Observation input context domainError output
data Transition input context domainError delta result output
```

An observation represents:

```text
input -> SQL query -> context -> zero-delta observation -> output
```

An observation is a transition whose delta is zero. The observation API is
separate because it must not expose write authority or require a command
interpreter.

The MVP shape is:

```haskell
data Observation input context domainError output = Observation
  { name       :: EndpointName
  , decode     :: RawRequest -> Either ApiError input
  , buildQuery :: input -> DBQuery context
  , observe    :: context -> input -> Either domainError output
  , encode     :: output -> Either ApiError RawResponse
  }

data Transition input context domainError delta result output = Transition
  { name         :: EndpointName
  , decode       :: RawRequest -> Either ApiError input
  , buildQuery   :: input -> DBQuery context
  , decide       :: context -> input -> Either domainError delta
  , buildCommand :: delta -> DBCommand result
  , respond      :: context -> result -> Either ApiError output
  , encode       :: output -> Either ApiError RawResponse
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

Domain delta decision functions must not run SQL directly.

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
5. Pure domain delta decisions.
6. SQL-backed application of well-formed algebra deltas.

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

1. A Haskell library exposes the core ARM transition abstraction and the
   zero-delta observation wrapper.
2. A WAI/Warp adapter can serve ARM endpoints over HTTP.
3. A PostgreSQL interpreter can execute `DBQuery` and `DBCommand`.
4. The sample task API can be run locally.
5. HTTP clients can call observation and transition URLs.
6. At least one transition performs a real SQL read, pure delta decision, and
   real SQL write.
7. Domain delta decision functions can be unit-tested without HTTP or database
   IO.
8. The README explains why ARM endpoints are named observations and transitions,
   not object resources.

## MVP Statement

ARM MVP is a Haskell library for defining Web API endpoints as typed algebraic
pipelines, where every endpoint is modeled as a transition over a domain algebra
extension, public URLs name observations and transitions, WAI/Warp provides real
HTTP execution, PostgreSQL provides real SQL execution, and pure delta decisions
remain separated from effectful interpreters.
