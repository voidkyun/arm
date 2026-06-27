{-# LANGUAGE DuplicateRecordFields #-}

module Arm.Core
  ( EndpointName (..)
  , RawRequest (..)
  , RawResponse (..)
  , ApiErrorKind (..)
  , ApiError (..)
  , DomainErrorKind (..)
  , DomainError (..)
  , DBQuery (..)
  , DBCommand (..)
  , Observation (..)
  , Transition (..)
  , domainErrorToApiError
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

data DomainErrorKind
  = DomainValidationError
  | DomainAuthorizationError
  | DomainNotFoundError
  | DomainConflictError
  | DomainInvariantViolation
  deriving (Eq, Ord, Show)

data DomainError = DomainError
  { domainErrorKind :: DomainErrorKind
  , domainErrorMessage :: String
  }
  deriving (Eq, Ord, Show)

newtype DBQuery a = DBQuery
  { dbQueryDescription :: String
  }
  deriving (Eq, Ord, Show)

newtype DBCommand a = DBCommand
  { dbCommandDescription :: String
  }
  deriving (Eq, Ord, Show)

data Observation input context output = Observation
  { name :: EndpointName
  , decode :: RawRequest -> Either ApiError input
  , buildQuery :: input -> DBQuery context
  , observe :: context -> input -> Either DomainError output
  , encode :: output -> Either ApiError RawResponse
  }

data Transition input context decision result output = Transition
  { name :: EndpointName
  , decode :: RawRequest -> Either ApiError input
  , buildQuery :: input -> DBQuery context
  , decide :: context -> input -> Either DomainError decision
  , buildCommand :: decision -> DBCommand result
  , respond :: context -> result -> Either ApiError output
  , encode :: output -> Either ApiError RawResponse
  }

domainErrorToApiError :: DomainError -> ApiError
domainErrorToApiError DomainError {domainErrorKind, domainErrorMessage} =
  ApiError
    { apiErrorKind = domainErrorKindToApiErrorKind domainErrorKind
    , apiErrorMessage = domainErrorMessage
    }

executeObservation
  :: Monad m
  => (DBQuery context -> m (Either ApiError context))
  -> Observation input context output
  -> RawRequest
  -> m (Either ApiError RawResponse)
executeObservation
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
                    Left (domainErrorToApiError domainError)
                  Right output ->
                    encodeResponse output
              )

executeTransition
  :: Monad m
  => (DBQuery context -> m (Either ApiError context))
  -> (DBCommand result -> m (Either ApiError result))
  -> Transition input context decision result output
  -> RawRequest
  -> m (Either ApiError RawResponse)
executeTransition
  runQuery
  runCommand
  Transition
    { decode = decodeRequest
    , buildQuery = buildContextQuery
    , decide = decideDomain
    , buildCommand = buildDecisionCommand
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
                pure (Left (domainErrorToApiError domainError))
              Right decision -> do
                commandResult <- runCommand (buildDecisionCommand decision)
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

domainErrorKindToApiErrorKind :: DomainErrorKind -> ApiErrorKind
domainErrorKindToApiErrorKind domainErrorKind =
  case domainErrorKind of
    DomainValidationError ->
      ApiValidationError
    DomainAuthorizationError ->
      ApiAuthorizationError
    DomainNotFoundError ->
      ApiNotFoundError
    DomainConflictError ->
      ApiConflictError
    DomainInvariantViolation ->
      ApiInvariantViolation
