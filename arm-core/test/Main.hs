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
  , Property
  , choose
  , listOf1
  , testProperty
  , (===)
  )

newtype TestInput = TestInput Int
  deriving (Eq, Show)

newtype TestContext = TestContext Int
  deriving (Eq, Show)

newtype TestDecision = TestDecision Int
  deriving (Eq, Show)

newtype TestResult = TestResult Int
  deriving (Eq, Show)

newtype TestOutput = TestOutput Int
  deriving (Eq, Show)

newtype Label = Label String
  deriving (Eq, Show)

instance Arbitrary Label where
  arbitrary = Label <$> listOf1 safeChar

instance Arbitrary TestInput where
  arbitrary = TestInput <$> arbitrary

instance Arbitrary TestContext where
  arbitrary = TestContext <$> arbitrary

instance Arbitrary TestDecision where
  arbitrary = TestDecision <$> arbitrary

instance Arbitrary TestResult where
  arbitrary = TestResult <$> arbitrary

instance Arbitrary TestOutput where
  arbitrary = TestOutput <$> arbitrary

data ObservationSpec = ObservationSpec
  { observationSpecName :: EndpointName
  , observationSpecRaw :: RawRequest
  , observationSpecInput :: TestInput
  , observationSpecContext :: TestContext
  , observationSpecQuery :: DBQuery TestContext
  , observationSpecOutput :: TestOutput
  , observationSpecResponse :: RawResponse
  , observationSpecApiError :: ApiError
  , observationSpecDomainError :: DomainError
  }
  deriving (Eq, Show)

instance Arbitrary ObservationSpec where
  arbitrary =
    ObservationSpec
      <$> genEndpointName
      <*> genRawRequest
      <*> arbitrary
      <*> arbitrary
      <*> genDBQuery
      <*> arbitrary
      <*> genRawResponse
      <*> genApiError
      <*> genDomainError

data TransitionSpec = TransitionSpec
  { transitionSpecName :: EndpointName
  , transitionSpecRaw :: RawRequest
  , transitionSpecInput :: TestInput
  , transitionSpecContext :: TestContext
  , transitionSpecQuery :: DBQuery TestContext
  , transitionSpecDecision :: TestDecision
  , transitionSpecCommand :: DBCommand TestResult
  , transitionSpecResult :: TestResult
  , transitionSpecOutput :: TestOutput
  , transitionSpecResponse :: RawResponse
  , transitionSpecApiError :: ApiError
  , transitionSpecDomainError :: DomainError
  }
  deriving (Eq, Show)

instance Arbitrary TransitionSpec where
  arbitrary =
    TransitionSpec
      <$> genEndpointName
      <*> genRawRequest
      <*> arbitrary
      <*> arbitrary
      <*> genDBQuery
      <*> arbitrary
      <*> genDBCommand
      <*> arbitrary
      <*> arbitrary
      <*> genRawResponse
      <*> genApiError
      <*> genDomainError

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
        "Observation laws"
        [ testProperty "name is part of the endpoint description" propObservationName
        , testProperty "success preserves query and encoded output sentinels" propObservationSuccess
        , testProperty "decode failure is an API failure" propObservationDecodeFailure
        , testProperty "observe failure is a domain failure" propObservationDomainFailure
        ]
    , testGroup
        "Transition laws"
        [ testProperty "name is part of the endpoint description" propTransitionName
        , testProperty "success preserves query, command, and encoded output sentinels" propTransitionSuccess
        , testProperty "decode failure is an API failure" propTransitionDecodeFailure
        , testProperty "decide failure is a domain failure" propTransitionDomainFailure
        , testProperty "respond failure is an API failure" propTransitionRespondFailure
        ]
    ]

propObservationName :: ObservationSpec -> Property
propObservationName spec =
  observationName (successfulObservation spec) === observationSpecName spec

propObservationSuccess :: ObservationSpec -> Property
propObservationSuccess spec =
  runObservationPure
    (successfulObservation spec)
    (observationSpecContext spec)
    (observationSpecRaw spec)
    === Right
      ( observationSpecQuery spec
      , observationSpecResponse spec
      )

