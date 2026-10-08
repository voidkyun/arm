# Task Sample: Relational Data to Domain Algebra

This is an executable guide to the six operations in `Task.HTTP`.

## Stored Extension

`arm-example-task/sql/001-schema.sql` represents:

| Algebra concept | PostgreSQL representation |
| --- | --- |
| Entity sets User, Project, Task | Keys in `users`, `projects`, `tasks` |
| Finite Status set | `statuses` containing `open` and `closed` |
| title, project, status, createdBy, createdAt | Required mappings in `tasks` |
| assignee, closedAt | Optional mappings in `tasks` |
| Member(Project, User) | Composite key in `project_members` |
| Creator/assignee membership | Composite foreign keys |
| Open/Closed time consistency | Check constraint on status and closedAt |
| Context freshness | Version checked by command predicates |

A `TaskFact` is loaded context describing the mappings needed by an operation,
not an active record. It has no save method or lazy associations. The schema
is plain setup SQL, not a migration framework. Seed SQL supplies two projects,
three users, two open tasks and one closed task.

## Operation Contracts

| Method and URL | External arguments | Pure result / delta |
| --- | --- | --- |
| GET `/open-tasks` | Optional query `projectId` | Open task projection: taskId, title, projectId, assigneeId |
| GET `/project-task-state` | Required query `projectId` | Counts by Open/Closed status |
| GET `/assignee-inbox` | Required query `assigneeId` | Open assignments: taskId, title, projectId |
| POST `/create-task` | JSON title, projectId, actorId, optional assigneeId | Add fresh Task and title/project/Open/creator/time/optional assignee mappings |
| POST `/close-task` | JSON taskId | Replace Open with Closed; add closedAt |
| POST `/assign-task` | JSON taskId, required assigneeId (ID or null) | Replace/remove assignee mapping on an open task |

Unknown POST fields are rejected. Assigning the current assignee is a conflict;
explicit null unassigns. Creation trims outer whitespace and accepts titles of
1–200 characters, excluding NUL (which PostgreSQL text cannot represent).
A missing project/user/task yields 404, invalid input or
membership yields 400, and closed tasks or stale context yield 409. Existing
empty projects/users produce empty projections, not missing-entity errors.

## Follow a Real Creation

1. `Task.HTTP.createTask` is a `Transition CreateTaskInput CreateTaskContext
   DomainError CreateTaskDelta CreateTaskResult CreateTaskResult`.
2. Its decoder accepts external arguments only. Caller-supplied status, id,
   time and version are rejected.
3. `Task.SQL.createTaskQuery` builds a parameterized `DBQuery` describing
   project existence, actor existence, the membership relation and server time.
4. `runPostgreSQLQueryWithPool` executes SELECT and decodes the typed context.
5. `Task.Domain.decideCreateTaskDelta` checks title and membership without IO.
   Its delta adds every required mapping together, with Open as the status.
6. `dbCommandFromDelta createTaskCommand` interprets the delta as one INSERT.
   PostgreSQL supplies the fresh task ID. The command rechecks membership, and
   foreign keys constrain the stored extension.
7. The returning row becomes `CreateTaskResult`; `respond` and `encode` produce
   `{"createdTaskId":4}` on a fresh seeded database.

The fresh task in the creation delta is a bound variable: its concrete identity
is assigned when PostgreSQL interprets the delta. The typed delta is not a
complete persisted task row.

## Observe Without Command Authority

`Task.HTTP.taskObservations` accepts only a polymorphic `DBQuery` interpreter.
It cannot execute a `DBCommand`. Each `Observation` loads context and calls a
pure observation function; its implicit algebra delta is `ZeroDelta`.

`ARM_OBSERVATIONS_ONLY=1` assembles just these routes. The E2E fixture runs this
app with `default_transaction_read_only=on` and compares the database before
and after all three GETs. It can read changes made by the transition app.
The PostgreSQL setting is a validation mechanism, not an ARM authorization
framework or a claim that arbitrary application-provided SQL is read-only.

## Concurrency and Failure Boundaries

The pool may use different connections for a context read and command. No
transaction wraps the whole pipeline. Close and assign therefore check the
context version and Open status in the UPDATE predicate. A concurrent winner
increments the version; the stale command returns no rows and maps to 409.
Create rechecks membership and inserts all mappings atomically. PostgreSQL
foreign keys guard membership if it changes during execution.

This example models no other domain transitions, and does not claim general
serializable pipelines. A future domain needing multiple dependent commands
would need an explicit transaction design. Commands may commit before result
encoding fails; this MVP has no exactly-once retries or idempotency keys.

PostgreSQL execution errors are structured `ApiError` values: constraint and
transaction conflicts are 409; other interpreter failures are 500. Raw SQL
exception details are not returned to HTTP clients. Cancellation propagates
and failed pool resources are discarded by existing interpreter tests.

## Review Order

Read the domain types and decisions first, then the six endpoint descriptions,
then the concrete SQL mappings and finally the thin server. Run the commands
in the README and inspect `scripts/e2e.py` for externally observable behavior.
`test/Domain.hs` uses only in-memory context and the pure domain sublibrary;
`test/Integration.hs` verifies real PostgreSQL execution and stale commands.
