# ARM: Algebra Relational Mapping

> ARM is not about mapping rows to objects.
> It maps relational data to domain algebra.

## Overview

ARM stands for **Algebra Relational Mapping**.

It is a design approach for building web applications and APIs where relational data is not primarily viewed as objects, models, or mutable records, but as a structure of **sets, mappings, relations, constraints, and operations**.

Traditional ORMs map relational tables to objects.

ARM maps relational data to **domain algebra**.

In ARM, a database schema is interpreted as an algebraic structure:

* entity sets
* finite sets
* mappings between sets
* relations
* constraints
* queries
* commands
* domain delta decisions
* transition deltas
* responses

The goal is not to hide the database behind objects, but to make the relationship between relational data and domain logic explicit, typed, and composable.

## Motivation

Most web APIs appear to have the shape:

```haskell
Request -> Response
```

But real APIs rarely have this shape.

A realistic endpoint usually needs to:

* parse an incoming request
* validate it
* query the database
* construct a domain state or context
* decide a domain algebra delta
* generate database commands
* execute those commands
* build a response
* serialize the response

So the real shape is closer to:

```haskell
RawRequest -> Program RawResponse
```

where `Program` represents effects such as database access, logging, time, authorization, external API calls, or other IO.

The central problem is that domain logic and database effects are often mixed together inside request handlers.

ARM separates them.

## Core Idea

ARM distinguishes between two layers:

1. **Domain algebra**
2. **Effect interpreters**

The domain algebra is pure.

It describes:

* what kind of request was received
* what data is required
* what delta should be decided
* what command should be executed
* what response should be returned

The effect interpreters are impure.

They execute:

* database queries
* database commands
* IO operations
* logging
* external calls

The core pipeline looks like this:

```haskell
RawRequest
  -> Either ApiError Request

Request
  -> DBQuery Context

Context
  -> Request
  -> Either domainError Delta

Delta
  -> DBCommand Result

Context
  -> Result
  -> Either ApiError Response

Response
  -> RawResponse
```

The full handler has an effectful boundary:

```haskell
RawRequest -> IO RawResponse
```

But most of the application-specific logic remains pure.

## Why Not ORM?

ORM stands for **Object Relational Mapping**.

It usually treats database tables as classes and rows as objects:

```text
table  <-> class
row    <-> object
column <-> field
```

This is useful, but it imposes an object-oriented interpretation on relational data.

ARM takes a different view.

A relational schema can be understood more directly as a collection of sets and mappings:

```text
User      : Set
Task      : Set
Project   : Set
Status    : Finite Set

owner     : Task -> User
project   : Task -> Project
status    : Task -> Status
createdAt : Task -> Time
```

From this perspective, the database is not an object graph.

It is a relational representation of domain algebra.

## Domain Algebra

In ARM, a domain algebra consists of:

* domain types
* entity sets
* mappings
* relations
* constraints
* queries
* commands
* delta decisions
* deltas
* results
* events
* response transformations

For example:

```haskell
data CreateTaskRequest
data CreateTaskContext
data CreateTaskError
data CreateTaskDelta
data CreateTaskResult
data CreateTaskResponse
```

A pure domain delta decision may have a shape like:

```haskell
decideCreateTask
  :: CreateTaskContext
  -> CreateTaskRequest
  -> Either CreateTaskError CreateTaskDelta
```

This function does not access the database.

It only decides what delta should be applied, given the current context and the
request.

Database access is handled separately.

## Deltas, Not Objects

A transition does not construct an object for persistence.

A transition constructs a well-formed delta to the current domain algebra
extension.

For example, creating a task is not just adding one value to the `Task` set. It
also defines the mappings that have `Task` as their domain:

```text
+ Task(t)
+ title(t)     = input.title
+ project(t)   = input.project
+ status(t)    = Open
+ createdBy(t) = actor
+ createdAt(t) = now
+ assignee(t)  = input.assignee, when present
```

The request body may be shaped like JSON object syntax, but its meaning is not a
serialized `Task` object. It is the set of external arguments required by the
`createTask` transition. Values such as `status`, `createdBy`, `createdAt`, and
the generated task identity may come from rules, context, interpreters, or the
database.

This is the main difference from serializer-driven object persistence:

```text
serializer:
  request body -> object or row

ARM:
  request body -> transition input
  context + input -> algebra delta
  algebra delta -> interpreted SQL command
```

## Queries and Commands as Data

In ARM, database queries and commands should be represented as data, not hidden inside arbitrary IO code.

Instead of writing:

```haskell
Request -> IO Context
```

ARM prefers:

```haskell
Request -> DBQuery Context
```

Then an interpreter executes the query:

```haskell
runQuery :: DBQuery a -> IO a
```

Likewise, instead of directly mutating the database inside domain logic:

```haskell
Delta -> IO Result
```

ARM prefers:

```haskell
Delta -> DBCommand Result
```

Then an interpreter executes the command:

```haskell
runCommand :: DBCommand a -> IO a
```

This keeps the domain layer pure and testable.

## Endpoint Shape

An endpoint can be described as a typed algebraic transition pipeline.

One possible representation is:

```haskell
data Transition req ctx domainError delta result res = Transition
  { decode       :: RawRequest -> Either ApiError req
  , buildQuery   :: req -> DBQuery ctx
  , decide       :: ctx -> req -> Either domainError delta
  , buildCommand :: delta -> DBCommand result
  , respond      :: ctx -> result -> Either ApiError res
  , encode       :: res -> RawResponse
  }
```