propObservationDecodeFailure :: ObservationSpec -> Property
propObservationDecodeFailure spec =
  runObservationPure
    (apiFailingObservation spec)
    (observationSpecContext spec)
    (observationSpecRaw spec)
    === Left (ObservationApiFailure (observationSpecApiError spec))

propObservationDomainFailure :: ObservationSpec -> Property
propObservationDomainFailure spec =
  runObservationPure
    (domainFailingObservation spec)
    (observationSpecContext spec)
    (observationSpecRaw spec)
    === Left (ObservationDomainFailure (observationSpecDomainError spec))

propTransitionName :: TransitionSpec -> Property
propTransitionName spec =
  transitionName (successfulTransition spec) === transitionSpecName spec

propTransitionSuccess :: TransitionSpec -> Property
propTransitionSuccess spec =
  runTransitionPure
    (successfulTransition spec)
    (transitionSpecContext spec)
    (transitionSpecResult spec)
    (transitionSpecRaw spec)
    === Right
      ( transitionSpecQuery spec
      , transitionSpecCommand spec
      , transitionSpecResponse spec
      )

propTransitionDecodeFailure :: TransitionSpec -> Property
propTransitionDecodeFailure spec =
  runTransitionPure
    (apiFailingTransition spec)
    (transitionSpecContext spec)
    (transitionSpecResult spec)
    (transitionSpecRaw spec)
    === Left (TransitionApiFailure (transitionSpecApiError spec))

propTransitionDomainFailure :: TransitionSpec -> Property
propTransitionDomainFailure spec =
  runTransitionPure
    (domainFailingTransition spec)
    (transitionSpecContext spec)
    (transitionSpecResult spec)
    (transitionSpecRaw spec)
    === Left (TransitionDomainFailure (transitionSpecDomainError spec))

propTransitionRespondFailure :: TransitionSpec -> Property
propTransitionRespondFailure spec =
  runTransitionPure
    (respondFailingTransition spec)
    (transitionSpecContext spec)
    (transitionSpecResult spec)
    (transitionSpecRaw spec)
    === Left (TransitionApiFailure (transitionSpecApiError spec))

runObservationPure
  :: Observation input context output
  -> context
  -> RawRequest
  -> Either ObservationFailure (DBQuery context, RawResponse)
runObservationPure endpoint context raw =
  case observationDecode endpoint raw of
    Left err ->
      Left (ObservationApiFailure err)
    Right input ->
      case observationObserve endpoint context input of
        Left err ->
          Left (ObservationDomainFailure err)
        Right output ->
          Right
            ( observationBuildQuery endpoint input
            , observationEncode endpoint output
            )

runTransitionPure
  :: Transition input context decision result output
  -> context
  -> result
  -> RawRequest
  -> Either TransitionFailure (DBQuery context, DBCommand result, RawResponse)
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
                ( transitionBuildQuery endpoint input
                , transitionBuildCommand endpoint decision
                , transitionEncode endpoint output
                )

successfulObservation :: ObservationSpec -> Observation TestInput TestContext TestOutput
successfulObservation spec =
  Observation
    { name = observationSpecName spec
    , decode = \raw ->
        if raw == observationSpecRaw spec
          then Right (observationSpecInput spec)
          else Left (observationSpecApiError spec)
    , buildQuery = \input ->
        if input == observationSpecInput spec
          then observationSpecQuery spec
          else unexpectedQuery
    , observe = \context input ->
        if context == observationSpecContext spec && input == observationSpecInput spec
          then Right (observationSpecOutput spec)
          else Left (observationSpecDomainError spec)
    , encode = \output ->
        if output == observationSpecOutput spec
          then observationSpecResponse spec
          else unexpectedResponse
    }

apiFailingObservation :: ObservationSpec -> Observation TestInput TestContext TestOutput
apiFailingObservation spec =
  Observation
    { name = observationSpecName spec
    , decode = const (Left (observationSpecApiError spec))
    , buildQuery = const unexpectedQuery
    , observe = \_ _ -> Left (observationSpecDomainError spec)
    , encode = const unexpectedResponse
    }

