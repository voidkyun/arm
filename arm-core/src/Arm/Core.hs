{-# LANGUAGE DuplicateRecordFields #-}

module Arm.Core
  ( EndpointName (..)
  , RawRequest (..)
  , RawResponse (..)
  , ApiErrorKind (..)
  , ApiError (..)
  , DomainErrorBoundary
  , ZeroDelta (..)
  , DBQuery (..)
  , DBCommand (..)
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

newtype DBQuery a = DBQuery
  { dbQueryDescription :: String
  }
  deriving (Eq, Ord, Show)

newtype DBCommand a = DBCommand
  { dbCommandDescription :: String
  }
  deriving (Eq, Ord, Show)

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
