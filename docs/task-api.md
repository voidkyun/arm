# Run the task API

Start the sample with the [quickstart](../README.md). To use an existing
PostgreSQL 14+ installation, create a fresh database and apply
[the schema](../arm-example-task/sql/001-schema.sql) followed by
[the seed data](../arm-example-task/sql/002-seed.sql). Set `ARM_DATABASE_URL`
to its connection string before starting the server.

With the quickstart defaults, the HTTP server listens on `127.0.0.1:8080` and
Compose publishes PostgreSQL on `127.0.0.1:55432`. Compose applies the schema
and seed SQL when it first creates its data volume. Stop the database with
`docker compose down`. The volume persists between runs.

## Example requests

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

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ARM_DATABASE_URL` | `host=127.0.0.1 port=55432 dbname=arm_task user=arm password=arm-local` | libpq connection string or URI |
| `ARM_PORT` | `8080` | Local HTTP port |
| `ARM_OBSERVATIONS_ONLY` | unset | Set to `1` to build only GET routes, using only a query interpreter |

`actorId` is a sample argument, not an authenticated identity. Authorization,
deployment, migration frameworks, a full SQL DSL, Servant and generic frontend
tooling are outside this MVP. The example is a runnable HTTP backend.
