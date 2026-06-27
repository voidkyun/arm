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
  , coreBoundary
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

newtype Label = Label String
  deriving (Eq, Show)

instance Arbitrary Label where
  arbitrary = Label <$> listOf1 safeChar

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
        , testProperty "ApiError preserves its message" propApiErrorRoundTrip
        , testProperty "DomainError preserves its message" propDomainErrorRoundTrip
        , testProperty "DBQuery preserves its description" propDBQueryRoundTrip
        , testProperty "DBCommand preserves its description" propDBCommandRoundTrip
        ]
    , testGroup
        "Endpoint descriptions"
        [ testProperty "Observation carries an endpoint name" propObservationCarriesEndpointName
        , testProperty "Transition carries an endpoint name" propTransitionCarriesEndpointName
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

propApiErrorRoundTrip :: Label -> Property
propApiErrorRoundTrip (Label value) =
  apiErrorMessage (ApiError value) === value

propDomainErrorRoundTrip :: Label -> Property
propDomainErrorRoundTrip (Label value) =
  domainErrorMessage (DomainError value) === value

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

minimalObservation :: EndpointName -> Observation () () ()
minimalObservation endpointName =
  Observation
    { name = endpointName
    , decode = const (Right ())
    , buildQuery = const (DBQuery "query")
    , observe = \_ _ -> Right ()
    , encode = const (RawResponse "response")
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
    , encode = const (RawResponse "response")
    }

safeChar :: Gen Char
safeChar =
  choose ('a', 'z')
