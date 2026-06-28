{-# LANGUAGE DuplicateRecordFields #-}

module Main
  ( main
  ) where

import Arm.Core
  ( ApiError (..)
  , ApiErrorKind (..)
  , DBCommand (..)
  , DBCommandResult (..)
  , DBQuery (..)
  , DeltaCommand (..)
  , DomainErrorBoundary
  , EndpointName (..)
  , Observation (..)
  , RawRequest (..)
  , RawResponse (..)
  , SQLCommandMode (..)
  , SQLParameter (..)
  , SQLRows (..)
  , SQLStatement (..)
  , Transition (..)
  , coreBoundary
  , dbCommandFromDelta
  , singleSQLRow
  , sqlColumnInteger
  , sqlQuery
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

data CreateTaskDelta = CreateTaskDelta
  { createTaskTitle :: String
  , createTaskContext :: String
  }
  deriving (Eq, Show)

newtype CreateTaskResult = CreateTaskResult
  { createdTaskId :: Integer
  }
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
    , buildQuery =
        const
          ( sqlQuery
              "load open task algebra extension"
              (SQLStatement "select id, title from tasks where status = ? order by id")
              [SQLTextParameter "open"]
              decodeOpenTasks
          )
    , observe = \context () ->
        Right ("open tasks observed from " <> context)
    , encode = \output ->
        Right (RawResponse output)
    }

createTaskTransition :: Transition String String TaskDomainError CreateTaskDelta CreateTaskResult String
createTaskTransition =
  Transition
    { name = EndpointName "create-task"
    , decode = \(RawRequest rawBody) ->
        if null rawBody
          then Left (ApiError ApiValidationError "create-task requires a task title in the request body")
          else Right rawBody
    , buildQuery = \title ->
        sqlQuery
          ("load task creation context for " <> title)
          (SQLStatement "select ?::text as requested_title")
          [SQLTextParameter title]
          decodeCreateTaskContext
    , decide = \context title ->
        if null title
          then Left EmptyTaskTitle
          else
            Right
              CreateTaskDelta
                { createTaskTitle = title
                , createTaskContext = context
                }
    , buildCommand = dbCommandFromDelta createTaskCommand
    , respond = \context result ->
        Right ("created task " <> show (createdTaskId result) <> " after " <> context)
    , encode = \output ->
        Right (RawResponse output)
    }

createTaskCommand :: DeltaCommand CreateTaskDelta CreateTaskResult
createTaskCommand =
  DeltaCommand
    { deltaCommandDescription = \delta ->
        "apply CreateTaskDelta by inserting task algebra mappings for "
          <> createTaskTitle delta
    , deltaCommandStatement =
        const
          ( SQLStatement
              "insert into tasks (title, status, creation_context) values (?, ?, ?) returning id"
          )
    , deltaCommandParameters = \delta ->
        [ SQLTextParameter (createTaskTitle delta)
        , SQLTextParameter "open"
        , SQLTextParameter (createTaskContext delta)
        ]
    , deltaCommandMode = SQLCommandReturningRows
    , deltaCommandDecodeResult = \_ result -> do
        row <- singleSQLRow (dbCommandReturnedRows result)
        CreateTaskResult <$> sqlColumnInteger "id" row
    }

decodeOpenTasks :: SQLRows -> Either ApiError String
decodeOpenTasks rows =
  Right ("open task rows: " <> show (length (unSQLRows rows)))

decodeCreateTaskContext :: SQLRows -> Either ApiError String
decodeCreateTaskContext rows =
  Right ("task creation context rows: " <> show (length (unSQLRows rows)))

runSampleQuery :: DBQuery String -> IO (Either ApiError String)
runSampleQuery query =
  pure (Right (dbQueryDescription query <> " [sample query result]"))

runSampleCommand :: DBCommand CreateTaskResult -> IO (Either ApiError CreateTaskResult)
runSampleCommand command =
  pure
    ( Right
        CreateTaskResult
          { createdTaskId = fromIntegral (length (dbCommandDescription command))
          }
    )

taskDomainErrorToApiError :: DomainErrorBoundary TaskDomainError
taskDomainErrorToApiError domainError =
  case domainError of
    EmptyTaskTitle ->
      ApiError ApiValidationError "task title must not be empty"
