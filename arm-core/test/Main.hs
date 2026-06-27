{-# LANGUAGE DuplicateRecordFields #-}

module Main
  ( main
  ) where

import Arm.Core
  ( ApiError (..)
  , DBCommand (..)
  , DBQuery (..)
  , DomainError (..)
  , EndpointName (..)
  , Observation (..)
  , RawRequest (..)
  , RawResponse (..)
  , Transition (..)
  )

newtype TestInput = TestInput String
  deriving (Eq, Show)

newtype TestContext = TestContext [String]
  deriving (Eq, Show)

newtype TestDecision = TestDecision String
  deriving (Eq, Show)

newtype TestResult = TestResult Int
  deriving (Eq, Show)

newtype TestOutput = TestOutput String
  deriving (Eq, Show)

main :: IO ()
main = do
  testObservation
  testTransition
  putStrLn "arm-core-test passed"

testObservation :: IO ()
testObservation = do
  let endpoint =
        Observation
          { name = EndpointName "open-tasks"
          , decode = decodeInput
          , buildQuery = buildContextQuery
          , observe = observeTasks
          , encode = encodeOutput
          }

  case endpoint of
    Observation
      { name = endpointName
      , decode = decodeEndpoint
      , buildQuery = buildEndpointQuery
      , observe = observeEndpoint
      , encode = encodeEndpoint
      } -> do
        assertEqual "observation name" (EndpointName "open-tasks") endpointName
        assertEqual "observation decode" (Right (TestInput "project-1")) (decodeEndpoint (RawRequest "project-1"))
        assertEqual "observation query" (DBQuery "load context for project-1") (buildEndpointQuery (TestInput "project-1"))
        assertEqual
          "observation pure logic"
          (Right (TestOutput "project-1: task-a,task-b"))
          (observeEndpoint (TestContext ["task-a", "task-b"]) (TestInput "project-1"))
        assertEqual "observation encode" (RawResponse "ok") (encodeEndpoint (TestOutput "ok"))

testTransition :: IO ()
testTransition = do
  let endpoint =
        Transition
          { name = EndpointName "close-task"
          , decode = decodeInput
          , buildQuery = buildContextQuery
          , decide = decideCloseTask
          , buildCommand = buildCloseTaskCommand
          , respond = respondCloseTask
          , encode = encodeOutput
          }

  case endpoint of
    Transition
      { name = endpointName
      , decode = decodeEndpoint
      , buildQuery = buildEndpointQuery
      , decide = decideEndpoint
      , buildCommand = buildEndpointCommand
      , respond = respondEndpoint
      , encode = encodeEndpoint
      } -> do
        assertEqual "transition name" (EndpointName "close-task") endpointName
        assertEqual "transition decode" (Right (TestInput "task-1")) (decodeEndpoint (RawRequest "task-1"))
        assertEqual "transition query" (DBQuery "load context for task-1") (buildEndpointQuery (TestInput "task-1"))
        assertEqual
          "transition pure decision"
          (Right (TestDecision "close task-1"))
          (decideEndpoint (TestContext ["open"]) (TestInput "task-1"))
        assertEqual
          "transition command"
          (DBCommand "execute close task-1")
          (buildEndpointCommand (TestDecision "close task-1"))
        assertEqual
          "transition respond"
          (Right (TestOutput "closed 1 row with open"))
          (respondEndpoint (TestContext ["open"]) (TestResult 1))
        assertEqual "transition encode" (RawResponse "closed") (encodeEndpoint (TestOutput "closed"))

decodeInput :: RawRequest -> Either ApiError TestInput
decodeInput (RawRequest body)
  | null body = Left (ApiError "empty request")
  | otherwise = Right (TestInput body)

buildContextQuery :: TestInput -> DBQuery TestContext
buildContextQuery (TestInput inputName) =
  DBQuery ("load context for " ++ inputName)

observeTasks :: TestContext -> TestInput -> Either DomainError TestOutput
observeTasks (TestContext tasks) (TestInput projectName)
  | null tasks = Left (DomainError "no tasks")
  | otherwise = Right (TestOutput (projectName ++ ": " ++ joinWith "," tasks))

decideCloseTask :: TestContext -> TestInput -> Either DomainError TestDecision
decideCloseTask (TestContext states) (TestInput taskName)
  | "open" `elem` states = Right (TestDecision ("close " ++ taskName))
  | otherwise = Left (DomainError "task is not open")

buildCloseTaskCommand :: TestDecision -> DBCommand TestResult
buildCloseTaskCommand (TestDecision decision) =
  DBCommand ("execute " ++ decision)

respondCloseTask :: TestContext -> TestResult -> Either ApiError TestOutput
respondCloseTask (TestContext states) (TestResult rows) =
  Right (TestOutput ("closed " ++ show rows ++ " row with " ++ joinWith "," states))

encodeOutput :: TestOutput -> RawResponse
encodeOutput (TestOutput output) =
  RawResponse output

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise =
      error
        ( label
            ++ "\nexpected: "
            ++ show expected
            ++ "\nactual:   "
            ++ show actual
        )

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [value] = value
joinWith separator (value : values) =
  value ++ separator ++ joinWith separator values
