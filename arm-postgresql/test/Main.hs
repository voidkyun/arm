{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Arm.Core
import Arm.PostgreSQL.Internal
import Control.Exception
import Control.Monad (unless)
import Data.Aeson (eitherDecodeStrict')
import Data.IORef
import Data.Pool
import qualified Data.Text
import qualified Data.Text.Encoding as Text
import Database.PostgreSQL.Simple.Types (Query (..))

check :: String -> Bool -> IO ()
check name passed = unless passed (error name)

main :: IO ()
main = do
  let statement = SQLStatement "select '日本語' as title -- comment\n"
      Query selectBytes = jsonSelectQuery statement
      Query returningBytes = jsonReturningQuery statement
      Query commandBytes = postgreSQLQuery statement
  check "query preserves Unicode and separates trailing comments"
    (Text.decodeUtf8 selectBytes == "select row_to_json(arm_rows)::text from (select '日本語' as title -- comment\n) as arm_rows")
  check "returning preserves Unicode and separates trailing comments"
    (Text.decodeUtf8 returningBytes == "with arm_command_rows as (select '日本語' as title -- comment\n) select row_to_json(arm_command_rows)::text from arm_command_rows")
  check "execute preserves Unicode"
    (Text.decodeUtf8 commandBytes == "select '日本語' as title -- comment")
  mapM_ (\json -> case eitherDecodeStrict' (Text.encodeUtf8 json) of
    Left message -> error message
    Right value -> case valueToSQLValue value of
      SQLJSONValue rendered -> check "nested JSON preserves Unicode" (eitherDecodeStrict' (Text.encodeUtf8 (Data.Text.pack rendered)) == Right value)
      _ -> error "expected JSON value")
    ["{\"title\":\"日本語\"}", "[\"日本語\"]"]
  mapM_ (\exception -> do
    result <- try (interpreterResult "test" (throwIO exception)) :: IO (Either AsyncException (Either ApiError ()))
    check "async exceptions propagate" (result == Left exception)) [ThreadKilled, UserInterrupt]
  let cancelledConnection = throw ThreadKilled
      queryPlan = sqlQuery "test" (SQLStatement "select 1") [] (const (Right ()))
      commandPlan = sqlCommand "test" (SQLStatement "delete from tasks") [] (const (Right ()))
      returningPlan = sqlCommandReturning "test" (SQLStatement "delete from tasks returning id") [] (const (Right ()))
  mapM_ (\action -> do
    cancelled <- try action :: IO (Either AsyncException (Either ApiError ()))
    check "every execution mode propagates cancellation" (cancelled == Left ThreadKilled))
    [ runPostgreSQLQuery cancelledConnection queryPlan
    , runPostgreSQLCommand cancelledConnection commandPlan
    , runPostgreSQLCommand cancelledConnection returningPlan
    ]
  result <- interpreterResult "test" (throwIO (userError "connection lost")) :: IO (Either ApiError ())
  check "synchronous failures become API errors" (case result of Left _ -> True; _ -> False)
  created <- newIORef (0 :: Int)
  destroyed <- newIORef ([] :: [Int])
  pool <- newPool (defaultPoolConfig
    (atomicModifyIORef' created (\n -> (n + 1, n + 1)))
    (\resource -> modifyIORef' destroyed (resource :)) 60 1)
  failure <- interpreterResult "pool" (withResource pool (\_ -> throwIO (userError "connection lost"))) :: IO (Either ApiError ())
  check "pool failure becomes API error" (case failure of Left _ -> True; _ -> False)
  discarded <- readIORef destroyed
  check "failed resource is destroyed" (discarded == [1])
  next <- withResource pool pure
  check "next request receives a new resource" (next == 2)
  destroyAllResources pool
  putStrLn "PostgreSQL regression checks passed"
