# MVP Validation Map

## Run the end-to-end checks

From the repository root, use Python 3 and PostgreSQL 14+ server/client binaries
(`sudo apt-get install postgresql libpq-dev` on Ubuntu).

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

## Issues and Acceptance Evidence

| Issue | Implementation and evidence |
| --- | --- |
| #6 PostgreSQL interpreter | `Arm.Core` SQL plans and `DeltaCommand`; `Arm.PostgreSQL` connection/pool interpreters (originally PR #17). `test/Integration.hs` executes typed reads, both command modes, SQL parameters and pool operations against PostgreSQL; verifies query/command/constraint failures. |
| #7 schema/local DB | `compose.yaml`, `sql/001-schema.sql`, `sql/002-seed.sql`; E2E starts a real local PostgreSQL cluster and validates seeded projections. `task-sample.md` maps schema to sets/mappings/relations/constraints. |
| #8 pure task domain | `domain/Task/Domain.hs`, separate base/containers-only Cabal sublibrary. `test/Domain.hs` checks valid/invalid creation, membership, close, assign, unassign, observations, maximum titles and properties of well-formed deltas. |
| #9 zero-delta observations | Three `Observation` values in `Task.HTTP`; `taskObservations` accepts no command interpreter. E2E calls all GETs on a PostgreSQL read-only connection and verifies unchanged stored mappings, including visibility of transition results. |
| #10 transitions | Three `Transition` values in `Task.HTTP`, pure decisions in `Task.Domain`, SQL context/commands in `Task.SQL`. E2E verifies full request/SELECT/decision/INSERT-or-UPDATE/response flow, persisted mappings and structured errors with no writes on invalid decisions. |
| #11 tests/docs | All four Cabal test suites, `test/Integration.hs`, `scripts/e2e.sh`, `scripts/e2e.py`, existing build/unit CI, README and sample walkthrough. Includes Unicode, SQL-looking parameter strings, malformed inputs, empty projections, stale deltas and concurrent close regression checks. |
| #1 umbrella | All eight success criteria below plus the six child issue rows above. Review and CI should be checked before integration/issue completion. |

## `docs/mvp-scope.md` Success Criteria

1. **Core abstraction and zero delta:** existing `Transition`, `Observation`,
   `ZeroDelta`, execution helpers and core handler-flow tests.
2. **WAI/Warp:** existing named route constructors plus application codec hooks;
   adapter tests and real Warp HTTP calls.
3. **PostgreSQL `DBQuery`/`DBCommand`:** direct connection and pool integration
   checks, including returning commands, parameter types and failures.
4. **Locally runnable task API:** Compose and seed SQL; README startup commands;
   fixture startup independently exercises the same schema/server binary.
5. **Observation/transition HTTP URLs:** all three GETs and all three POSTs are
   called by the E2E script; `/tasks` is absent and incorrect methods yield 405.
6. **Real read/decision/write:** E2E creates a task from loaded membership
   context, then directly checks its persisted title/project/status/creator/
   time/assignee mappings; assigns/unassigns and closes it with subsequent GETs.
7. **Pure unit tests:** domain sublibrary has no HTTP, ARM or PostgreSQL
   dependency; 28 tests include two QuickCheck properties (100 cases each).
8. **Endpoint rationale:** [URL design](url-design.md) explains named operations
   and external inputs. The [task walkthrough](task-sample.md) traces a typed
   delta through SQL, and [MVP scope](mvp-scope.md) defines the boundaries.

## Additional Regression Evidence

The generic WAI default codec preserves UTF-8 and rejects invalid UTF-8 before
query execution. Custom codec failures likewise never execute queries. The
PostgreSQL interpreter retains cancellation/pool disposal regressions and
reports structured failures without including raw driver exceptions.

The integration runner proves a stale assignment command is rejected with 409.
The real HTTP test races two closes and verifies exactly one 200, one 409 and
one version increment. Commands guard context freshness rather than assuming
that separate pool calls share a transaction.

The local validation used GHC 9.10.3, Cabal 3.16.1.0 and PostgreSQL 14.24 on
Ubuntu 22.04 (WSL). All four unit suites and real PostgreSQL/HTTP checks passed.
Docker Compose configuration is provided; Docker was stopped in that local
environment, so Compose startup itself was not exercised there. The existing
GitHub workflow builds all packages and runs all unit tests. Real SQL/HTTP
checks are reproducible with the separate E2E script; they were run locally.
Automating E2E in the workflow is a follow-up: the current GitHub credential
cannot update workflow files, and no authorization scopes were changed.

These checks prove the defined sample operations. Authentication, production
deployment, generic transaction/idempotency semantics, migrations and a
frontend framework remain outside the MVP.
