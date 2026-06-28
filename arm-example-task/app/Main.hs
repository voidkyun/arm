{-# LANGUAGE DuplicateRecordFields #-}

module Main
  ( main
  ) where

import Arm.Core
  ( ApiError (..)
  , ApiErrorKind (..)
  , DBCommand (..)
  , DBQuery (..)
  , DomainErrorBoundary
  , EndpointName (..)
  , Observation (..)
  , RawRequest (..)
  , RawResponse (..)
  , Transition (..)
  , coreBoundary
  )
import Arm.PostgreSQL (postgreSQLBoundary)
import Arm.Wai
  ( armApplication
  , observationRoute
  , transitionRoute
  , waiBoundary
  )
import Network.Wai
  ( Application
  )
import Network.Wai.Handler.Warp
  ( run
  )

data TaskDomainError
  = EmptyTaskTitle
  deriving (Eq, Show)

main :: IO ()
main = do
  putStr
    ( unlines
        [ "arm-example-task"
        , coreBoundary
        , waiBoundary
        , postgreSQLBoundary
        , "Listening on http://localhost:8080"
        , "GET  /open-tasks"
        , "POST /create-task"
        ]
    )
  run 8080 taskApplication

taskApplication :: Application
taskApplication =
  armApplication
    [ observationRoute taskDomainErrorToApiError runSampleQuery openTasksObservation
    , transitionRoute taskDomainErrorToApiError runSampleQuery runSampleCommand createTaskTransition
    ]

openTasksObservation :: Observation () String TaskDomainError String
openTasksObservation =
  Observation
    { name = EndpointName "open-tasks"
    , decode = const (Right ())
    , buildQuery = const (DBQuery "load open task algebra extension")
    , observe = \context () ->
        Right ("open tasks observed from " <> context)
    , encode = \output ->
        Right (RawResponse output)
    }

createTaskTransition :: Transition String String TaskDomainError String String String
createTaskTransition =
  Transition
    { name = EndpointName "create-task"
    , decode = \(RawRequest rawBody) ->
        if null rawBody
          then Left (ApiError ApiValidationError "create-task requires a task title in the request body")
          else Right rawBody
    , buildQuery = \title ->
        DBQuery ("load task creation context for " <> title)
    , decide = \context title ->
        if null title
          then Left EmptyTaskTitle
          else Right ("add Task with title " <> title <> " using " <> context)
    , buildCommand = \delta ->
        DBCommand ("apply delta: " <> delta)
    , respond = \context result ->
        Right ("created task through " <> result <> " after " <> context)
    , encode = \output ->
        Right (RawResponse output)
    }

runSampleQuery :: DBQuery String -> IO (Either ApiError String)
runSampleQuery query =
  pure (Right (dbQueryDescription query <> " [sample query result]"))

runSampleCommand :: DBCommand String -> IO (Either ApiError String)
runSampleCommand command =
  pure (Right (dbCommandDescription command <> " [sample command result]"))

taskDomainErrorToApiError :: DomainErrorBoundary TaskDomainError
taskDomainErrorToApiError domainError =
  case domainError of
    EmptyTaskTitle ->
      ApiError ApiValidationError "task title must not be empty"
