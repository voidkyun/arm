{-# LANGUAGE DuplicateRecordFields #-}

module Main
  ( main,
  )
where

import Arm.Core
  ( ApiError (..),
    ApiErrorKind (..),
    DBCommand (..),
    DBQuery (..),
    DomainErrorBoundary,
    EndpointName (..),
    Observation (..),
    RawRequest (..),
    RawResponse (..),
    Transition (..),
    ZeroDelta (..),
    coreBoundary,
    executeObservation,
    executeTransition,
  )
import Data.Functor.Identity
  ( Identity (..),
    runIdentity,
  )
import Test.Tasty
  ( TestTree,
    defaultMain,
    testGroup,
  )
import Test.Tasty.QuickCheck
  ( Arbitrary (..),
    Gen,
    Property,
    choose,
    elements,
    listOf1,
    testProperty,
    (===),
  )

newtype Label = Label String
  deriving (Eq, Show)

newtype ApiKind = ApiKind ApiErrorKind
  deriving (Show)

data TaskDomainError
  = TaskAlreadyExists String
  | TaskInvariantBroken String
  deriving (Eq, Show)

instance Arbitrary Label where
  arbitrary = Label <$> listOf1 safeChar

instance Arbitrary ApiKind where
  arbitrary =
    ApiKind
      <$> elements
        [ ApiParseError,
          ApiValidationError,
          ApiAuthorizationError,
          ApiNotFoundError,
          ApiConflictError,
          ApiInvariantViolation,
          ApiUnexpectedInterpreterFailure
        ]

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Arm.Core"
    [ testProperty "core boundary names the core package" propCoreBoundary,
      testGroup
        "Core vocabulary"
        [ testProperty "EndpointName preserves its label" propEndpointNameRoundTrip,
          testProperty "RawRequest preserves its body" propRawRequestRoundTrip,
          testProperty "RawResponse preserves its body" propRawResponseRoundTrip,
          testProperty "ApiError preserves its kind and message" propApiErrorRoundTrip,
          testProperty "ZeroDelta marks an empty algebra delta" propZeroDeltaIsStable,
          testProperty "DBQuery preserves its description" propDBQueryRoundTrip,
          testProperty "DBCommand preserves its description" propDBCommandRoundTrip
        ],
      testGroup
        "Endpoint descriptions"
        [ testProperty "Observation carries an endpoint name" propObservationCarriesEndpointName,
          testProperty "Transition carries an endpoint name" propTransitionCarriesEndpointName
        ],
      testGroup
        "Observation execution"
        [ testProperty "Observation execution can succeed" propObservationExecutionSucceeds,
          testProperty "Observation decode failures are returned" propObservationDecodeFailure,
          testProperty "Observation query failures are returned" propObservationQueryFailure,
          testProperty "Observation domain failures use the supplied boundary" propObservationDomainFailure,
          testProperty "Observation encode failures are returned" propObservationEncodeFailure
        ],
      testGroup
        "Transition execution"
        [ testProperty "Transition execution can succeed" propTransitionExecutionSucceeds,
          testProperty "Transition decode failures are returned" propTransitionDecodeFailure,
          testProperty "Transition query failures are returned" propTransitionQueryFailure,
          testProperty "Transition delta failures use the supplied boundary" propTransitionDeltaFailure,
          testProperty "Transition command failures are returned" propTransitionCommandFailure,
          testProperty "Transition response failures are returned" propTransitionRespondFailure,
          testProperty "Transition encode failures are returned" propTransitionEncodeFailure
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
  (apiErrorKind apiError, apiErrorMessage apiError) === (kind, value)
  where
    apiError = ApiError kind value

propZeroDeltaIsStable :: Property
propZeroDeltaIsStable =
  ZeroDelta === ZeroDelta

propDBQueryRoundTrip :: Label -> Property
propDBQueryRoundTrip (Label value) =
  dbQueryDescription (DBQuery value :: DBQuery ()) === value

propDBCommandRoundTrip :: Label -> Property
propDBCommandRoundTrip (Label value) =
  dbCommandDescription (DBCommand value :: DBCommand ()) === value

propObservationCarriesEndpointName :: Label -> Property
propObservationCarriesEndpointName (Label value) =
  actualName === expectedName
  where
    expectedName = EndpointName value
    Observation {name = actualName} = minimalObservation expectedName

propTransitionCarriesEndpointName :: Label -> Property
propTransitionCarriesEndpointName (Label value) =
  actualName === expectedName
  where
    expectedName = EndpointName value
    Transition {name = actualName} = minimalTransition expectedName

propObservationExecutionSucceeds :: Label -> Property
propObservationExecutionSucceeds (Label value) =
  runIdentity
    ( executeObservation
        unexpectedDomainErrorToApiError
        successfulQuery
        successfulObservation
        rawRequest
    )
    === expected
  where
    rawRequest = RawRequest value
    expected =
      Right
        ( RawResponse
            ( value
                <> "-query-context-"
                <> value
            )
        )

propObservationDecodeFailure :: Label -> Property
propObservationDecodeFailure (Label value) =
  runIdentity
    ( executeObservation
        unexpectedDomainErrorToApiError
        failIfQueryRuns
        endpoint
        (RawRequest value)
    )
    === Left expected
  where
    expected = ApiError ApiParseError value
    endpoint =
      Observation
        { name = EndpointName "decode-failure",
          decode = const (Left expected),
          buildQuery = \_ -> error "query should not be built after a decode failure",
          observe = \_ _ -> error "observe should not run after a decode failure",
          encode = \_ -> error "encode should not run after a decode failure"
        }

propObservationQueryFailure :: Label -> Property
propObservationQueryFailure (Label value) =
  runIdentity
    ( executeObservation
        unexpectedDomainErrorToApiError
        runQuery
        endpoint
        (RawRequest value)
    )
    === Left expected
  where
    expected = ApiError ApiUnexpectedInterpreterFailure value
    endpoint =
      (minimalObservation (EndpointName "query-failure"))
        { observe = \_ _ -> error "observe should not run after a query failure"
        }
    runQuery _ = Identity (Left expected)

propObservationDomainFailure :: Label -> Property
propObservationDomainFailure (Label value) =
  runIdentity
    ( executeObservation
        taskDomainErrorToApiError
        successfulUnitQuery
        endpoint
        (RawRequest value)
    )
    === Left (taskDomainErrorToApiError domainError)
  where
    domainError = TaskAlreadyExists value
    endpoint =
      (minimalObservation (EndpointName "domain-failure"))
        { observe = \_ _ -> Left domainError,
          encode = \_ -> error "encode should not run after a domain failure"
        }

propObservationEncodeFailure :: Label -> Property
propObservationEncodeFailure (Label value) =
  runIdentity
    ( executeObservation
        unexpectedDomainErrorToApiError
        successfulUnitQuery
        endpoint
        (RawRequest value)
    )
    === Left expected
  where
    expected = ApiError ApiValidationError value
    endpoint =
      Observation
        { name = EndpointName "encode-failure",
          decode = const (Right ()),
          buildQuery = const (DBQuery "query"),
          observe = \_ _ -> Right (),
          encode = const (Left expected)
        }

propTransitionExecutionSucceeds :: Label -> Property
propTransitionExecutionSucceeds (Label value) =
  runIdentity
    ( executeTransition
        unexpectedDomainErrorToApiError
        successfulQuery
        successfulCommand
        successfulTransition
        rawRequest
    )
    === expected
  where
    rawRequest = RawRequest value
    expected =
      Right
        ( RawResponse
            ( value
                <> "-query-context-"
                <> value
                <> "-query-context-"
                <> value
                <> "-delta-command-result"
            )
        )

propTransitionDecodeFailure :: Label -> Property
propTransitionDecodeFailure (Label value) =
  runIdentity
    ( executeTransition
        unexpectedDomainErrorToApiError
        failIfQueryRuns
        failIfCommandRuns
        endpoint
        (RawRequest value)
    )
    === Left expected
  where
    expected = ApiError ApiParseError value
    endpoint =
      Transition
        { name = EndpointName "decode-failure",
          decode = const (Left expected),
          buildQuery = \_ -> error "query should not be built after a decode failure",
          decide = \_ _ -> error "decide should not run after a decode failure",
          buildCommand = \_ -> error "command should not be built after a decode failure",
          respond = \_ _ -> error "respond should not run after a decode failure",
          encode = \_ -> error "encode should not run after a decode failure"
        }

propTransitionQueryFailure :: Label -> Property
propTransitionQueryFailure (Label value) =
  runIdentity
    ( executeTransition
        unexpectedDomainErrorToApiError
        runQuery
        failIfCommandRuns
        endpoint
        (RawRequest value)
    )
    === Left expected
  where
    expected = ApiError ApiUnexpectedInterpreterFailure value
    endpoint =
      (minimalTransition (EndpointName "query-failure"))
        { decide = \_ _ -> error "decide should not run after a query failure"
        }
    runQuery _ = Identity (Left expected)

propTransitionDeltaFailure :: Label -> Property
propTransitionDeltaFailure (Label value) =
  runIdentity
    ( executeTransition
        taskDomainErrorToApiError
        successfulUnitQuery
        failIfCommandRuns
        endpoint
        (RawRequest value)
    )
    === Left (taskDomainErrorToApiError domainError)
  where
    domainError = TaskInvariantBroken value
    endpoint =
      (minimalTransition (EndpointName "delta-failure"))
        { decide = \_ _ -> Left domainError,
          buildCommand = \_ -> error "command should not be built after a delta failure"
        }

propTransitionCommandFailure :: Label -> Property
propTransitionCommandFailure (Label value) =
  runIdentity
    ( executeTransition
        unexpectedDomainErrorToApiError
        successfulUnitQuery
        runCommand
        endpoint
        (RawRequest value)
    )
    === Left expected
  where
    expected = ApiError ApiUnexpectedInterpreterFailure value
    endpoint =
      (minimalTransition (EndpointName "command-failure"))
        { respond = \_ _ -> error "respond should not run after a command failure"
        }
    runCommand _ = Identity (Left expected)

propTransitionRespondFailure :: Label -> Property
propTransitionRespondFailure (Label value) =
  runIdentity
    ( executeTransition
        unexpectedDomainErrorToApiError
        successfulUnitQuery
        successfulUnitCommand
        endpoint
        (RawRequest value)
    )
    === Left expected
  where
    expected = ApiError ApiConflictError value
    endpoint =
      (minimalTransition (EndpointName "respond-failure"))
        { respond = \_ _ -> Left expected,
          encode = \_ -> error "encode should not run after a response failure"
        }

propTransitionEncodeFailure :: Label -> Property
propTransitionEncodeFailure (Label value) =
  runIdentity
    ( executeTransition
        unexpectedDomainErrorToApiError
        successfulUnitQuery
        successfulUnitCommand
        endpoint
        (RawRequest value)
    )
    === Left expected
  where
    expected = ApiError ApiValidationError value
    endpoint =
      Transition
        { name = EndpointName "encode-failure",
          decode = const (Right ()),
          buildQuery = const (DBQuery "query"),
          decide = \_ _ -> Right (),
          buildCommand = const (DBCommand "command"),
          respond = \_ _ -> Right (),
          encode = const (Left expected)
        }

minimalObservation :: EndpointName -> Observation () () domainError ()
minimalObservation endpointName =
  Observation
    { name = endpointName,
      decode = const (Right ()),
      buildQuery = const (DBQuery "query"),
      observe = \_ _ -> Right (),
      encode = const (Right (RawResponse "response"))
    }

minimalTransition :: EndpointName -> Transition () () domainError () () ()
minimalTransition endpointName =
  Transition
    { name = endpointName,
      decode = const (Right ()),
      buildQuery = const (DBQuery "query"),
      decide = \_ _ -> Right (),
      buildCommand = const (DBCommand "command"),
      respond = \_ _ -> Right (),
      encode = const (Right (RawResponse "response"))
    }

successfulObservation :: Observation String String domainError String
successfulObservation =
  Observation
    { name = EndpointName "successful-observation",
      decode = \(RawRequest rawBody) -> Right rawBody,
      buildQuery = \input -> DBQuery (input <> "-query"),
      observe = \context input -> Right (context <> "-" <> input),
      encode = \output -> Right (RawResponse output)
    }

successfulTransition :: Transition String String domainError String String String
successfulTransition =
  Transition
    { name = EndpointName "successful-transition",
      decode = \(RawRequest rawBody) -> Right rawBody,
      buildQuery = \input -> DBQuery (input <> "-query"),
      decide = \context input -> Right (context <> "-" <> input <> "-delta"),
      buildCommand = \delta -> DBCommand (delta <> "-command"),
      respond = \context result -> Right (context <> "-" <> result),
      encode = \output -> Right (RawResponse output)
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

taskDomainErrorToApiError :: DomainErrorBoundary TaskDomainError
taskDomainErrorToApiError domainError =
  case domainError of
    TaskAlreadyExists value ->
      ApiError ApiConflictError value
    TaskInvariantBroken value ->
      ApiError ApiInvariantViolation value

unexpectedDomainErrorToApiError :: DomainErrorBoundary domainError
unexpectedDomainErrorToApiError _ =
  error "domain error should not be converted"

safeChar :: Gen Char
safeChar =
  choose ('a', 'z')
