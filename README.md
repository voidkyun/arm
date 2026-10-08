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
- [Library and Example Boundary](docs/library-example-boundary.md)

## Package Boundaries

ARM starts as a Cabal multi-package workspace:

- `arm-core`: reusable core library for ARM concepts. It must not depend on
  WAI, Warp, PostgreSQL, or the task example.
- `arm-wai`: HTTP adapter boundary for WAI/Warp integration.
- `arm-postgresql`: SQL interpreter boundary for PostgreSQL integration.
- `arm-example-task`: sample task management application that depends on the
  reusable ARM libraries.

The core stays independent of HTTP and database dependencies. The example's
`domain` sublibrary depends only on `base` and `containers`: domain decisions
cannot import the HTTP or PostgreSQL packages.

## Run the Task API

Requirements: GHC 9.10.3, Cabal, Docker Compose for the database, and `libpq`
development headers (`sudo apt-get install libpq-dev` on Ubuntu). On Windows,
run the Haskell commands in WSL. PostgreSQL 14 or later also works directly.

```sh
docker compose up -d --wait
cabal build all -j2
cabal test all -j2
cabal run arm-example-task:exe:arm-example-task
```

The server listens on `127.0.0.1:8080`; PostgreSQL is on `127.0.0.1:55432`.
Schema and seed SQL run once when Compose creates its data volume. Stop the
database with `docker compose down`; the data volume persists. Use a fresh
database when applying the example schema manually.

```sh
curl -s 'http://127.0.0.1:8080/open-tasks?projectId=1'
curl -s 'http://127.0.0.1:8080/project-task-state?projectId=1'
curl -s 'http://127.0.0.1:8080/assignee-inbox?assigneeId=2'
curl -s -H 'Content-Type: application/json' \
  -d '{"title":"Review ARM","projectId":1,"actorId":1,"assigneeId":2}' \
  http://127.0.0.1:8080/create-task
```

Use the returned `createdTaskId` in the next calls (for a fresh database it is 4):

```sh
curl -s -H 'Content-Type: application/json' -d '{"taskId":4,"assigneeId":1}' http://127.0.0.1:8080/assign-task
curl -s -H 'Content-Type: application/json' -d '{"taskId":4,"assigneeId":null}' http://127.0.0.1:8080/assign-task
curl -s -H 'Content-Type: application/json' -d '{"taskId":4}' http://127.0.0.1:8080/close-task
curl -s 'http://127.0.0.1:8080/project-task-state?projectId=1'
```

Alice (1) and Bob (2) belong to project 1; Alice (1) and Carol (3) belong to
project 2. Creating with a non-member creator or assignee fails. Closing an
already closed task fails with HTTP 409. Domain and decode errors are JSON:
`{"error":{"kind":"ApiConflictError","message":"task is already closed"}}`.
Adapter routing errors (unknown operation or wrong method) are plain text
404/405. IDs must fit a positive PostgreSQL `bigint`.

Configuration:

| Variable | Default | Meaning |
| --- | --- | --- |
| `ARM_DATABASE_URL` | `host=127.0.0.1 port=55432 dbname=arm_task user=arm password=arm-local` | libpq connection string or URI |
| `ARM_PORT` | `8080` | Local HTTP port |
| `ARM_OBSERVATIONS_ONLY` | unset | Set to `1` to build only GET routes, using only a query interpreter |

`actorId` is a sample argument, not an authenticated identity. Authorization,
deployment, migration frameworks, a full SQL DSL, Servant and generic frontend
tooling are outside this MVP. The example is a runnable HTTP backend.

## Why These URLs and Inputs?

`/open-tasks`, `/project-task-state`, and `/assignee-inbox` name observations,
not object collections. Public observations are zero-delta transitions: they
load context, compute a pure projection, and need no command interpreter.

`/create-task`, `/close-task`, and `/assign-task` name transitions. Their inputs
are external arguments for deciding typed algebra deltas, not serialized rows
or objects for persistence. `CreateTaskInput` omits identity, status, timestamps
and version. The pure decision adds a fresh Task with required mappings; the
SQL command binds its identity and applies those mappings atomically.

```text
HTTP JSON -> input -> DBQuery -> PostgreSQL SELECT -> typed Context
          -> pure delta decision -> DeltaCommand -> DBCommand
          -> PostgreSQL INSERT/UPDATE -> Result -> JSON -> HTTP
```

The schema represents entity sets, mappings, the membership relation and
constraints. SQL lives in the example's interpreter mapping, outside the pure
decision functions. Conditional commands detect stale context with version
checks; callers receive 409 and can reload before retrying.

## Read and Verify the Implementation

- [Sample walkthrough](docs/task-sample.md): schema, endpoint contracts and
  the concrete ARM calls to review.
- [MVP evidence](docs/mvp-validation.md): issue and success criterion mapping.
- [Pure task domain](arm-example-task/domain/Task/Domain.hs): input/context/delta
  types, constraints and pure decisions.
- [Endpoint pipelines](arm-example-task/src/Task/HTTP.hs): all six typed ARM
  endpoint values and JSON/query codecs.
- [SQL mapping](arm-example-task/src/Task/SQL.hs): typed context queries and
  delta-to-command construction.
- [Server](arm-example-task/app/Main.hs): PostgreSQL pool and Warp assembly.

For reproducible real SQL/HTTP validation, install PostgreSQL server/client
binaries (`sudo apt-get install postgresql libpq-dev` on Ubuntu), then run:

```sh
cabal build all -j2
cabal test all -j2
ARM_E2E_LOG_DIR=/tmp/arm-e2e-logs bash scripts/e2e.sh
```

The script creates and stops its own temporary PostgreSQL cluster and two Warp
processes. It verifies all endpoints, actual persisted changes, query-only
observations on a database read-only connection, structured failures, Unicode,
parameter binding, stale deltas and concurrent closes. It leaves its fixture
and logs for inspection. Override `PG_BIN` if server binaries are outside
`pg_config --bindir`; `PG_SHARE` is available for an unpacked distribution.
Ports default to 55439 (DB), 18089 (HTTP) and 18090 (read-only HTTP); override
`ARM_TEST_PG_PORT`, `ARM_TEST_HTTP_PORT`, `ARM_TEST_READONLY_PORT` if occupied.
