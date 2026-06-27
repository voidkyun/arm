module Main
  ( main
  ) where

import Arm.Core (coreBoundary)
import Arm.PostgreSQL (postgreSQLBoundary)
import Arm.Wai (waiBoundary)

main :: IO ()
main =
  putStr
    ( unlines
        [ "arm-example-task"
        , coreBoundary
        , waiBoundary
        , postgreSQLBoundary
        ]
    )
