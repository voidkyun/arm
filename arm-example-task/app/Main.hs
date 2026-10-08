{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Arm.PostgreSQL
import Arm.Wai (armApplication)
import Control.Exception (bracket)
import Data.Pool
import qualified Data.ByteString.Char8 as BS
import Database.PostgreSQL.Simple (connectPostgreSQL, close)
import Network.Wai.Handler.Warp
import System.Environment (lookupEnv)
import Task.HTTP
import Text.Read (readMaybe)

main :: IO ()
main = do
  database <- maybe "host=127.0.0.1 port=55432 dbname=arm_task user=arm password=arm-local" id <$> lookupEnv "ARM_DATABASE_URL"
  portText <- maybe "8080" id <$> lookupEnv "ARM_PORT"
  observationOnly <- (== Just "1") <$> lookupEnv "ARM_OBSERVATIONS_ONLY"
  port <- case readMaybe portText of
    Just number | number > 0 && number <= 65535 -> pure number
    _ -> ioError (userError "ARM_PORT must be an integer from 1 to 65535")
  bracket (newPool (defaultPoolConfig (connectPostgreSQL (BS.pack database)) close 60 4)) destroyAllResources $ \pool -> do
    let runQuery = runPostgreSQLQueryWithPool pool
        runCommand = runPostgreSQLCommandWithPool pool
        routes = taskObservations runQuery <> if observationOnly then [] else taskTransitions runQuery runCommand
    putStrLn ("ARM task sample listening on http://127.0.0.1:" <> show port)
    runSettings (setHost "127.0.0.1" (setPort port defaultSettings)) (armApplication routes)
