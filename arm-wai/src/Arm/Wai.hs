module Arm.Wai
  ( waiBoundary
  ) where

import Arm.Core (coreBoundary)

waiBoundary :: String
waiBoundary = coreBoundary ++ "/arm-wai"
