# URL Design

ARM treats HTTP URLs as names for domain algebra operations, not as object
locations.

Traditional REST-style APIs often organize URLs around mutable objects and CRUD
operations:

```text
GET    /tasks
POST   /tasks
PUT    /tasks/:id
DELETE /tasks/:id
```

This shape is useful, but it usually reflects an object-oriented interpretation
of the domain:

```text
object + CRUD verb
```

ARM uses a different interpretation.

The domain is modeled as algebra over sets, mappings, relations, constraints,
and transitions. A public HTTP endpoint should therefore name an operation over
that algebra.

## Endpoint Semantics

At the core algebraic level, every ARM endpoint is a transition over the current
domain algebra extension:

```text
input x extension -> delta x output
```

An observation is the special case whose delta is zero. It is a transition from
the current extension back to the same extension.

Public HTTP APIs still expose two semantic endpoint kinds:

```text
Observation
Transition
```

An observation evaluates a named expression over the current algebra extension.
It has no authority to change the extension.

A transition proposes or applies a named state change to the current algebra
extension.

## GET As Observation

In ARM, `GET` means:

```text
evaluate a named expression over the current domain algebra extension
```

The URL names the observation, not a table or object collection.

Examples:

```text
GET /open-tasks
GET /project-task-state
GET /assignee-inbox
GET /project-workload
```

These endpoints are not primarily asking for `Task` objects. They ask the
current domain algebra to evaluate an expression such as:

```text
openTasks(project)
projectTaskState(project)
assigneeInbox(user)
projectWorkload(project)
```

The underlying SQL may read from many tables, joins, mappings, and constraints,
but the public URL names the domain observation. Algebraically, this is a
zero-delta transition.

## POST As Transition

In ARM, `POST` means:

```text
apply a named transition to the current domain algebra extension
```

The URL names the transition, not a mutable object collection.

Examples:

```text
POST /create-task
POST /close-task
POST /assign-task
POST /move-task-to-project
POST /rename-project
```

These endpoints are not primarily CRUD operations on rows. They are named domain
transitions such as:

```text
createTask(input)
closeTask(input)
assignTask(input)
moveTaskToProject(input)
renameProject(input)
```

Each transition may require a SQL-backed context, a pure domain delta decision,
and one or more SQL commands.

A transition input is not a serialized object to persist. It is the set of
external arguments required to decide a well-formed delta. For example,
`createTask(input)` may add one task to the `Task` set and define the related
`title`, `project`, `status`, `createdBy`, `createdAt`, and `assignee` mappings
at the same time.

## Public URLs

Although ARM has one core algebraic transition model, public URLs should
normally expose named operations directly:

```text
GET  /open-tasks
POST /create-task
```

The following shape is conceptually valid but not the default public style for
the MVP:

```text
GET  /observe?name=open-tasks
POST /transition
```

ARM keeps `Observation` and `Transition` as public semantic categories while the
core model treats both as transitions over a domain algebra extension. This lets
public HTTP APIs remain readable, loggable, documentable, and easy to monitor.

## Design Rules

ARM URL design starts from these rules:

1. URLs name domain algebra operations.
2. Every endpoint is an algebraic transition over the current extension.
3. `GET` URLs name zero-delta observations.
4. `POST` URLs name transitions that may produce non-zero deltas.
5. URLs should not be derived mechanically from table names.
6. URLs should not be derived mechanically from object names plus CRUD verbs.
7. SQL remains real and explicit, but SQL structure does not dictate public URL
   structure.

In short:

```text
ARM endpoints are named observations and transitions over a domain algebra.
They are not object locations.
```
