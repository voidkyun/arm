{-# LANGUAGE DuplicateRecordFields #-}

module Arm.Core
  ( EndpointName (..)
  , RawRequest (..)
  , RawResponse (..)
  , ApiErrorKind (..)
  , ApiError (..)
  , DomainErrorBoundary
  , ZeroDelta (..)
  , SQLStatement (..)
  , SQLParameter (..)
  , SQLValue (..)
  , SQLRow (..)
  , SQLRows (..)
  , DBCommandResult (..)
  , DBQuery (..)
  , DBQueryPlan (..)
  , DBCommand (..)
  , DBCommandPlan (..)
  , SQLCommandMode (..)
  , DeltaCommand (..)
  , describeDBQuery
  , sqlQuery
  , describeDBCommand
  , sqlCommand
  , sqlCommandReturning
  , dbCommandFromDelta
  , singleSQLRow
  , sqlColumn
  , sqlColumnText
  , sqlColumnInteger
  , sqlColumnDouble
  , sqlColumnBool
  , Observation (..)
  , Transition (..)
  , executeObservation
  , executeTransition
  , coreBoundary
  ) where

newtype EndpointName = EndpointName
  { unEndpointName :: String
  }
  deriving (Eq, Ord, Show)

newtype RawRequest = RawRequest
  { rawRequestBody :: String
  }
  deriving (Eq, Ord, Show)

newtype RawResponse = RawResponse
  { rawResponseBody :: String
  }
  deriving (Eq, Ord, Show)

data ApiErrorKind
  = ApiParseError
  | ApiValidationError
  | ApiAuthorizationError
  | ApiNotFoundError
  | ApiConflictError
  | ApiInvariantViolation
  | ApiUnexpectedInterpreterFailure
  deriving (Eq, Ord, Show)

data ApiError = ApiError
  { apiErrorKind :: ApiErrorKind
  , apiErrorMessage :: String
  }
  deriving (Eq, Ord, Show)

type DomainErrorBoundary domainError = domainError -> ApiError

-- | The empty change to a domain algebra extension.
data ZeroDelta = ZeroDelta
  deriving (Eq, Ord, Show)

newtype SQLStatement = SQLStatement
  { unSQLStatement :: String
  }
  deriving (Eq, Ord, Show)

data SQLParameter
  = SQLNullParameter
  | SQLTextParameter String
  | SQLIntegerParameter Integer
  | SQLDoubleParameter Double
  | SQLBoolParameter Bool
  deriving (Eq, Ord, Show)

data SQLValue
  = SQLNullValue
  | SQLTextValue String
  | SQLIntegerValue Integer
  | SQLDoubleValue Double
  | SQLBoolValue Bool
  | SQLJSONValue String
  deriving (Eq, Ord, Show)

newtype SQLRow = SQLRow
  { sqlRowColumns :: [(String, SQLValue)]
  }
  deriving (Eq, Ord, Show)

newtype SQLRows = SQLRows
  { unSQLRows :: [SQLRow]
  }
  deriving (Eq, Ord, Show)

data DBCommandResult = DBCommandResult
  { dbCommandRowsAffected :: Integer
  , dbCommandReturnedRows :: SQLRows
  }
  deriving (Eq, Ord, Show)

data DBQueryPlan a
  = DescribedDBQuery
  | SQLDBQuery
      { dbQueryStatement :: SQLStatement
      , dbQueryParameters :: [SQLParameter]
      , dbQueryDecodeRows :: SQLRows -> Either ApiError a
      }

data DBQuery a = DBQuery
  { dbQueryDescription :: String
  , dbQueryPlan :: DBQueryPlan a
  }

data SQLCommandMode
  = SQLCommandExecute
  | SQLCommandReturningRows
  deriving (Eq, Ord, Show)

data DBCommandPlan a
  = DescribedDBCommand
  | SQLDBCommand
      { dbCommandStatement :: SQLStatement
      , dbCommandParameters :: [SQLParameter]
      , dbCommandMode :: SQLCommandMode
      , dbCommandDecodeResult :: DBCommandResult -> Either ApiError a
      }

data DBCommand a = DBCommand
  { dbCommandDescription :: String
  , dbCommandPlan :: DBCommandPlan a
  }

data DeltaCommand delta result = DeltaCommand
  { deltaCommandDescription :: delta -> String
  , deltaCommandStatement :: delta -> SQLStatement
  , deltaCommandParameters :: delta -> [SQLParameter]
  , deltaCommandMode :: SQLCommandMode
  , deltaCommandDecodeResult :: delta -> DBCommandResult -> Either ApiError result
  }

instance Eq (DBQuery a) where
  left == right =
    dbQueryComparable left == dbQueryComparable right

instance Ord (DBQuery a) where
  compare left right =
    compare (dbQueryComparable left) (dbQueryComparable right)

instance Show (DBQuery a) where
  show query =
    "DBQuery "
      <> show (dbQueryComparable query)

instance Eq (DBCommand a) where
  left == right =
    dbCommandComparable left == dbCommandComparable right

instance Ord (DBCommand a) where
  compare left right =
    compare (dbCommandComparable left) (dbCommandComparable right)

instance Show (DBCommand a) where
  show command =
    "DBCommand "
      <> show (dbCommandComparable command)

describeDBQuery :: String -> DBQuery a
describeDBQuery description =
  DBQuery
    { dbQueryDescription = description
    , dbQueryPlan = DescribedDBQuery
    }

sqlQuery
  :: String
  -> SQLStatement
  -> [SQLParameter]
  -> (SQLRows -> Either ApiError a)
  -> DBQuery a
sqlQuery description statement parameters decodeRows =
  DBQuery
    { dbQueryDescription = description
    , dbQueryPlan =
        SQLDBQuery
          { dbQueryStatement = statement
          , dbQueryParameters = parameters
          , dbQueryDecodeRows = decodeRows
          }
    }

describeDBCommand :: String -> DBCommand a
describeDBCommand description =
  DBCommand
    { dbCommandDescription = description
    , dbCommandPlan = DescribedDBCommand
    }

sqlCommand
  :: String
  -> SQLStatement
  -> [SQLParameter]
  -> (DBCommandResult -> Either ApiError a)
  -> DBCommand a
sqlCommand description statement parameters decodeResult =
  DBCommand
    { dbCommandDescription = description
    , dbCommandPlan =
        SQLDBCommand
          { dbCommandStatement = statement
          , dbCommandParameters = parameters
          , dbCommandMode = SQLCommandExecute
          , dbCommandDecodeResult = decodeResult
          }
    }

sqlCommandReturning
  :: String
  -> SQLStatement
  -> [SQLParameter]
  -> (DBCommandResult -> Either ApiError a)
  -> DBCommand a
sqlCommandReturning description statement parameters decodeResult =
  DBCommand
    { dbCommandDescription = description
    , dbCommandPlan =
        SQLDBCommand
          { dbCommandStatement = statement
          , dbCommandParameters = parameters
          , dbCommandMode = SQLCommandReturningRows
          , dbCommandDecodeResult = decodeResult
          }
    }

dbCommandFromDelta :: DeltaCommand delta result -> delta -> DBCommand result
dbCommandFromDelta deltaCommand delta =
  DBCommand
    { dbCommandDescription = deltaCommandDescription deltaCommand delta
    , dbCommandPlan =
        SQLDBCommand
          { dbCommandStatement = deltaCommandStatement deltaCommand delta
          , dbCommandParameters = deltaCommandParameters deltaCommand delta
          , dbCommandMode = deltaCommandMode deltaCommand
          , dbCommandDecodeResult = deltaCommandDecodeResult deltaCommand delta
          }
    }

singleSQLRow :: SQLRows -> Either ApiError SQLRow
singleSQLRow (SQLRows rows) =
  case rows of
    [row] ->
      Right row
    [] ->
      Left (sqlDecodeError "expected exactly one SQL row, got none")
    _ ->
      Left (sqlDecodeError ("expected exactly one SQL row, got " <> show (length rows)))

sqlColumn :: String -> SQLRow -> Either ApiError SQLValue
sqlColumn columnName (SQLRow columns) =
  case lookup columnName columns of
    Just value ->
      Right value
    Nothing ->
      Left (sqlDecodeError ("missing SQL column: " <> columnName))

sqlColumnText :: String -> SQLRow -> Either ApiError String
sqlColumnText columnName row = do
  value <- sqlColumn columnName row
  case value of
    SQLTextValue text ->
      Right text
    _ ->
      Left (sqlColumnTypeError columnName "text" value)

sqlColumnInteger :: String -> SQLRow -> Either ApiError Integer
sqlColumnInteger columnName row = do
  value <- sqlColumn columnName row
  case value of
    SQLIntegerValue integer ->
      Right integer
    _ ->
      Left (sqlColumnTypeError columnName "integer" value)

sqlColumnDouble :: String -> SQLRow -> Either ApiError Double
sqlColumnDouble columnName row = do
  value <- sqlColumn columnName row
  case value of
    SQLDoubleValue double ->
      Right double
    SQLIntegerValue integer ->
      Right (fromInteger integer)
    _ ->
      Left (sqlColumnTypeError columnName "double" value)

sqlColumnBool :: String -> SQLRow -> Either ApiError Bool
sqlColumnBool columnName row = do
  value <- sqlColumn columnName row
  case value of
    SQLBoolValue bool ->
      Right bool
    _ ->
      Left (sqlColumnTypeError columnName "bool" value)

dbQueryComparable :: DBQuery a -> (String, DBQueryPlanComparable)
dbQueryComparable DBQuery {dbQueryDescription = description, dbQueryPlan = plan} =
  (description, dbQueryPlanComparable plan)

data DBQueryPlanComparable = DBQueryPlanComparable
  { dbQueryPlanKind :: String
  , dbQueryPlanStatement :: Maybe SQLStatement
  , dbQueryPlanParameters :: [SQLParameter]
  }
  deriving (Eq, Ord, Show)

dbQueryPlanComparable :: DBQueryPlan a -> DBQueryPlanComparable
dbQueryPlanComparable plan =
  case plan of
    DescribedDBQuery ->
      DBQueryPlanComparable
        { dbQueryPlanKind = "described"
        , dbQueryPlanStatement = Nothing
        , dbQueryPlanParameters = []
        }
    SQLDBQuery
      { dbQueryStatement = statement
      , dbQueryParameters = parameters
      } ->
        DBQueryPlanComparable
          { dbQueryPlanKind = "sql"
          , dbQueryPlanStatement = Just statement
          , dbQueryPlanParameters = parameters
          }

dbCommandComparable :: DBCommand a -> (String, DBCommandPlanComparable)
dbCommandComparable DBCommand {dbCommandDescription = description, dbCommandPlan = plan} =
  (description, dbCommandPlanComparable plan)

data DBCommandPlanComparable = DBCommandPlanComparable
  { dbCommandPlanKind :: String
  , dbCommandPlanStatement :: Maybe SQLStatement
  , dbCommandPlanParameters :: [SQLParameter]
  , dbCommandPlanMode :: Maybe SQLCommandMode
  }
  deriving (Eq, Ord, Show)

dbCommandPlanComparable :: DBCommandPlan a -> DBCommandPlanComparable
dbCommandPlanComparable plan =
  case plan of
    DescribedDBCommand ->
      DBCommandPlanComparable
        { dbCommandPlanKind = "described"
        , dbCommandPlanStatement = Nothing
        , dbCommandPlanParameters = []
        , dbCommandPlanMode = Nothing
        }
    SQLDBCommand
      { dbCommandStatement = statement
      , dbCommandParameters = parameters
      , dbCommandMode = mode
      } ->
        DBCommandPlanComparable
          { dbCommandPlanKind = "sql"
          , dbCommandPlanStatement = Just statement
          , dbCommandPlanParameters = parameters
          , dbCommandPlanMode = Just mode
          }

sqlColumnTypeError :: String -> String -> SQLValue -> ApiError
sqlColumnTypeError columnName expectedType actualValue =
  sqlDecodeError
    ( "SQL column "
        <> columnName
        <> " expected "
        <> expectedType
        <> ", got "
        <> sqlValueKind actualValue
    )

sqlDecodeError :: String -> ApiError
sqlDecodeError message =
  ApiError
    { apiErrorKind = ApiUnexpectedInterpreterFailure
    , apiErrorMessage = message
    }

sqlValueKind :: SQLValue -> String
sqlValueKind value =
  case value of
    SQLNullValue ->
      "null"
    SQLTextValue _ ->
      "text"
    SQLIntegerValue _ ->
      "integer"
    SQLDoubleValue _ ->
      "double"
    SQLBoolValue _ ->
      "bool"
    SQLJSONValue _ ->
      "json"

-- | A safe zero-delta transition exposed without write authority.
data Observation input context domainError output = Observation
  { name :: EndpointName
  , decode :: RawRequest -> Either ApiError input
  , buildQuery :: input -> DBQuery context
  , observe :: context -> input -> Either domainError output
  , encode :: output -> Either ApiError RawResponse
  }

-- | A transition that decides a typed delta and interprets it as a command.
data Transition input context domainError delta result output = Transition
  { name :: EndpointName
  , decode :: RawRequest -> Either ApiError input
  , buildQuery :: input -> DBQuery context
  , decide :: context -> input -> Either domainError delta
  , buildCommand :: delta -> DBCommand result
  , respond :: context -> result -> Either ApiError output
  , encode :: output -> Either ApiError RawResponse
  }

executeObservation
  :: Monad m
  => DomainErrorBoundary domainError
  -> (DBQuery context -> m (Either ApiError context))
  -> Observation input context domainError output
  -> RawRequest
  -> m (Either ApiError RawResponse)
executeObservation
  mapDomainError
  runQuery
  Observation
    { decode = decodeRequest
    , buildQuery = buildContextQuery
    , observe = observeDomain
    , encode = encodeResponse
    }
  rawRequest =
    case decodeRequest rawRequest of
      Left apiError ->
        pure (Left apiError)
      Right input -> do
        contextResult <- runQuery (buildContextQuery input)
        case contextResult of
          Left apiError ->
            pure (Left apiError)
          Right context ->
            pure
              ( case observeDomain context input of
                  Left domainError ->
                    Left (mapDomainError domainError)
                  Right output ->
                    encodeResponse output
              )

executeTransition
  :: Monad m
  => DomainErrorBoundary domainError
  -> (DBQuery context -> m (Either ApiError context))
  -> (DBCommand result -> m (Either ApiError result))
  -> Transition input context domainError delta result output
  -> RawRequest
  -> m (Either ApiError RawResponse)
executeTransition
  mapDomainError
  runQuery
  runCommand
  Transition
    { decode = decodeRequest
    , buildQuery = buildContextQuery
    , decide = decideDomain
    , buildCommand = buildDeltaCommand
    , respond = respondWithResult
    , encode = encodeResponse
    }
  rawRequest =
    case decodeRequest rawRequest of
      Left apiError ->
        pure (Left apiError)
      Right input -> do
        contextResult <- runQuery (buildContextQuery input)
        case contextResult of
          Left apiError ->
            pure (Left apiError)
          Right context ->
            case decideDomain context input of
              Left domainError ->
                pure (Left (mapDomainError domainError))
              Right delta -> do
                commandResult <- runCommand (buildDeltaCommand delta)
                case commandResult of
                  Left apiError ->
                    pure (Left apiError)
                  Right result ->
                    pure
                      ( case respondWithResult context result of
                          Left apiError ->
                            Left apiError
                          Right output ->
                            encodeResponse output
                      )

coreBoundary :: String
coreBoundary = "arm-core"
