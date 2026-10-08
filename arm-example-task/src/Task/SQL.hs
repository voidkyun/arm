{-# LANGUAGE OverloadedStrings #-}
module Task.SQL where

import Arm.Core
import Data.Aeson (eitherDecodeStrict')
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Task.Domain

integer :: Integer -> SQLParameter
integer = SQLIntegerParameter
userParameter :: Maybe UserId -> SQLParameter
userParameter = maybe SQLNullParameter (integer . unUserId)

createTaskQuery :: CreateTaskInput -> DBQuery CreateTaskContext
createTaskQuery input = sqlQuery "load project and membership relation for task creation"
  (SQLStatement $ unlines
    [ "SELECT EXISTS(SELECT 1 FROM projects WHERE id = ?) AS project_exists,"
    , "EXISTS(SELECT 1 FROM users WHERE id = ?) AS actor_exists,"
    , "COALESCE((SELECT json_agg(user_id) FROM project_members WHERE project_id = ?), '[]') AS members,"
    , "current_timestamp::text AS now" ])
  [integer (unProjectId (projectArgument input)), integer (unUserId (actorArgument input)), integer (unProjectId (projectArgument input))]
  (\rows -> do
    row <- singleSQLRow rows
    CreateTaskContext <$> sqlColumnBool "project_exists" row <*> sqlColumnBool "actor_exists" row
      <*> decodeMembers row <*> sqlColumnText "now" row)

taskContextQuery :: TaskId -> DBQuery TaskContext
taskContextQuery requested = sqlQuery "load task mappings and project membership"
  (SQLStatement $ unlines
    [ "SELECT t.id AS task_id, t.title, t.project_id, t.status, t.assignee_id, t.version,"
    , "COALESCE((SELECT json_agg(user_id) FROM project_members WHERE project_id = t.project_id), '[]') AS members,"
    , "current_timestamp::text AS now FROM (SELECT 1) AS anchor LEFT JOIN tasks t ON t.id = ?" ])
  [integer (unTaskId requested)]
  (\rows -> do
    row <- singleSQLRow rows
    TaskContext <$> optionalFact row <*> decodeMembers row <*> sqlColumnText "now" row)

openTasksQuery :: OpenTasksInput -> DBQuery ObservationContext
openTasksQuery input = observationQuery "load open task mappings"
  "(?::bigint IS NULL OR EXISTS(SELECT 1 FROM projects WHERE id = ?))"
  "t.status = 'open' AND (?::bigint IS NULL OR t.project_id = ?)"
  [project, project, project, project]
  where project = maybe SQLNullParameter (integer . unProjectId) (openProjectArgument input)

projectTaskStateQuery :: ProjectTaskStateInput -> DBQuery ObservationContext
projectTaskStateQuery input = observationQuery "load status mapping for project"
  "EXISTS(SELECT 1 FROM projects WHERE id = ?)" "t.project_id = ?" [project, project]
  where project = integer (unProjectId (stateProjectArgument input))

assigneeInboxQuery :: AssigneeInboxInput -> DBQuery ObservationContext
assigneeInboxQuery input = observationQuery "load open assignee relation"
  "EXISTS(SELECT 1 FROM users WHERE id = ?)" "t.status = 'open' AND t.assignee_id = ?" [user, user]
  where user = integer (unUserId (inboxUserArgument input))

observationQuery :: String -> String -> String -> [SQLParameter] -> DBQuery ObservationContext
observationQuery description subject condition parameters = sqlQuery description
  (SQLStatement $ "SELECT " <> subject <> " AS subject_exists, t.id AS task_id, t.title, t.project_id, t.status, t.assignee_id, t.version "
    <> "FROM (SELECT 1) AS anchor LEFT JOIN tasks t ON " <> condition <> " ORDER BY t.id")
  parameters
  (\(SQLRows rows) -> case rows of
    [] -> Left (ApiError ApiUnexpectedInterpreterFailure "missing observation anchor")
    row : _ -> do
      exists <- sqlColumnBool "subject_exists" row
      facts <- traverse optionalFact rows
      Right (ObservationContext exists [fact | Just fact <- facts]))

decodeMembers :: SQLRow -> Either ApiError (Set.Set UserId)
decodeMembers row = do
  value <- sqlColumn "members" row
  case value of
    SQLJSONValue json -> case eitherDecodeStrict' (Text.encodeUtf8 (Text.pack json)) of
      Right ids -> Right (Set.fromList (map UserId ids))
      Left _ -> Left (ApiError ApiUnexpectedInterpreterFailure "invalid membership context")
    _ -> Left (ApiError ApiUnexpectedInterpreterFailure "expected membership relation")

optionalFact :: SQLRow -> Either ApiError (Maybe TaskFact)
optionalFact row = do
  value <- sqlColumn "task_id" row
  case value of
    SQLNullValue -> Right Nothing
    _ -> Just <$> (TaskFact <$> (TaskId <$> sqlColumnInteger "task_id" row)
      <*> sqlColumnText "title" row <*> (ProjectId <$> sqlColumnInteger "project_id" row)
      <*> decodeStatus row <*> optionalUser "assignee_id" row <*> sqlColumnInteger "version" row)

decodeStatus :: SQLRow -> Either ApiError Status
decodeStatus row = do
  status <- sqlColumnText "status" row
  case status of
    "open" -> Right Open
    "closed" -> Right Closed
    _ -> Left (ApiError ApiInvariantViolation "unknown task status")

optionalUser :: String -> SQLRow -> Either ApiError (Maybe UserId)
optionalUser column row = do
  value <- sqlColumn column row
  case value of
    SQLNullValue -> Right Nothing
    _ -> Just . UserId <$> sqlColumnInteger column row

-- Membership predicates recheck the context at application time; all required
-- mappings are added in one statement. FK constraints preserve the relation.
createTaskCommand :: DeltaCommand CreateTaskDelta CreateTaskResult
createTaskCommand = DeltaCommand
  { deltaCommandDescription = const "add fresh Task with all required mappings"
  , deltaCommandStatement = const (SQLStatement $ unlines
      [ "INSERT INTO tasks (title, project_id, status, created_by, created_at, assignee_id)"
      , "SELECT ?, ?, ?, ?, ?::timestamptz, ?::bigint"
      , "WHERE EXISTS(SELECT 1 FROM project_members WHERE project_id = ? AND user_id = ?)"
      , "AND (?::bigint IS NULL OR EXISTS(SELECT 1 FROM project_members WHERE project_id = ? AND user_id = ?))"
      , "RETURNING id" ])
  , deltaCommandParameters = \delta ->
      let project = integer (unProjectId (addProject delta))
          actor = integer (unUserId (addCreator delta))
          assignee = userParameter (addAssignee delta)
      in [SQLTextParameter (addTitle delta), project, SQLTextParameter (statusText (addStatus delta)), actor,
          SQLTextParameter (addCreatedAt delta), assignee, project, actor, assignee, project, assignee]
  , deltaCommandMode = SQLCommandReturningRows
  , deltaCommandDecodeResult = \_ result -> CreateTaskResult . TaskId <$> (commandRow result >>= sqlColumnInteger "id")
  }

closeTaskCommand :: DeltaCommand CloseTaskDelta CloseTaskResult
closeTaskCommand = DeltaCommand
  { deltaCommandDescription = const "replace Open status with Closed and add closedAt"
  , deltaCommandStatement = const (SQLStatement
      "UPDATE tasks SET status = 'closed', closed_at = ?::timestamptz, version = version + 1 WHERE id = ? AND version = ? AND status = 'open' RETURNING id, version")
  , deltaCommandParameters = \delta -> [SQLTextParameter (addClosedAt delta), integer (unTaskId (closeTask delta)), integer (closeExpectedVersion delta)]
  , deltaCommandMode = SQLCommandReturningRows
  , deltaCommandDecodeResult = \_ result -> do
      row <- commandRow result
      CloseTaskResult <$> (TaskId <$> sqlColumnInteger "id" row) <*> sqlColumnInteger "version" row
  }

assignTaskCommand :: DeltaCommand AssignTaskDelta AssignTaskResult
assignTaskCommand = DeltaCommand
  { deltaCommandDescription = const "replace or remove assignee mapping"
  , deltaCommandStatement = const (SQLStatement $ unlines
      [ "UPDATE tasks SET assignee_id = ?::bigint, version = version + 1"
      , "WHERE id = ? AND version = ? AND status = 'open'"
      , "AND (?::bigint IS NULL OR EXISTS(SELECT 1 FROM project_members WHERE project_id = tasks.project_id AND user_id = ?))"
      , "RETURNING id, assignee_id, version" ])
  , deltaCommandParameters = \delta -> let assignee = userParameter (replaceAssignee delta)
      in [assignee, integer (unTaskId (assignTask delta)), integer (assignExpectedVersion delta), assignee, assignee]
  , deltaCommandMode = SQLCommandReturningRows
  , deltaCommandDecodeResult = \_ result -> do
      row <- commandRow result
      AssignTaskResult <$> (TaskId <$> sqlColumnInteger "id" row) <*> optionalUser "assignee_id" row <*> sqlColumnInteger "version" row
  }

commandRow :: DBCommandResult -> Either ApiError SQLRow
commandRow result = case unSQLRows (dbCommandReturnedRows result) of
  [] -> Left (ApiError ApiConflictError "context changed before delta application; reload and retry")
  _ -> singleSQLRow (dbCommandReturnedRows result)

statusText :: Status -> String
statusText Open = "open"
statusText Closed = "closed"
