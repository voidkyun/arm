{-# LANGUAGE DuplicateRecordFields #-}

module Arm.Core
  ( EndpointName (..)
  , RawRequest (..)
  , RawResponse (..)
  , ApiError (..)
  , DomainError (..)
  , DBQuery (..)
  , DBCommand (..)
  , Observation (..)
  , Transition (..)
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

newtype ApiError = ApiError
  { apiErrorMessage :: String
  }
  deriving (Eq, Ord, Show)

newtype DomainError = DomainError
  { domainErrorMessage :: String
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
  , encode :: output -> RawResponse
  }

data Transition input context decision result output = Transition
  { name :: EndpointName
  , decode :: RawRequest -> Either ApiError input
  , buildQuery :: input -> DBQuery context
  , decide :: context -> input -> Either DomainError decision
  , buildCommand :: decision -> DBCommand result
  , respond :: context -> result -> Either ApiError output
  , encode :: output -> RawResponse
  }

coreBoundary :: String
coreBoundary = "arm-core"
