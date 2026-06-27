{-# LANGUAGE DuplicateRecordFields #-}

module Main
  ( main
  ) where

import Arm.Core
  ( ApiError (..)
  , ApiErrorKind (..)
  , DBCommand (..)
  , DBQuery (..)
  , DomainError (..)
  , DomainErrorKind (..)
  , EndpointName (..)
  , Observation (..)
  , RawRequest (..)
  , RawResponse (..)
  , Transition (..)
  , coreBoundary
  , domainErrorToApiError
  , executeObservation
  , executeTransition
  )
import Data.Functor.Identity
  ( Identity (..)
  , runIdentity
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
  , elements
  , listOf1
  , testProperty
  , (===)
  )

newtype Label = Label String
  deriving (Eq, Show)

newtype ApiKind = ApiKind ApiErrorKind
  deriving (Show)

newtype DomainKind = DomainKind DomainErrorKind
  deriving (Show)

instance Arbitrary Label where
  arbitrary = Label <$> listOf1 safeChar

instance Arbitrary ApiKind where
  arbitrary =
    ApiKind
      <$> elements
        [ ApiParseError
        , ApiValidationError
        , ApiAuthorizationError
        , ApiNotFoundError
        , ApiConflictError
        , ApiInvariantViolation
        , ApiUnexpectedInterpreterFailure
        ]

instance Arbitrary DomainKind where
  arbitrary =
    DomainKind
      <$> elements
        [ DomainValidationError
        , DomainAuthorizationError
        , DomainNotFoundError
        , DomainConflictError
        , DomainInvariantViolation
        ]

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Arm.Core"
    [ testProperty "core boundary names the core package" propCoreBoundary
    , testGroup
        "Core vocabulary"
        [ testProperty "EndpointName preserves its label" propEndpointNameRoundTrip
        , testProperty "RawRequest preserves its body" propRawRequestRoundTrip
        , testProperty "RawResponse preserves its body" propRawResponseRoundTrip
        , testProperty "ApiError preserves its kind and message" propApiErrorRoundTrip
        , testProperty "DomainError preserves its kind and message" propDomainErrorRoundTrip
        , testProperty "DomainError maps to a boundary ApiError" propDomainErrorToApiError
        , testProperty "DBQuery preserves its description" propDBQueryRoundTrip
        , testProperty "DBCommand preserves its description" propDBCommandRoundTrip
        ]
    , testGroup
        "Endpoint descriptions"
        [ testProperty "Observation carries an endpoint name" propObservationCarriesEndpointName
        , testProperty "Transition carries an endpoint name" propTransitionCarriesEndpointName
        ]
    , testGroup
        "Observation execution"
        [ testProperty "Observation execution can succeed" propObservationExecutionSucceeds
        , testProperty "Observation decode failures are returned" propObservationDecodeFailure
        , testProperty "Observation query failures are returned" propObservationQueryFailure
        , testProperty "Observation domain failures become ApiError values" propObservationDomainFailure
        , testProperty "Observation encode failures are returned" propObservationEncodeFailure
        ]
    , testGroup
        "Transition execution"
        [ testProperty "Transition execution can succeed" propTransitionExecutionSucceeds
        , testProperty "Transition decode failures are returned" propTransitionDecodeFailure
        , testProperty "Transition query failures are returned" propTransitionQueryFailure
        , testProperty "Transition decision failures become ApiError values" propTransitionDecisionFailure
        , testProperty "Transition command failures are returned" propTransitionCommandFailure
        , testProperty "Transition response failures are returned" propTransitionRespondFailure
        , testProperty "Transition encode failures are returned" propTransitionEncodeFailure
        ]
    ]

propCoreBoundary :: Property
propCoreBoundary =
  coreBoundary === "arm-core"

propEndpointNameRoundTrip :: Label -> Property
propEndpointNameRoundTrip (Label value) =
  unEndpointName (EndpointName value) === value

propRawRequestRoundTrip :: Label -> Property
propRawRequestRoundTrip (Label value) =
  rawRequestBody (RawRequest value) === value

propRawResponseRoundTrip :: Label -> Property
propRawResponseRoundTrip (Label value) =
  rawResponseBody (RawResponse value) === value

propApiErrorRoundTrip :: ApiKind -> Label -> Property
propApiErrorRoundTrip (ApiKind kind) (Label value) =
  let apiError = ApiError kind value
   in (apiErrorKind apiError, apiErrorMessage apiError) === (kind, value)

propDomainErrorRoundTrip :: DomainKind -> Label -> Property
propDomainErrorRoundTrip (DomainKind kind) (Label value) =
  let domainError = DomainError kind value
   in (domainErrorKind domainError, domainErrorMessage domainError) === (kind, value)

propDomainErrorToApiError :: DomainKind -> Label -> Property
propDomainErrorToApiError (DomainKind kind) (Label value) =
  domainErrorToApiError (DomainError kind value)
    === ApiError (expectedApiErrorKind kind) value

propDBQueryRoundTrip :: Label -> Property
propDBQueryRoundTrip (Label value) =
  dbQueryDescription (DBQuery value :: DBQuery ()) === value

propDBCommandRoundTrip :: Label -> Property
propDBCommandRoundTrip (Label value) =
  dbCommandDescription (DBCommand value :: DBCommand ()) === value

propObservationCarriesEndpointName :: Label -> Property
propObservationCarriesEndpointName (Label value) =
  let expectedName = EndpointName value
      Observation {name = actualName} = minimalObservation expectedName
   in actualName === expectedName

propTransitionCarriesEndpointName :: Label -> Property
propTransitionCarriesEndpointName (Label value) =
  let expectedName = EndpointName value
      Transition {name = actualName} = minimalTransition expectedName
   in actualName === expectedName

propObservationExecutionSucceeds :: Label -> Property
propObservationExecutionSucceeds (Label value) =
  let rawRequest = RawRequest value
      expected =
        Right
          ( RawResponse
              ( value
                  <> "-query-context-"
                  <> value
              )
          )
   in runIdentity (executeObservation successfulQuery successfulObservation rawRequest)
        === expected

propObservationDecodeFailure :: Label -> Property
propObservationDecodeFailure (Label value) =
  let expected = ApiError ApiParseError value
      endpoint =
        Observation
          { name = EndpointName "decode-failure"
          , decode = const (Left expected)
          , buildQuery = \_ -> error "query should not be built after a decode failure"
          , observe = \_ _ -> error "observe should not run after a decode failure"
          , encode = \_ -> error "encode should not run after a decode failure"
          }
   in runIdentity (executeObservation failIfQueryRuns endpoint (RawRequest value))
        === Left expected

propObservationQueryFailure :: Label -> Property
propObservationQueryFailure (Label value) =
  let expected = ApiError ApiUnexpectedInterpreterFailure value
      endpoint =
        (minimalObservation (EndpointName "query-failure"))
          { observe = \_ _ -> error "observe should not run after a query failure"
          }
      runQuery _ = Identity (Left expected)
   in runIdentity (executeObservation runQuery endpoint (RawRequest value))
        === Left expected

propObservationDomainFailure :: Label -> Property
propObservationDomainFailure (Label value) =
  let domainError = DomainError DomainConflictError value
      endpoint =
        (minimalObservation (EndpointName "domain-failure"))
          { observe = \_ _ -> Left domainError
          , encode = \_ -> error "encode should not run after a domain failure"
          }
   in runIdentity (executeObservation successfulUnitQuery endpoint (RawRequest value))
        === Left (domainErrorToApiError domainError)

propObservationEncodeFailure :: Label -> Property
propObservationEncodeFailure (Label value) =
  let expected = ApiError ApiValidationError value
      endpoint =
        Observation
          { name = EndpointName "encode-failure"
          , decode = const (Right ())
          , buildQuery = const (DBQuery "query")
          , observe = \_ _ -> Right ()
          , encode = const (Left expected)
          }
   in runIdentity (executeObservation successfulUnitQuery endpoint (RawRequest value))
        === Left expected

propTransitionExecutionSucceeds :: Label -> Property
propTransitionExecutionSucceeds (Label value) =
  let rawRequest = RawRequest value
      expected =
        Right
          ( RawResponse
              ( value
                  <> "-query-context-"
                  <> value
                  <> "-query-context-"
                  <> value
                  <> "-decision-command-result"
              )
          )
   in runIdentity
        ( executeTransition
            successfulQuery
            successfulCommand
            successfulTransition
            rawRequest
        )
        === expected

propTransitionDecodeFailure :: Label -> Property
propTransitionDecodeFailure (Label value) =
  let expected = ApiError ApiParseError value
      endpoint =
        Transition
          { name = EndpointName "decode-failure"
          , decode = const (Left expected)
          , buildQuery = \_ -> error "query should not be built after a decode failure"
          , decide = \_ _ -> error "decide should not run after a decode failure"
          , buildCommand = \_ -> error "command should not be built after a decode failure"
          , respond = \_ _ -> error "respond should not run after a decode failure"
          , encode = \_ -> error "encode should not run after a decode failure"
          }
   in runIdentity
        ( executeTransition
            failIfQueryRuns
            failIfCommandRuns
            endpoint
            (RawRequest value)
        )
        === Left expected

propTransitionQueryFailure :: Label -> Property
propTransitionQueryFailure (Label value) =
  let expected = ApiError ApiUnexpectedInterpreterFailure value
      endpoint =
        (minimalTransition (EndpointName "query-failure"))
          { decide = \_ _ -> error "decide should not run after a query failure"
          }
      runQuery _ = Identity (Left expected)
   in runIdentity
        ( executeTransition
            runQuery
            failIfCommandRuns
            endpoint
            (RawRequest value)
        )
        === Left expected

propTransitionDecisionFailure :: Label -> Property
propTransitionDecisionFailure (Label value) =
  let domainError = DomainError DomainInvariantViolation value
      endpoint =
        (minimalTransition (EndpointName "decision-failure"))
          { decide = \_ _ -> Left domainError
          , buildCommand = \_ -> error "command should not be built after a decision failure"
          }
   in runIdentity
        ( executeTransition
            successfulUnitQuery
            failIfCommandRuns
            endpoint
            (RawRequest value)
        )
        === Left (domainErrorToApiError domainError)

propTransitionCommandFailure :: Label -> Property
propTransitionCommandFailure (Label value) =
  let expected = ApiError ApiUnexpectedInterpreterFailure value
      endpoint =
        (minimalTransition (EndpointName "command-failure"))
          { respond = \_ _ -> error "respond should not run after a command failure"
          }
      runCommand _ = Identity (Left expected)
   in runIdentity
        ( executeTransition
            successfulUnitQuery
            runCommand
            endpoint
            (RawRequest value)
        )
        === Left expected

propTransitionRespondFailure :: Label -> Property
propTransitionRespondFailure (Label value) =
  let expected = ApiError ApiConflictError value
      endpoint =
        (minimalTransition (EndpointName "respond-failure"))
          { respond = \_ _ -> Left expected
          , encode = \_ -> error "encode should not run after a response failure"
          }
   in runIdentity
        ( executeTransition
            successfulUnitQuery
            successfulUnitCommand
            endpoint
            (RawRequest value)
        )
        === Left expected

propTransitionEncodeFailure :: Label -> Property
propTransitionEncodeFailure (Label value) =
  let expected = ApiError ApiValidationError value
      endpoint =
        Transition
          { name = EndpointName "encode-failure"
          , decode = const (Right ())
          , buildQuery = const (DBQuery "query")
          , decide = \_ _ -> Right ()
          , buildCommand = const (DBCommand "command")
          , respond = \_ _ -> Right ()
          , encode = const (Left expected)
          }
   in runIdentity
        ( executeTransition
            successfulUnitQuery
            successfulUnitCommand
            endpoint
            (RawRequest value)
        )
        === Left expected

minimalObservation :: EndpointName -> Observation () () ()
minimalObservation endpointName =
  Observation
    { name = endpointName
    , decode = const (Right ())
    , buildQuery = const (DBQuery "query")
    , observe = \_ _ -> Right ()
    , encode = const (Right (RawResponse "response"))
    }

minimalTransition :: EndpointName -> Transition () () () () ()
minimalTransition endpointName =
  Transition
    { name = endpointName
    , decode = const (Right ())
    , buildQuery = const (DBQuery "query")
    , decide = \_ _ -> Right ()
    , buildCommand = const (DBCommand "command")
    , respond = \_ _ -> Right ()
    , encode = const (Right (RawResponse "response"))
    }

successfulObservation :: Observation String String String
successfulObservation =
  Observation
    { name = EndpointName "successful-observation"
    , decode = \(RawRequest rawBody) -> Right rawBody
    , buildQuery = \input -> DBQuery (input <> "-query")
    , observe = \context input -> Right (context <> "-" <> input)
    , encode = \output -> Right (RawResponse output)
    }

successfulTransition :: Transition String String String String String
successfulTransition =
  Transition
    { name = EndpointName "successful-transition"
    , decode = \(RawRequest rawBody) -> Right rawBody
    , buildQuery = \input -> DBQuery (input <> "-query")
    , decide = \context input -> Right (context <> "-" <> input <> "-decision")
    , buildCommand = \decision -> DBCommand (decision <> "-command")
    , respond = \context result -> Right (context <> "-" <> result)
    , encode = \output -> Right (RawResponse output)
    }

successfulQuery :: DBQuery String -> Identity (Either ApiError String)
successfulQuery query =
  Identity (Right (dbQueryDescription query <> "-context"))

successfulCommand :: DBCommand String -> Identity (Either ApiError String)
successfulCommand command =
  Identity (Right (dbCommandDescription command <> "-result"))

successfulUnitQuery :: DBQuery () -> Identity (Either ApiError ())
successfulUnitQuery _ =
  Identity (Right ())

successfulUnitCommand :: DBCommand () -> Identity (Either ApiError ())
successfulUnitCommand _ =
  Identity (Right ())

failIfQueryRuns :: DBQuery context -> Identity (Either ApiError context)
failIfQueryRuns _ =
  error "query should not run"

failIfCommandRuns :: DBCommand result -> Identity (Either ApiError result)
failIfCommandRuns _ =
  error "command should not run"

expectedApiErrorKind :: DomainErrorKind -> ApiErrorKind
expectedApiErrorKind kind =
  case kind of
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

safeChar :: Gen Char
safeChar =
  choose ('a', 'z')
