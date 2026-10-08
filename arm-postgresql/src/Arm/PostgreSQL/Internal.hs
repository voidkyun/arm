{-# LANGUAGE DuplicateRecordFields #-}

module Arm.PostgreSQL.Internal where

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
  , SomeAsyncException
  , fromException
  , throwIO
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
import qualified Data.Text.Encoding as Text.Encoding
import qualified Data.Text.Lazy as LazyText
import qualified Data.Text.Lazy.Encoding as LazyText.Encoding
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
  interpreterResult "PostgreSQL query failed"
    (runPostgreSQLQueryUnchecked connection dbQuery)

-- Keep execution exceptions visible to withResource so it discards the connection.
runPostgreSQLQueryUnchecked :: Connection -> DBQuery a -> IO (Either ApiError a)
runPostgreSQLQueryUnchecked connection dbQuery =
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
        jsonRows <- query connection (jsonSelectQuery statement) (PostgreSQLParameters parameters)
        pure (decodeRows =<< decodeSQLRows jsonRows)

runPostgreSQLCommand :: Connection -> DBCommand a -> IO (Either ApiError a)
runPostgreSQLCommand connection dbCommand =
  interpreterResult "PostgreSQL command failed"
    (runPostgreSQLCommandUnchecked connection dbCommand)

runPostgreSQLCommandUnchecked :: Connection -> DBCommand a -> IO (Either ApiError a)
runPostgreSQLCommandUnchecked connection dbCommand =
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
  interpreterResult "PostgreSQL query failed"
    (withResource pool (`runPostgreSQLQueryUnchecked` dbQuery))

runPostgreSQLCommandWithPool :: Pool Connection -> DBCommand a -> IO (Either ApiError a)
runPostgreSQLCommandWithPool pool dbCommand =
  interpreterResult "PostgreSQL command failed"
    (withResource pool (`runPostgreSQLCommandUnchecked` dbCommand))

runExecuteCommand
  :: Connection
  -> SQLStatement
  -> [SQLParameter]
  -> (DBCommandResult -> Either ApiError a)
  -> IO (Either ApiError a)
runExecuteCommand connection statement parameters decodeResult = do
  rowsAffected <- execute connection (postgreSQLQuery statement) (PostgreSQLParameters parameters)
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
  jsonRows <- query connection (jsonReturningQuery statement) (PostgreSQLParameters parameters)
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
    ( Text.Encoding.encodeUtf8 . Text.pack $
        ( "select row_to_json(arm_rows)::text from ("
            <> normalizedSQLStatement statement
            <> "\n) as arm_rows"
        )
    )

jsonReturningQuery :: SQLStatement -> Query
jsonReturningQuery statement =
  Query
    ( Text.Encoding.encodeUtf8 . Text.pack $
        ( "with arm_command_rows as ("
            <> normalizedSQLStatement statement
            <> "\n) select row_to_json(arm_command_rows)::text from arm_command_rows"
        )
    )

postgreSQLQuery :: SQLStatement -> Query
postgreSQLQuery statement =
  Query (Text.Encoding.encodeUtf8 (Text.pack (normalizedSQLStatement statement)))

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
      SQLJSONValue (LazyText.unpack (LazyText.Encoding.decodeUtf8 (encode value)))
    Object _ ->
      SQLJSONValue (LazyText.unpack (LazyText.Encoding.decodeUtf8 (encode value)))

-- Catch only synchronous failures, after pool cleanup has completed.
interpreterResult :: String -> IO (Either ApiError a) -> IO (Either ApiError a)
interpreterResult prefix action = do
  result <- try action
  case result of
    Right value -> pure value
    Left exception ->
      case fromException exception :: Maybe SomeAsyncException of
        Just _ -> throwIO exception
        Nothing -> pure (Left (interpreterException prefix exception))

interpreterException :: String -> SomeException -> ApiError
interpreterException prefix exception =
  interpreterError (prefix <> ": " <> show exception)

interpreterError :: String -> ApiError
interpreterError message =
  ApiError
    { apiErrorKind = ApiUnexpectedInterpreterFailure
    , apiErrorMessage = message
    }
