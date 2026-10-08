{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Arm.Wai
  ( WaiRoute
  , armApplication
  , observationRoute
  , observationRouteWith
  , transitionRoute
  , transitionRouteWith
  , apiErrorStatus
  , waiBoundary
  ) where

import Arm.Core
  ( ApiError (..)
  , ApiErrorKind (..)
  , DBCommand
  , DBQuery
  , DomainErrorBoundary
  , EndpointName (..)
  , Observation (..)
  , RawRequest (..)
  , RawResponse (..)
  , Transition (..)
  , coreBoundary
  , executeObservation
  , executeTransition
  )
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import qualified Data.ByteString.Lazy.Char8 as LazyByteString.Char8
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.List
  ( find
  )
import Network.HTTP.Types
  ( Method
  , Status
  , hContentType
  , methodGet
  , methodPost
  , status200
  , status400
  , status403
  , status404
  , status405
  , status409
  , status500
  )
import Network.Wai
  ( Application
  , Request
  , Response
  , rawPathInfo
  , requestMethod
  , responseLBS
  , strictRequestBody
  )

data WaiRoute = WaiRoute
  { routeMethod :: Method
  , routeName :: EndpointName
  , routeApplication :: Application
  }

armApplication :: [WaiRoute] -> Application
armApplication routes request respond =
  case find (matchesRequest request) routes of
    Just route ->
      routeApplication route request respond
    Nothing
      | any (matchesPath request) routes ->
          respond methodNotAllowedResponse
      | otherwise ->
          respond notFoundResponse

observationRoute
  :: DomainErrorBoundary domainError
  -> (DBQuery context -> IO (Either ApiError context))
  -> Observation input context domainError output
  -> WaiRoute
observationRoute mapDomainError runQuery observation =
  observationRouteWith waiRawRequest apiResultResponse mapDomainError runQuery observation

-- | Application-owned request and response codecs, without domain or JSON
-- dependencies in the adapter. No command interpreter is accepted.
observationRouteWith
  :: (Request -> IO (Either ApiError RawRequest))
  -> (Either ApiError RawResponse -> Response)
  -> DomainErrorBoundary domainError
  -> (DBQuery context -> IO (Either ApiError context))
  -> Observation input context domainError output
  -> WaiRoute
observationRouteWith readRequest renderResult mapDomainError runQuery observation@Observation {name = endpointName} =
  WaiRoute
    { routeMethod = methodGet
    , routeName = endpointName
    , routeApplication = \request respond -> do
        rawRequest <- readRequest request
        result <- either (pure . Left) (executeObservation mapDomainError runQuery observation) rawRequest
        respond (renderResult result)
    }

transitionRoute
  :: DomainErrorBoundary domainError
  -> (DBQuery context -> IO (Either ApiError context))
  -> (DBCommand result -> IO (Either ApiError result))
  -> Transition input context domainError delta result output
  -> WaiRoute
transitionRoute mapDomainError runQuery runCommand transition =
  transitionRouteWith waiRawRequest apiResultResponse mapDomainError runQuery runCommand transition

transitionRouteWith
  :: (Request -> IO (Either ApiError RawRequest))
  -> (Either ApiError RawResponse -> Response)
  -> DomainErrorBoundary domainError
  -> (DBQuery context -> IO (Either ApiError context))
  -> (DBCommand result -> IO (Either ApiError result))
  -> Transition input context domainError delta result output
  -> WaiRoute
transitionRouteWith readRequest renderResult mapDomainError runQuery runCommand transition@Transition {name = endpointName} =
  WaiRoute
    { routeMethod = methodPost
    , routeName = endpointName
    , routeApplication = \request respond -> do
        rawRequest <- readRequest request
        result <- either (pure . Left) (executeTransition mapDomainError runQuery runCommand transition) rawRequest
        respond (renderResult result)
    }

waiBoundary :: String
waiBoundary = coreBoundary ++ "/arm-wai"

matchesRequest :: Request -> WaiRoute -> Bool
matchesRequest request route =
  requestMethod request == routeMethod route
    && matchesPath request route

matchesPath :: Request -> WaiRoute -> Bool
matchesPath request route =
  rawPathInfo request == routePath (routeName route)

routePath :: EndpointName -> ByteString.ByteString
routePath (EndpointName endpointName) =
  ByteString.Char8.pack ('/' : dropWhile (== '/') endpointName)

waiRawRequest :: Request -> IO (Either ApiError RawRequest)
waiRawRequest request =
  do
    bytes <- strictRequestBody request
    pure $ case Text.decodeUtf8' (ByteString.concat (LazyByteString.Char8.toChunks bytes)) of
      Left _ -> Left (ApiError ApiParseError "request body must be UTF-8")
      Right body -> Right (RawRequest (Text.unpack body))

apiResultResponse :: Either ApiError RawResponse -> Response
apiResultResponse result =
  case result of
    Right (RawResponse body) ->
      textResponse status200 body
    Left apiError ->
      textResponse (apiErrorStatus apiError) (apiErrorMessage apiError)

apiErrorStatus :: ApiError -> Status
apiErrorStatus ApiError {apiErrorKind = kind} =
  case kind of
    ApiParseError ->
      status400
    ApiValidationError ->
      status400
    ApiAuthorizationError ->
      status403
    ApiNotFoundError ->
      status404
    ApiConflictError ->
      status409
    ApiInvariantViolation ->
      status500
    ApiUnexpectedInterpreterFailure ->
      status500

notFoundResponse :: Response
notFoundResponse =
  textResponse status404 "ARM endpoint not found"

methodNotAllowedResponse :: Response
methodNotAllowedResponse =
  textResponse status405 "ARM endpoint method not allowed"

textResponse :: Status -> String -> Response
textResponse status body =
  responseLBS
    status
    [(hContentType, "text/plain; charset=utf-8")]
    (LazyByteString.Char8.fromStrict (Text.encodeUtf8 (Text.pack body)))
