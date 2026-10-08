{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Main
  ( main
  ) where

import Arm.Core
  ( ApiError (..)
  , ApiErrorKind (..)
  , DBCommand (..)
  , DBQuery (..)
  , DomainErrorBoundary
  , EndpointName (..)
  , Observation (..)
  , RawRequest (..)
  , RawResponse (..)
  , Transition (..)
  , describeDBCommand
  , describeDBQuery
  )
import Arm.Wai
  ( armApplication
  , observationRoute
  , transitionRoute
  , waiBoundary
  )
import qualified Data.ByteString as ByteString
import Data.ByteString.Builder
  ( toLazyByteString
  )
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString.Char8
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Network.HTTP.Types
  ( Method
  , Status
  , methodGet
  , methodPost
  , status200
  , status404
  , status405
  , status409
  )
import Network.Wai
  ( Application
  , Request
  , defaultRequest
  , rawPathInfo
  , requestMethod
  , setRequestBodyChunks
  )
import Network.Wai.Internal
  ( Response (..)
  , ResponseReceived (..)
  )
import Test.Tasty
  ( TestTree
  , defaultMain
  , testGroup
  )
import Test.Tasty.HUnit
  ( Assertion
  , assertEqual
  , assertFailure
  , testCase
  )

data TaskDomainError
  = DuplicateTask String
  deriving (Eq, Show)

data CapturedResponse = CapturedResponse
  { capturedStatus :: Status
  , capturedBody :: LazyByteString.ByteString
  }
  deriving (Eq, Show)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Arm.Wai"
    [ testCase "WAI boundary names the adapter package" testWaiBoundary
    , testCase "GET routes a named observation without command authority" testObservationRoute
    , testCase "POST routes a named transition through command authority" testTransitionRoute
    , testCase "Unknown operation names return 404" testUnknownRoute
    , testCase "Known operation names with the wrong method return 405" testWrongMethod
    , testCase "API errors are converted to HTTP statuses" testApiErrorStatus
    ]

testWaiBoundary :: Assertion
testWaiBoundary =
  assertEqual "boundary" "arm-core/arm-wai" waiBoundary

testObservationRoute :: Assertion
testObservationRoute = do
  queryCount <- newIORef (0 :: Int)
  commandCount <- newIORef (0 :: Int)
  let application =
        armApplication
          [ observationRoute taskDomainErrorToApiError (countingQuery queryCount) openTasksObservation
          , transitionRoute
              taskDomainErrorToApiError
              (countingQuery queryCount)
              (countingCommand commandCount)
              createTaskTransition
          ]

  response <- runApplication application methodGet "/open-tasks" "project-a"

  assertEqual "status" status200 (capturedStatus response)
  assertEqual
    "body"
    "open-tasks:project-a:context:project-a"
    (LazyByteString.Char8.unpack (capturedBody response))
  assertEqual "queries" 1 =<< readIORef queryCount
  assertEqual "commands" 0 =<< readIORef commandCount

testTransitionRoute :: Assertion
testTransitionRoute = do
  queryCount <- newIORef (0 :: Int)
  commandCount <- newIORef (0 :: Int)
  let application =
        armApplication
          [ observationRoute taskDomainErrorToApiError (countingQuery queryCount) openTasksObservation
          , transitionRoute
              taskDomainErrorToApiError
              (countingQuery queryCount)
              (countingCommand commandCount)
              createTaskTransition
          ]

  response <- runApplication application methodPost "/create-task" "write docs"

  assertEqual "status" status200 (capturedStatus response)
  assertEqual
    "body"
    "create-task:write docs:context:create-task:write docs:context:write docs:delta:command:result"
    (LazyByteString.Char8.unpack (capturedBody response))
  assertEqual "queries" 1 =<< readIORef queryCount
  assertEqual "commands" 1 =<< readIORef commandCount

testUnknownRoute :: Assertion
testUnknownRoute = do
  response <- runApplication sampleApplication methodGet "/tasks" ""

  assertEqual "status" status404 (capturedStatus response)

testWrongMethod :: Assertion
testWrongMethod = do
  response <- runApplication sampleApplication methodGet "/create-task" ""

  assertEqual "status" status405 (capturedStatus response)

testApiErrorStatus :: Assertion
testApiErrorStatus = do
  response <- runApplication sampleApplication methodPost "/create-task" "duplicate"

  assertEqual "status" status409 (capturedStatus response)
  assertEqual
    "body"
    "duplicate task"
    (LazyByteString.Char8.unpack (capturedBody response))

sampleApplication :: Application
sampleApplication =
  armApplication
    [ observationRoute taskDomainErrorToApiError successfulQuery openTasksObservation
    , transitionRoute taskDomainErrorToApiError successfulQuery successfulCommand createTaskTransition
    ]

openTasksObservation :: Observation String String TaskDomainError String
openTasksObservation =
  Observation
    { name = EndpointName "open-tasks"
    , decode = \(RawRequest rawBody) -> Right rawBody
    , buildQuery = \input -> describeDBQuery ("open-tasks:" <> input)
    , observe = \context input -> Right (context <> ":" <> input)
    , encode = \output -> Right (RawResponse output)
    }

createTaskTransition :: Transition String String TaskDomainError String String String
createTaskTransition =
  Transition
    { name = EndpointName "create-task"
    , decode = \(RawRequest rawBody) -> Right rawBody
    , buildQuery = \input -> describeDBQuery ("create-task:" <> input)
    , decide = \context input ->
        if input == "duplicate"
          then Left (DuplicateTask input)
          else Right (context <> ":" <> input <> ":delta")
    , buildCommand = \delta -> describeDBCommand (delta <> ":command")
    , respond = \context result -> Right (context <> ":" <> result)
    , encode = \output -> Right (RawResponse output)
    }

countingQuery :: IORef Int -> DBQuery String -> IO (Either ApiError String)
countingQuery count query = do
  modifyIORef' count (+ 1)
  successfulQuery query

countingCommand :: IORef Int -> DBCommand String -> IO (Either ApiError String)
countingCommand count command = do
  modifyIORef' count (+ 1)
  successfulCommand command

successfulQuery :: DBQuery String -> IO (Either ApiError String)
successfulQuery query =
  pure (Right (dbQueryDescription query <> ":context"))

successfulCommand :: DBCommand String -> IO (Either ApiError String)
successfulCommand command =
  pure (Right (dbCommandDescription command <> ":result"))

taskDomainErrorToApiError :: DomainErrorBoundary TaskDomainError
taskDomainErrorToApiError domainError =
  case domainError of
    DuplicateTask _ ->
      ApiError ApiConflictError "duplicate task"

runApplication
  :: Application
  -> Method
  -> ByteString.ByteString
  -> LazyByteString.ByteString
  -> IO CapturedResponse
runApplication application method path body = do
  request <- requestWithBody method path body
  responseRef <- newIORef Nothing
  _ <-
    application request $ \response -> do
      captured <- captureResponse response
      writeIORef responseRef (Just captured)
      pure ResponseReceived
  responseMaybe <- readIORef responseRef
  case responseMaybe of
    Just response ->
      pure response
    Nothing ->
      assertFailure "application did not send a response"

requestWithBody
  :: Method
  -> ByteString.ByteString
  -> LazyByteString.ByteString
  -> IO Request
requestWithBody method path body = do
  bodyChunks <- newIORef [LazyByteString.toStrict body]
  pure
    ( setRequestBodyChunks
        (nextRequestBodyChunk bodyChunks)
        defaultRequest
          { requestMethod = method
          , rawPathInfo = path
          }
    )

nextRequestBodyChunk :: IORef [ByteString.ByteString] -> IO ByteString.ByteString
nextRequestBodyChunk bodyChunks =
  atomicModifyIORef'
    bodyChunks
    ( \chunks ->
        case chunks of
          [] ->
            ([], ByteString.empty)
          chunk : rest ->
            (rest, chunk)
    )

captureResponse :: Response -> IO CapturedResponse
captureResponse response =
  case response of
    ResponseBuilder status _ body ->
      pure (CapturedResponse status (toLazyByteString body))
    ResponseStream status _ body -> do
      chunksRef <- newIORef []
      body
        ( \chunk ->
            modifyIORef' chunksRef (<> [toLazyByteString chunk])
        )
        (pure ())
      chunks <- readIORef chunksRef
      pure (CapturedResponse status (mconcat chunks))
    ResponseFile status _ _ _ ->
      pure (CapturedResponse status "")
    ResponseRaw _ fallback ->
      captureResponse fallback
