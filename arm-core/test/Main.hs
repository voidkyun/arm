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
import Test.Tasty
  ( TestTree
  , defaultMain
  , testGroup
  )
import Test.Tasty.QuickCheck
  ( Arbitrary (..)
  , Gen
  , NonNegative (..)
  , Property
  , choose
  , counterexample
  , listOf1
  , testProperty
  , (===)
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

newtype NonEmptyText = NonEmptyText String
  deriving (Eq, Show)

instance Arbitrary NonEmptyText where
  arbitrary = NonEmptyText <$> listOf1 safeChar

newtype NonEmptyTexts = NonEmptyTexts [String]
  deriving (Eq, Show)

instance Arbitrary NonEmptyTexts where
  arbitrary = NonEmptyTexts <$> listOf1 (listOf1 safeChar)

data ObservationFailure
  = ObservationApiFailure ApiError
  | ObservationDomainFailure DomainError
  deriving (Eq, Show)

data TransitionFailure
  = TransitionApiFailure ApiError
  | TransitionDomainFailure DomainError
  deriving (Eq, Show)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Arm.Core"
    [ testGroup
        "Observation"
        [ testProperty "exposes a semantic endpoint name" propObservationName
        , testProperty "maps decoded input to a context query" propObservationQuery
        , testProperty "maps request and context to a raw response" propObservationPipeline
        , testProperty "keeps API decode failures distinct" propObservationApiFailure
        , testProperty "keeps domain observation failures distinct" propObservationDomainFailure
        ]
    , testGroup
        "Transition"
        [ testProperty "exposes a semantic endpoint name" propTransitionName
        , testProperty "maps decoded input to a context query" propTransitionQuery
        , testProperty "maps decisions to database commands" propTransitionCommand
        , testProperty "maps request, context, and command result to a raw response" propTransitionPipeline
        , testProperty "keeps API decode failures distinct" propTransitionApiFailure
        , testProperty "keeps domain decision failures distinct" propTransitionDomainFailure
        ]
    ]

propObservationName :: Property
propObservationName =
  observationName observationEndpoint === EndpointName "open-tasks"

propObservationQuery :: NonEmptyText -> Property
propObservationQuery (NonEmptyText projectName) =
  case observationDecode observationEndpoint (RawRequest projectName) of
    Left err ->
      counterexample ("unexpected decode failure: " ++ show err) False
    Right input ->
      observationBuildQuery observationEndpoint input
        === DBQuery ("load context for " ++ projectName)

propObservationPipeline :: NonEmptyText -> NonEmptyTexts -> Property
propObservationPipeline (NonEmptyText projectName) (NonEmptyTexts tasks) =
  runObservationPure
    observationEndpoint
    (TestContext tasks)
    (RawRequest projectName)
    === Right (RawResponse (projectName ++ ": " ++ joinWith "," tasks))

propObservationApiFailure :: NonEmptyTexts -> Property
propObservationApiFailure (NonEmptyTexts tasks) =
  runObservationPure observationEndpoint (TestContext tasks) (RawRequest "")
    === Left (ObservationApiFailure (ApiError "empty request"))

propObservationDomainFailure :: NonEmptyText -> Property
propObservationDomainFailure (NonEmptyText projectName) =
  runObservationPure observationEndpoint (TestContext []) (RawRequest projectName)
    === Left (ObservationDomainFailure (DomainError "no tasks"))

propTransitionName :: Property
propTransitionName =
  transitionName transitionEndpoint === EndpointName "close-task"

propTransitionQuery :: NonEmptyText -> Property
propTransitionQuery (NonEmptyText taskName) =
  case transitionDecode transitionEndpoint (RawRequest taskName) of
    Left err ->
      counterexample ("unexpected decode failure: " ++ show err) False
    Right input ->
      transitionBuildQuery transitionEndpoint input
        === DBQuery ("load context for " ++ taskName)

propTransitionCommand :: NonEmptyText -> Property
propTransitionCommand (NonEmptyText taskName) =
  case transitionDecide transitionEndpoint (TestContext ["open"]) (TestInput taskName) of
    Left err ->
      counterexample ("unexpected decision failure: " ++ show err) False
    Right decision ->
      transitionBuildCommand transitionEndpoint decision
        === DBCommand ("execute close " ++ taskName)

propTransitionPipeline :: NonEmptyText -> NonNegative Int -> Property
propTransitionPipeline (NonEmptyText taskName) (NonNegative rows) =
  runTransitionPure
    transitionEndpoint
    (TestContext ["open"])
    (TestResult rows)
    (RawRequest taskName)
    === Right
      ( DBCommand ("execute close " ++ taskName)
      , RawResponse ("closed " ++ show rows ++ " row with open")
      )

propTransitionApiFailure :: NonNegative Int -> Property
propTransitionApiFailure (NonNegative rows) =
  runTransitionPure transitionEndpoint (TestContext ["open"]) (TestResult rows) (RawRequest "")
    === Left (TransitionApiFailure (ApiError "empty request"))

propTransitionDomainFailure :: NonEmptyText -> NonNegative Int -> Property
propTransitionDomainFailure (NonEmptyText taskName) (NonNegative rows) =
  runTransitionPure transitionEndpoint (TestContext ["closed"]) (TestResult rows) (RawRequest taskName)
    === Left (TransitionDomainFailure (DomainError "task is not open"))

runObservationPure
  :: Observation input context output
  -> context
  -> RawRequest
  -> Either ObservationFailure RawResponse
runObservationPure endpoint context raw =
  case observationDecode endpoint raw of
    Left err ->
      Left (ObservationApiFailure err)
    Right input ->
      case observationObserve endpoint context input of
        Left err ->
          Left (ObservationDomainFailure err)
        Right output ->
          Right (observationEncode endpoint output)

runTransitionPure
  :: Transition input context decision result output
  -> context
  -> result
  -> RawRequest
  -> Either TransitionFailure (DBCommand result, RawResponse)
runTransitionPure endpoint context result raw =
  case transitionDecode endpoint raw of
    Left err ->
      Left (TransitionApiFailure err)
    Right input ->
      case transitionDecide endpoint context input of
        Left err ->
          Left (TransitionDomainFailure err)
        Right decision ->
          case transitionRespond endpoint context result of
            Left err ->
              Left (TransitionApiFailure err)
            Right output ->
              Right
                ( transitionBuildCommand endpoint decision
                , transitionEncode endpoint output
                )

observationEndpoint :: Observation TestInput TestContext TestOutput
observationEndpoint =
  Observation
    { name = EndpointName "open-tasks"
    , decode = decodeInput
    , buildQuery = buildContextQuery
    , observe = observeTasks
    , encode = encodeOutput
    }

transitionEndpoint :: Transition TestInput TestContext TestDecision TestResult TestOutput
transitionEndpoint =
  Transition
    { name = EndpointName "close-task"
    , decode = decodeInput
    , buildQuery = buildContextQuery
    , decide = decideCloseTask
    , buildCommand = buildCloseTaskCommand
    , respond = respondCloseTask
    , encode = encodeOutput
    }

observationName :: Observation input context output -> EndpointName
observationName Observation {name = endpointName} =
  endpointName

observationDecode :: Observation input context output -> RawRequest -> Either ApiError input
observationDecode Observation {decode = decodeEndpoint} =
  decodeEndpoint

observationBuildQuery :: Observation input context output -> input -> DBQuery context
observationBuildQuery Observation {buildQuery = buildEndpointQuery} =
  buildEndpointQuery

observationObserve :: Observation input context output -> context -> input -> Either DomainError output
observationObserve Observation {observe = observeEndpoint} =
  observeEndpoint

observationEncode :: Observation input context output -> output -> RawResponse
observationEncode Observation {encode = encodeEndpoint} =
  encodeEndpoint

transitionName :: Transition input context decision result output -> EndpointName
transitionName Transition {name = endpointName} =
  endpointName

transitionDecode :: Transition input context decision result output -> RawRequest -> Either ApiError input
transitionDecode Transition {decode = decodeEndpoint} =
  decodeEndpoint

transitionBuildQuery :: Transition input context decision result output -> input -> DBQuery context
transitionBuildQuery Transition {buildQuery = buildEndpointQuery} =
  buildEndpointQuery

transitionDecide :: Transition input context decision result output -> context -> input -> Either DomainError decision
transitionDecide Transition {decide = decideEndpoint} =
  decideEndpoint

transitionBuildCommand :: Transition input context decision result output -> decision -> DBCommand result
transitionBuildCommand Transition {buildCommand = buildEndpointCommand} =
  buildEndpointCommand

transitionRespond :: Transition input context decision result output -> context -> result -> Either ApiError output
transitionRespond Transition {respond = respondEndpoint} =
  respondEndpoint

transitionEncode :: Transition input context decision result output -> output -> RawResponse
transitionEncode Transition {encode = encodeEndpoint} =
  encodeEndpoint

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

safeChar :: Gen Char
safeChar =
  choose ('a', 'z')

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [value] = value
joinWith separator (value : values) =
  value ++ separator ++ joinWith separator values