Then a generic interpreter can execute any endpoint:

```haskell
handle
  :: (domainError -> ApiError)
  -> Transition req ctx domainError delta result res
  -> RawRequest
  -> IO RawResponse
handle mapDomainError endpoint raw = do
  req      <- liftEither $ decode endpoint raw
  ctx      <- runQuery   $ buildQuery endpoint req
  delta    <-
    liftEither $
      case decide endpoint ctx req of
        Left domainError -> Left (mapDomainError domainError)
        Right delta       -> Right delta
  result   <- runCommand $ buildCommand endpoint delta
  res      <- liftEither $ respond endpoint ctx result
  pure        $ encode endpoint res
```

The endpoint-specific parts are pure descriptions.

The interpreter is responsible for effects.

## Observation As Zero-Delta Transition

At the core algebraic level, every ARM endpoint is a transition:

```text
input x extension -> delta x output
```

An observation is the safe special case where `delta` is zero. It evaluates the
current extension and returns an output without authority to change the
extension.

The public API still distinguishes:

```text
Observation
Transition
```

This distinction is for safety and HTTP semantics. `GET`-like observations do
not receive a command interpreter. `POST`-like transitions may produce
non-zero deltas and therefore need an interpreter that can apply commands.

## Request, Context, Delta, Result, Response

ARM does not assume that every endpoint shares the same request, state, or response type.

Each endpoint may define its own types:

```haskell
CreateTaskRequest
CreateTaskContext
CreateTaskDelta
CreateTaskResult
CreateTaskResponse
```

Another endpoint may define:

```haskell
CloseTaskRequest
CloseTaskContext
CloseTaskDelta
CloseTaskResult
CloseTaskResponse
```

This allows each endpoint to expose only the domain information it actually needs.

The shared abstraction is not a universal object model.

The shared abstraction is the pipeline:

```text
Request -> Query -> Context -> Delta -> Command -> Result -> Response
```

## Context Instead of Global State

ARM prefers the term `Context` when describing the subset of database state required by an endpoint.

A database may contain a large global state, but an endpoint usually needs only a small projection of it.

For example:

```haskell
buildQuery :: CreateTaskRequest -> DBQuery CreateTaskContext
```

The context may include:

* the current user
* the target project
* existing task names
* permission information
* plan limits
* relevant constraints

The domain delta decision receives this context as ordinary data.

```haskell
decide
  :: CreateTaskContext
  -> CreateTaskRequest
  -> Either CreateTaskError CreateTaskDelta
```

This makes the domain logic independent from the database.

## Errors

ARM should not use `Maybe` for API-level failure unless the absence of a value is the only meaningful information.

Most API failures need structured error information.

Therefore ARM prefers:

```haskell
Either ApiError a
Either domainError a
```

over:

```haskell
Maybe a
```

`ApiError` is the framework-owned boundary error. `domainError` is supplied by
the application, because the concrete failure algebra belongs to the domain.

At the API boundary, the application provides a translation:

```haskell
domainError -> ApiError
```

This allows the boundary to distinguish between:

* parse errors
* validation errors
* authorization errors
* not found errors
* conflict errors
* invariant violations
* unexpected interpreter failures

## Relationship to Haskell

ARM is strongly influenced by typed functional programming.

The handler boundary is effectful:

```haskell
RawRequest -> IO RawResponse
```

But the domain core is pure:

```haskell
Context -> Request -> Either domainError Delta
```

The IO layer sequences effects.

The domain layer describes algebra.

This matches the functional design principle often called:

```text
functional core, imperative shell
```

In ARM terms:

```text
algebraic core, effectful interpreter
```

## Relationship to Monad

ARM does not require application developers to think about monads directly, but the structure is naturally monadic.

The full API handler composes effectful computations:

```haskell
IO a -> (a -> IO b) -> IO b
```

Database queries, database commands, parsing failures, and domain errors all introduce computational context.

ARM keeps those contexts explicit instead of hiding them inside mutable object methods.

The key distinction is:

* pure functions describe domain transformations
* effectful interpreters execute database and IO operations
* the handler composes these steps into a complete program

## What ARM Is Not

ARM is not an ORM with a different name.

ARM is not primarily about active records, lazy-loaded associations, or object persistence.

ARM is not about pretending that database access is pure.

ARM is not about removing SQL or relational databases.

ARM is not about hiding effects.

Instead, ARM is about making the algebraic structure of the application explicit and mapping it to relational storage in a disciplined way.

## What ARM Is

ARM is a way to model a web application as:

```text
Relational Data
  <-> Domain Algebra
  -> Typed Deltas
  -> Interpreted Effects
```

It treats database schemas as relational representations of algebraic domain structures.

It treats API endpoints as typed transition pipelines from raw input to
interpreted commands and serialized output.

It separates:

* parsing from delta decision-making
* querying from domain logic
* commands from command execution
* response construction from response serialization
* pure algebra from effectful interpretation

## Guiding Principle

The core principle of ARM is:

> Keep the domain algebra pure.
> Keep the interpreters explicit.
> Map relational data to algebra, not rows to objects.

## Slogan

> ARM is not about mapping rows to objects.
> It maps relational data to domain algebra.
