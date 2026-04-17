module Main (main) where

import Control.Monad (when)
import System.Environment (getArgs)
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import STT.Config (loadConfig)
import STT.App (runApp)

main :: IO ()
main = do
  args <- getArgs

  -- Determine config file path
  let configPath = case args of
        [] -> ".env"
        (path:_) -> path

  -- Check if config file exists
  configExists <- doesFileExist configPath
  if not configExists && configPath /= ".env"
    then do
      putStrLn $ "Error: Config file not found: " ++ configPath
      exitFailure
    else do
      when (not configExists && configPath == ".env") $
        putStrLn "Note: .env file not found. Using default configuration."

      -- Load configuration
      config <- loadConfig configPath

      -- Run application
      runApp config
