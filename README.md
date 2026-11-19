# ARM

Algebra Relational Mapping (ARM) is a Haskell library for defining HTTP APIs as
observations and transitions over data stored in PostgreSQL.

## Run the task API

From the repository root, use GHC 9.10.3, Cabal, Docker Compose and the libpq
development headers (`libpq-dev` on Ubuntu). On Windows, use WSL.

```sh
docker compose up -d --wait
cabal update
cabal build all -j2
cabal test all -j2
cabal run arm-example-task:exe:arm-example-task
```

In another terminal, query the seeded project:

```sh
curl -fsS 'http://127.0.0.1:8080/open-tasks?projectId=1'
```

See the [development docs](docs/README.md) for API examples, configuration, design and validation.
