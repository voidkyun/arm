# Library and Example Boundary

This document fixes the MVP boundary between reusable ARM library code and the
task management example.

The short rule is:

```text
Reusable endpoint algebra, adapters, and interpreters belong in the library.
Task-specific domain algebra, schema, SQL, JSON, and local setup belong in the example.
```

## Library Responsibilities

### `arm-core`

`arm-core` defines the reusable ARM model. It may contain:

- Core endpoint vocabulary such as `EndpointName`, `RawRequest`, and
  `RawResponse`.
- Structured API errors and domain error boundary types.
- `Observation` and `Transition` descriptions.
- Pure execution flow for observations and transitions.
- Database effect descriptions such as `DBQuery`, `DBCommand`, and
  `DeltaCommand`.
- Generic SQL statement, parameter, row, value, and decoding helpers.

`arm-core` must not depend on WAI, Warp, PostgreSQL, Aeson, the task domain, or
any concrete application schema.

### `arm-wai`

`arm-wai` adapts ARM endpoints to WAI. It may contain:

- Route values that bind an ARM endpoint name to an HTTP method.
- WAI `Application` assembly.
- Request body extraction into `RawRequest`.
- Conversion from `ApiError` to HTTP status responses.
- Observation and transition route constructors that expose the correct
  authority boundaries.

`arm-wai` must not know about task concepts, JSON request shapes, PostgreSQL
connections, SQL statements, or database schemas.

### `arm-postgresql`

`arm-postgresql` interprets generic ARM SQL descriptions against PostgreSQL. It
may contain:

- `DBQuery` execution against a PostgreSQL `Connection` or `Pool Connection`.
- `DBCommand` execution against a PostgreSQL `Connection` or `Pool Connection`.
- Parameter binding for `SQLParameter`.
- Conversion of PostgreSQL result rows into generic `SQLRows`.
- Structured interpreter failures surfaced as `ApiError`.

`arm-postgresql` must not contain migrations, schema introspection, task table
knowledge, task-specific row decoders, or a complete SQL query builder.

## Example Responsibilities

### Schema and Local Setup

The task example owns the concrete stored extension of its domain algebra. It
should contain:

- PostgreSQL schema for users, projects, tasks, statuses, mappings, relations,
  and constraints.
- Local development setup such as Docker Compose.
- Seed data that makes the example useful immediately.
- Schema documentation that explains rows and columns as representations of
  algebra extension data, not persisted objects.

### Domain Algebra

The task example owns all task-specific domain types and pure decisions. It
should contain:

- Task-specific input, context, delta, result, response, and error types.
- Pure observation functions.
- Pure transition delta decision functions such as `decideCreateTaskDelta`,
  `decideCloseTaskDelta`, and `decideAssignTaskDelta`.
- Unit tests for domain decisions using in-memory context values.

These functions must not run HTTP or database IO.

### Concrete SQL Queries and Commands

The task example owns the mapping from its domain algebra to concrete SQL. It
should contain:

- `DBQuery` values that load task-specific context from PostgreSQL.
- SQL row decoders from `SQLRows` to task-specific context and result types.
- `DeltaCommand` values that translate task-specific deltas into SQL commands.
- SQL statements for observations and transitions such as `openTasks`,
  `createTask`, `closeTask`, and `assignTask`.

The library provides the mechanism for `DBQuery`, `DBCommand`, and
`DeltaCommand`. The example provides the actual task SQL and task row decoding.

### HTTP Sample Application

The task example owns the runnable sample application. It should contain:

- JSON decoding and encoding for task endpoint inputs and responses.
- The list of public sample routes such as `GET /open-tasks` and
  `POST /create-task`.
- PostgreSQL connection configuration for the sample.
- Warp startup code for local development.
- End-to-end checks and README commands that prove the sample works over real
  HTTP and real PostgreSQL.

## Gray Areas

### JSON

For the MVP, task endpoint JSON shapes belong in the example. A reusable JSON
adapter can be added later only if it remains domain-independent and does not
force ARM endpoints into object serialization.

### Command Construction

`DeltaCommand` and `dbCommandFromDelta` belong in `arm-core` because they are a
generic bridge from typed deltas to command descriptions.

Concrete mappings such as `CreateTaskDelta -> INSERT INTO tasks ...` belong in
the task example.

### Row Decoding

Generic helpers such as `singleSQLRow` and `sqlColumnText` belong in
`arm-core`.

Concrete decoders such as `SQLRows -> CreateTaskContext` or
`SQLRows -> OpenTasksResponse` belong in the task example.

### Migrations

Migration tooling is outside the MVP library scope. The task example may include
plain schema setup files so the sample can run locally, but that must not become
a reusable migration framework in the MVP.

### Authorization, Time, and Identity

The MVP example may model actor identity, current time, and generated IDs as
sample infrastructure or SQL behavior. A reusable ARM capability model should be
considered only after the core observation/transition model is proven.

## Issue Mapping

After the SQL library issue, the remaining MVP issues should stay on the example
side:

- Issue #7: task sample schema, local PostgreSQL setup, and seed data.
- Issue #8: task sample domain algebra and pure delta decisions.
- Issue #9: task sample observation endpoints.
- Issue #10: task sample transition endpoints.
- Issue #11: validation, end-to-end checks, and README guidance.

These issues may use and pressure-test the library APIs, but they should not add
task-specific behavior to `arm-core`, `arm-wai`, or `arm-postgresql`.
