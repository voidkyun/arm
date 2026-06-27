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
* domain decisions
* state transitions
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
* make a domain decision
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
* what decision should be made
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
  -> Either DomainError Decision

Decision
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
* decisions
* results
* events
* response transformations

For example:

```haskell
data CreateTaskRequest
data CreateTaskContext
data CreateTaskDecision
data CreateTaskResult
data CreateTaskResponse
```

A pure domain decision may have a shape like:

```haskell
decideCreateTask
  :: CreateTaskContext
  -> CreateTaskRequest
  -> Either DomainError CreateTaskDecision
```

This function does not access the database.

It only decides what should happen, given the current context and the request.

Database access is handled separately.

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
Decision -> IO Result
```

ARM prefers:

```haskell
Decision -> DBCommand Result
```

Then an interpreter executes the command:

```haskell
runCommand :: DBCommand a -> IO a
```

This keeps the domain layer pure and testable.

## Endpoint Shape

An endpoint can be described as a typed algebraic pipeline.

One possible representation is:

```haskell
data Endpoint req ctx decision result res = Endpoint
  { decode       :: RawRequest -> Either ApiError req
  , buildQuery   :: req -> DBQuery ctx
  , decide       :: ctx -> req -> Either DomainError decision
  , buildCommand :: decision -> DBCommand result
  , respond      :: ctx -> result -> Either ApiError res
  , encode       :: res -> RawResponse
  }
```

Then a generic interpreter can execute any endpoint:

```haskell
handle
  :: Endpoint req ctx decision result res
  -> RawRequest
  -> IO RawResponse
handle endpoint raw = do
  req      <- liftEither $ decode endpoint raw
  ctx      <- runQuery   $ buildQuery endpoint req
  decision <- liftEither $ decide endpoint ctx req
  result   <- runCommand $ buildCommand endpoint decision
  res      <- liftEither $ respond endpoint ctx result
  pure        $ encode endpoint res
```

The endpoint-specific parts are pure descriptions.

The interpreter is responsible for effects.

## Request, Context, Decision, Result, Response

ARM does not assume that every endpoint shares the same request, state, or response type.

Each endpoint may define its own types:

```haskell
CreateTaskRequest
CreateTaskContext
CreateTaskDecision
CreateTaskResult
CreateTaskResponse
```

Another endpoint may define:

```haskell
CloseTaskRequest
CloseTaskContext
CloseTaskDecision
CloseTaskResult
CloseTaskResponse
```

This allows each endpoint to expose only the domain information it actually needs.

The shared abstraction is not a universal object model.

The shared abstraction is the pipeline:

```text
Request -> Query -> Context -> Decision -> Command -> Result -> Response
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

The domain decision receives this context as ordinary data.

```haskell
decide
  :: CreateTaskContext
  -> CreateTaskRequest
  -> Either DomainError CreateTaskDecision
```

This makes the domain logic independent from the database.

## Errors

ARM should not use `Maybe` for API-level failure unless the absence of a value is the only meaningful information.

Most API failures need structured error information.

Therefore ARM prefers:

```haskell
Either ApiError a
Either DomainError a
```

over:

```haskell
Maybe a
```

This allows the system to distinguish between:

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
Context -> Request -> Either DomainError Decision
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
  -> Typed Decisions
  -> Interpreted Effects
```

It treats database schemas as relational representations of algebraic domain structures.

It treats API endpoints as typed pipelines from raw input to interpreted commands and serialized output.

It separates:

* parsing from decision-making
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