domainFailingObservation :: ObservationSpec -> Observation TestInput TestContext TestOutput
domainFailingObservation spec =
  Observation
    { name = observationSpecName spec
    , decode = const (Right (observationSpecInput spec))
    , buildQuery = const (observationSpecQuery spec)
    , observe = \_ _ -> Left (observationSpecDomainError spec)
    , encode = const unexpectedResponse
    }

successfulTransition :: TransitionSpec -> Transition TestInput TestContext TestDecision TestResult TestOutput
successfulTransition spec =
  Transition
    { name = transitionSpecName spec
    , decode = \raw ->
        if raw == transitionSpecRaw spec
          then Right (transitionSpecInput spec)
          else Left (transitionSpecApiError spec)
    , buildQuery = \input ->
        if input == transitionSpecInput spec
          then transitionSpecQuery spec
          else unexpectedQuery
    , decide = \context input ->
        if context == transitionSpecContext spec && input == transitionSpecInput spec
          then Right (transitionSpecDecision spec)
          else Left (transitionSpecDomainError spec)
    , buildCommand = \decision ->
        if decision == transitionSpecDecision spec
          then transitionSpecCommand spec
          else unexpectedCommand
    , respond = \context result ->
        if context == transitionSpecContext spec && result == transitionSpecResult spec
          then Right (transitionSpecOutput spec)
          else Left (transitionSpecApiError spec)
    , encode = \output ->
        if output == transitionSpecOutput spec
          then transitionSpecResponse spec
          else unexpectedResponse
    }

apiFailingTransition :: TransitionSpec -> Transition TestInput TestContext TestDecision TestResult TestOutput
apiFailingTransition spec =
  Transition
    { name = transitionSpecName spec
    , decode = const (Left (transitionSpecApiError spec))
    , buildQuery = const unexpectedQuery
    , decide = \_ _ -> Left (transitionSpecDomainError spec)
    , buildCommand = const unexpectedCommand
    , respond = \_ _ -> Left (transitionSpecApiError spec)
    , encode = const unexpectedResponse
    }

domainFailingTransition :: TransitionSpec -> Transition TestInput TestContext TestDecision TestResult TestOutput
domainFailingTransition spec =
  Transition
    { name = transitionSpecName spec
    , decode = const (Right (transitionSpecInput spec))
    , buildQuery = const (transitionSpecQuery spec)
    , decide = \_ _ -> Left (transitionSpecDomainError spec)
    , buildCommand = const unexpectedCommand
    , respond = \_ _ -> Left (transitionSpecApiError spec)
    , encode = const unexpectedResponse
    }

respondFailingTransition :: TransitionSpec -> Transition TestInput TestContext TestDecision TestResult TestOutput
respondFailingTransition spec =
  Transition
    { name = transitionSpecName spec
    , decode = const (Right (transitionSpecInput spec))
    , buildQuery = const (transitionSpecQuery spec)
    , decide = \_ _ -> Right (transitionSpecDecision spec)
    , buildCommand = const (transitionSpecCommand spec)
    , respond = \_ _ -> Left (transitionSpecApiError spec)
    , encode = const unexpectedResponse
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

genEndpointName :: Gen EndpointName
genEndpointName =
  EndpointName <$> genText

genRawRequest :: Gen RawRequest
genRawRequest =
  RawRequest <$> genText

genRawResponse :: Gen RawResponse
genRawResponse =
  RawResponse <$> genText

genApiError :: Gen ApiError
genApiError =
  ApiError <$> genText

genDomainError :: Gen DomainError
genDomainError =
  DomainError <$> genText

genDBQuery :: Gen (DBQuery a)
genDBQuery =
  DBQuery <$> genText

genDBCommand :: Gen (DBCommand a)
genDBCommand =
  DBCommand <$> genText

genText :: Gen String
genText = do
  Label value <- arbitrary
  pure value

safeChar :: Gen Char
safeChar =
  choose ('a', 'z')

unexpectedQuery :: DBQuery a
unexpectedQuery =
  DBQuery "__unexpected_query__"

unexpectedCommand :: DBCommand a
unexpectedCommand =
  DBCommand "__unexpected_command__"

unexpectedResponse :: RawResponse
unexpectedResponse =
  RawResponse "__unexpected_response__"
