{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Arm.Core
import Arm.PostgreSQL
import Control.Exception (bracket)
import Control.Monad (unless)
import qualified Data.ByteString.Char8 as BS
import Data.Pool
import Database.PostgreSQL.Simple (connectPostgreSQL, close, execute_)
import System.Environment (getEnv)
import Task.Domain
import Task.SQL

main :: IO ()
main = do
  url <- BS.pack <$> getEnv "ARM_TEST_DATABASE_URL"
  bracket (connectPostgreSQL url) close $ \connection -> do
    let query = sqlQuery "typed SQL parameter round trip" (SQLStatement
          "SELECT ?::text AS title, ?::bigint AS id, ?::boolean AS enabled, ?::double precision AS score, ?::text AS absent")
          [SQLTextParameter "日本語 '); DROP TABLE tasks; --", SQLIntegerParameter 42, SQLBoolParameter True, SQLDoubleParameter 1.5, SQLNullParameter] Right
    rows <- requireRight =<< runPostgreSQLQuery connection query
    row <- requireRight (singleSQLRow rows)
    check "parameterized Unicode, integer, boolean, double and NULL" $
      sqlColumnText "title" row == Right "日本語 '); DROP TABLE tasks; --" && sqlColumnInteger "id" row == Right 42
      && sqlColumnBool "enabled" row == Right True && sqlColumnDouble "score" row == Right 1.5 && sqlColumn "absent" row == Right SQLNullValue
    failed <- runPostgreSQLQuery connection (sqlQuery "invalid statement" (SQLStatement "SELECT private_missing_column") [] Right)
    check "query failures are structured and hide SQL internals" $ case failed of
      Left err -> apiErrorKind err == ApiUnexpectedInterpreterFailure && apiErrorMessage err == "PostgreSQL query failed"
      _ -> False
    _ <- execute_ connection "BEGIN"
    context <- requireRight =<< runPostgreSQLQuery connection (taskContextQuery (TaskId 1))
    delta <- requireRight (decideAssignTaskDelta context (AssignTaskInput (TaskId 1) Nothing))
    result <- requireRight =<< runPostgreSQLCommand connection (dbCommandFromDelta assignTaskCommand delta)
    check "real assignment command removes the relation" (assignedUser result == Nothing)
    stale <- runPostgreSQLCommand connection (dbCommandFromDelta assignTaskCommand delta)
    check "stale delta cannot overwrite a newer mapping" $ case stale of
      Left err -> apiErrorKind err == ApiConflictError
      _ -> False
    after <- requireRight =<< runPostgreSQLQuery connection (taskContextQuery (TaskId 1))
    closeDelta <- requireRight (decideCloseTaskDelta after (CloseTaskInput (TaskId 1)))
    _ <- requireRight =<< runPostgreSQLCommand connection (dbCommandFromDelta closeTaskCommand closeDelta)
    closed <- requireRight =<< runPostgreSQLQuery connection (taskContextQuery (TaskId 1))
    check "closed status rejects later pure transitions" (decideCloseTaskDelta closed (CloseTaskInput (TaskId 1)) == Left TaskAlreadyClosed)
    _ <- execute_ connection "ROLLBACK"
    failedCommand <- runPostgreSQLCommand connection (sqlCommand "invalid command" (SQLStatement "UPDATE private_missing_table SET id = 1") [] Right)
    check "command failures are structured" $ case failedCommand of Left err -> apiErrorKind err == ApiUnexpectedInterpreterFailure; _ -> False
    _ <- requireRight =<< runPostgreSQLCommand connection (sqlCommand "temporary mapping" (SQLStatement "CREATE TEMP TABLE arm_test_delta (id integer PRIMARY KEY)") [] Right)
    _ <- requireRight =<< runPostgreSQLCommand connection (sqlCommand "apply mapping" (SQLStatement "INSERT INTO arm_test_delta VALUES (?)") [SQLIntegerParameter 1] Right)
    conflict <- runPostgreSQLCommand connection (sqlCommand "duplicate mapping" (SQLStatement "INSERT INTO arm_test_delta VALUES (?)") [SQLIntegerParameter 1] Right)
    check "constraint failures map to conflict" $ case conflict of Left err -> apiErrorKind err == ApiConflictError; _ -> False
  bracket (newPool (defaultPoolConfig (connectPostgreSQL url) close 30 2)) destroyAllResources $ \pool -> do
    count <- requireRight =<< runPostgreSQLQueryWithPool pool (sqlQuery "pool read" (SQLStatement "SELECT count(*) AS count FROM tasks") [] (\rows -> singleSQLRow rows >>= sqlColumnInteger "count"))
    check "pool executes real reads" (count == 3)
    result <- requireRight =<< runPostgreSQLCommandWithPool pool (sqlCommand "pool command" (SQLStatement "UPDATE tasks SET version = version WHERE id = ?") [SQLIntegerParameter 99999] Right)
    check "pool executes commands" (dbCommandRowsAffected result == 0)
  bracket (connectPostgreSQL (url <> " options='-c default_transaction_read_only=on'")) close $ \connection -> do
    _ <- requireRight =<< runPostgreSQLQuery connection (openTasksQuery (OpenTasksInput Nothing))
    forbidden <- runPostgreSQLCommand connection (sqlCommand "prove read-only DB" (SQLStatement "UPDATE tasks SET version = version WHERE id = 1") [] Right)
    check "observation connection cannot execute writes" $ case forbidden of Left _ -> True; _ -> False
  putStrLn "All real PostgreSQL interpreter and stale-delta checks passed"

requireRight :: Show e => Either e a -> IO a
requireRight = either (ioError . userError . show) pure
check :: String -> Bool -> IO ()
check label passed = unless passed (ioError (userError label)) >> putStrLn ("PASS: " <> label)
