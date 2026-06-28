{-# LANGUAGE DuplicateRecordFields #-}

module Arm.PostgreSQL
  ( postgreSQLBoundary
  , runPostgreSQLQuery
  , runPostgreSQLCommand
  , runPostgreSQLQueryWithPool
  , runPostgreSQLCommandWithPool
  ) where

import Arm.Core
  ( ApiError (..)
  , ApiErrorKind (..)
  , DBCommand (..)
  , DBCommandPlan (..)
  , DBCommandResult (..)
  , DBQuery (..)
  , DBQueryPlan (..)
  , SQLCommandMode (..)
  , SQLParameter (..)
  , SQLRow (..)
  , SQLRows (..)
  , SQLStatement (..)
  , SQLValue (..)
  , coreBoundary
  )
import Control.Exception
  ( SomeException
  , try
  )
import Data.Aeson
  ( Value (..)
  , eitherDecodeStrict'
  , encode
  )
import qualified Data.Aeson.Key as Aeson.Key
import qualified Data.Aeson.KeyMap as Aeson.KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import qualified Data.ByteString.Lazy.Char8 as LazyByteString.Char8
import Data.Char
  ( isSpace
  )
import Data.Pool
  ( Pool
  , withResource
  )
import Data.Scientific
  ( floatingOrInteger
  )
import qualified Data.Text as Text
import Database.PostgreSQL.Simple
  ( Connection
  , Only (..)
  , execute
  , query
  )
import Database.PostgreSQL.Simple.ToField
  ( Action
  , toField
  )
import Database.PostgreSQL.Simple.ToRow
  ( ToRow (..)
  )
import Database.PostgreSQL.Simple.Types
  ( Query (..)
  )

postgreSQLBoundary :: String
postgreSQLBoundary = coreBoundary ++ "/arm-postgresql"

runPostgreSQLQuery :: Connection -> DBQuery a -> IO (Either ApiError a)
runPostgreSQLQuery connection dbQuery =
  case dbQueryPlan dbQuery of
    DescribedDBQuery ->
      pure
        ( Left
            ( interpreterError
                ( "PostgreSQL cannot execute a query without SQL: "
                    <> dbQueryDescription dbQuery
                )
            )
        )
    SQLDBQuery
      { dbQueryStatement = statement
      , dbQueryParameters = parameters
      , dbQueryDecodeRows = decodeRows
      } -> do
        rowsResult <-
          try
            ( query
                connection
                (jsonSelectQuery statement)
                (PostgreSQLParameters parameters)
            )
        case rowsResult of
          Left exception ->
            pure (Left (interpreterException "PostgreSQL query failed" exception))
          Right jsonRows ->
            pure (decodeRows =<< decodeSQLRows jsonRows)

runPostgreSQLCommand :: Connection -> DBCommand a -> IO (Either ApiError a)
runPostgreSQLCommand connection dbCommand =
  case dbCommandPlan dbCommand of
    DescribedDBCommand ->
      pure
        ( Left
            ( interpreterError
                ( "PostgreSQL cannot execute a command without SQL: "
                    <> dbCommandDescription dbCommand
                )
            )
        )
    SQLDBCommand
      { dbCommandStatement = statement
      , dbCommandParameters = parameters
      , dbCommandMode = mode
      , dbCommandDecodeResult = decodeResult
      } ->
        case mode of
          SQLCommandExecute ->
            runExecuteCommand connection statement parameters decodeResult
          SQLCommandReturningRows ->
            runReturningCommand connection statement parameters decodeResult

runPostgreSQLQueryWithPool :: Pool Connection -> DBQuery a -> IO (Either ApiError a)
runPostgreSQLQueryWithPool pool dbQuery =
  withResource pool (`runPostgreSQLQuery` dbQuery)

runPostgreSQLCommandWithPool :: Pool Connection -> DBCommand a -> IO (Either ApiError a)
runPostgreSQLCommandWithPool pool dbCommand =
  withResource pool (`runPostgreSQLCommand` dbCommand)

runExecuteCommand
  :: Connection
  -> SQLStatement
  -> [SQLParameter]
  -> (DBCommandResult -> Either ApiError a)
  -> IO (Either ApiError a)
runExecuteCommand connection statement parameters decodeResult = do
  executeResult <-
    try
      ( execute
          connection
          (postgreSQLQuery statement)
          (PostgreSQLParameters parameters)
      )
  case executeResult of
    Left exception ->
      pure (Left (interpreterException "PostgreSQL command failed" exception))
    Right rowsAffected ->
      pure
        ( decodeResult
            DBCommandResult
              { dbCommandRowsAffected = fromIntegral rowsAffected
              , dbCommandReturnedRows = SQLRows []
              }
        )

runReturningCommand
  :: Connection
  -> SQLStatement
  -> [SQLParameter]
  -> (DBCommandResult -> Either ApiError a)
  -> IO (Either ApiError a)
runReturningCommand connection statement parameters decodeResult = do
  rowsResult <-
    try
      ( query
          connection
          (jsonReturningQuery statement)
          (PostgreSQLParameters parameters)
      )
  case rowsResult of
    Left exception ->
      pure (Left (interpreterException "PostgreSQL returning command failed" exception))
    Right jsonRows ->
      pure
        ( do
            rows <- decodeSQLRows jsonRows
            decodeResult
              DBCommandResult
                { dbCommandRowsAffected = fromIntegral (length (unSQLRows rows))
                , dbCommandReturnedRows = rows
                }
        )

newtype PostgreSQLParameters = PostgreSQLParameters [SQLParameter]

instance ToRow PostgreSQLParameters where
  toRow (PostgreSQLParameters parameters) =
    parameterAction <$> parameters

parameterAction :: SQLParameter -> Action
parameterAction parameter =
  case parameter of
    SQLNullParameter ->
      toField (Nothing :: Maybe String)
    SQLTextParameter value ->
      toField value
    SQLIntegerParameter value ->
      toField value
    SQLDoubleParameter value ->
      toField value
    SQLBoolParameter value ->
      toField value

jsonSelectQuery :: SQLStatement -> Query
jsonSelectQuery statement =
  Query
    ( ByteString.Char8.pack
        ( "select row_to_json(arm_rows)::text from ("
            <> normalizedSQLStatement statement
            <> ") as arm_rows"
        )
    )

jsonReturningQuery :: SQLStatement -> Query
jsonReturningQuery statement =
  Query
    ( ByteString.Char8.pack
        ( "with arm_command_rows as ("
            <> normalizedSQLStatement statement
            <> ") select row_to_json(arm_command_rows)::text from arm_command_rows"
        )
    )

postgreSQLQuery :: SQLStatement -> Query
postgreSQLQuery statement =
  Query (ByteString.Char8.pack (normalizedSQLStatement statement))

normalizedSQLStatement :: SQLStatement -> String
normalizedSQLStatement (SQLStatement statement) =
  dropTrailingSemicolons statement

dropTrailingSemicolons :: String -> String
dropTrailingSemicolons statement =
  reverse
    ( dropWhile isSpace
        ( dropWhile (== ';')
            (dropWhile isSpace (reverse statement))
        )
    )

decodeSQLRows :: [Only ByteString.ByteString] -> Either ApiError SQLRows
decodeSQLRows jsonRows =
  SQLRows <$> traverse decodeSQLRow jsonRows

decodeSQLRow :: Only ByteString.ByteString -> Either ApiError SQLRow
decodeSQLRow (Only jsonRow) =
  case eitherDecodeStrict' jsonRow of
    Left message ->
      Left (interpreterError ("PostgreSQL row JSON decode failed: " <> message))
    Right value ->
      valueToSQLRow value

valueToSQLRow :: Value -> Either ApiError SQLRow
valueToSQLRow value =
  case value of
    Object object ->
      SQLRow <$> traverse columnValue (Aeson.KeyMap.toList object)
    _ ->
      Left (interpreterError "PostgreSQL row JSON was not an object")
  where
    columnValue (key, columnJSON) =
      Right (Aeson.Key.toString key, valueToSQLValue columnJSON)

valueToSQLValue :: Value -> SQLValue
valueToSQLValue value =
  case value of
    Null ->
      SQLNullValue
    String text ->
      SQLTextValue (Text.unpack text)
    Number number ->
      case floatingOrInteger number of
        Right integer ->
          SQLIntegerValue integer
        Left double ->
          SQLDoubleValue double
    Bool bool ->
      SQLBoolValue bool
    Array _ ->
      SQLJSONValue (LazyByteString.Char8.unpack (encode value))
    Object _ ->
      SQLJSONValue (LazyByteString.Char8.unpack (encode value))

interpreterException :: String -> SomeException -> ApiError
interpreterException prefix exception =
  interpreterError (prefix <> ": " <> show exception)

interpreterError :: String -> ApiError
interpreterError message =
  ApiError
    { apiErrorKind = ApiUnexpectedInterpreterFailure
    , apiErrorMessage = message
    }
