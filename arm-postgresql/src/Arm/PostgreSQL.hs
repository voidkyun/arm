module Arm.PostgreSQL
  ( postgreSQLBoundary
  ) where

import Arm.Core (coreBoundary)

postgreSQLBoundary :: String
postgreSQLBoundary = coreBoundary ++ "/arm-postgresql"
