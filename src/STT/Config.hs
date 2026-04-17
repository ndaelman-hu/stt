{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module STT.Config
  ( -- * Configuration Types
    AppConfig(..)
  , ModelSize(..)
  , Device(..)
  , StopSignal(..)
  , Task(..)
  , SampleRate(..)
  , Minutes(..)

    -- * Configuration Loading
  , loadConfig
  , defaultConfig

    -- * Helper Functions
  , shouldTranscribe
  , shouldTranslate
  , getDeviceString
  ) where

import Data.Aeson (FromJSON(..), ToJSON)
import qualified Data.Text as T
import Data.Text (Text)
import GHC.Generics (Generic)
import System.Environment (lookupEnv)
import Configuration.Dotenv (loadFile, defaultConfig)
import qualified Configuration.Dotenv as Dotenv
import Text.Read (readMaybe)
import Control.Monad (when)
import Control.Exception (catch, IOException)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))

-- | Whisper model sizes
data ModelSize
  = Tiny
  | Base
  | Small
  | Medium
  | Large
  deriving (Show, Read, Eq, Enum, Bounded, Generic)

instance FromJSON ModelSize
instance ToJSON ModelSize

-- | Compute device options
data Device
  = Auto
  | CPU
  | CUDA
  deriving (Show, Read, Eq, Generic)

instance FromJSON Device
instance ToJSON Device

-- | Recording stop signal options
data StopSignal
  = CtrlC
  | Enter
  | Space
  deriving (Show, Read, Eq, Generic)

instance FromJSON StopSignal
instance ToJSON StopSignal

-- | Transcription task types
data Task
  = Transcribe
  | Translate
  | Both
  deriving (Show, Read, Eq, Generic)

instance FromJSON Task
instance ToJSON Task

-- | Sample rate with validation (8000-48000 Hz)
newtype SampleRate = SampleRate { unSampleRate :: Int }
  deriving (Show, Eq)

mkSampleRate :: Int -> Maybe SampleRate
mkSampleRate rate
  | rate >= 8000 && rate <= 48000 = Just (SampleRate rate)
  | otherwise = Nothing

-- | Recording duration in minutes with validation (1-300)
newtype Minutes = Minutes { unMinutes :: Int }
  deriving (Show, Eq)

mkMinutes :: Int -> Maybe Minutes
mkMinutes mins
  | mins >= 1 && mins <= 300 = Just (Minutes mins)
  | otherwise = Nothing

-- | Application configuration
data AppConfig = AppConfig
  { modelSize :: !ModelSize
  , device :: !Device
  , sampleRate :: !SampleRate
  , maxDurationMinutes :: !Minutes
  , stopSignal :: !StopSignal
  , language :: !(Maybe Text)
  , task :: !Task
  , keepRecordings :: !Bool
  -- LLM post-processing settings
  , llmBinaryPath :: !FilePath
  , llmModelPath :: !FilePath
  , llmEnableCleaning :: !Bool
  , llmExtractTodos :: !Bool
  } deriving (Show, Generic)

-- | Default configuration values
defaultAppConfig :: AppConfig
defaultAppConfig = AppConfig
  { modelSize = Base
  , device = Auto
  , sampleRate = SampleRate 16000
  , maxDurationMinutes = Minutes 90
  , stopSignal = CtrlC
  , language = Nothing
  , task = Transcribe
  , keepRecordings = False
  -- LLM defaults
  , llmBinaryPath = "llama.cpp/build/bin/llama-cli"
  , llmModelPath = "models/tinyllama-1.1b-chat.gguf"
  , llmEnableCleaning = True
  , llmExtractTodos = False
  }

-- | Load configuration from .env file
loadConfig :: FilePath -> IO AppConfig
loadConfig envFile = do
  -- Load .env file if it exists (ignore if file doesn't exist)
  _ <- (Dotenv.loadFile (Dotenv.defaultConfig { Dotenv.configPath = [envFile] }))
       `catch` \(_ :: IOException) -> return ()

  -- Read environment variables with defaults
  modelSize' <- readEnvWithDefault "MODEL_SIZE" (modelSize defaultAppConfig) parseModelSize
  device' <- readEnvWithDefault "DEVICE" (device defaultAppConfig) parseDevice
  sampleRate' <- readEnvWithDefault "SAMPLE_RATE" (sampleRate defaultAppConfig) parseSampleRate
  maxDuration' <- readEnvWithDefault "MAX_DURATION_MINUTES" (maxDurationMinutes defaultAppConfig) parseMinutes
  stopSignal' <- readEnvWithDefault "STOP_SIGNAL" (stopSignal defaultAppConfig) parseStopSignal
  language' <- fmap T.pack <$> lookupEnv "LANGUAGE"
  task' <- readEnvWithDefault "TASK" (task defaultAppConfig) parseTask
  keepRecordings' <- readEnvWithDefault "KEEP_RECORDINGS" (keepRecordings defaultAppConfig) parseBool

  -- LLM settings
  llmBinPath' <- readEnvWithDefault "LLM_BINARY_PATH" (llmBinaryPath defaultAppConfig) Just
  llmModelPath' <- readEnvWithDefault "LLM_MODEL_PATH" (llmModelPath defaultAppConfig) Just
  llmCleaning' <- readEnvWithDefault "LLM_ENABLE_CLEANING" (llmEnableCleaning defaultAppConfig) parseBool
  llmTodos' <- readEnvWithDefault "LLM_EXTRACT_TODOS" (llmExtractTodos defaultAppConfig) parseBool

  return AppConfig
    { modelSize = modelSize'
    , device = device'
    , sampleRate = sampleRate'
    , maxDurationMinutes = maxDuration'
    , stopSignal = stopSignal'
    , language = language'
    , task = task'
    , keepRecordings = keepRecordings'
    , llmBinaryPath = llmBinPath'
    , llmModelPath = llmModelPath'
    , llmEnableCleaning = llmCleaning'
    , llmExtractTodos = llmTodos'
    }

-- | Read environment variable with default and parser
readEnvWithDefault :: String -> a -> (String -> Maybe a) -> IO a
readEnvWithDefault envVar defaultVal parser = do
  maybeVal <- lookupEnv envVar
  case maybeVal of
    Nothing -> return defaultVal
    Just val -> case parser val of
      Just parsed -> return parsed
      Nothing -> do
        putStrLn $ "Warning: Invalid value for " ++ envVar ++ ": " ++ val ++ ". Using default."
        return defaultVal

-- Parsers for configuration values
parseModelSize :: String -> Maybe ModelSize
parseModelSize s = case map toLowerChar s of
  "tiny" -> Just Tiny
  "base" -> Just Base
  "small" -> Just Small
  "medium" -> Just Medium
  "large" -> Just Large
  _ -> Nothing
  where
    toLowerChar c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

parseDevice :: String -> Maybe Device
parseDevice s = case map toLowerChar s of
  "auto" -> Just Auto
  "cpu" -> Just CPU
  "cuda" -> Just CUDA
  _ -> Nothing
  where
    toLowerChar c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

parseStopSignal :: String -> Maybe StopSignal
parseStopSignal s = case map toLowerChar s of
  "ctrl_c" -> Just CtrlC
  "enter" -> Just Enter
  "space" -> Just Space
  _ -> Nothing
  where
    toLowerChar c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

parseTask :: String -> Maybe Task
parseTask s = case map toLowerChar s of
  "transcribe" -> Just Transcribe
  "translate" -> Just Translate
  "both" -> Just Both
  _ -> Nothing
  where
    toLowerChar c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

parseSampleRate :: String -> Maybe SampleRate
parseSampleRate s = readMaybe s >>= mkSampleRate

parseMinutes :: String -> Maybe Minutes
parseMinutes s = readMaybe s >>= mkMinutes

parseBool :: String -> Maybe Bool
parseBool s = case map toLowerChar s of
  "true" -> Just True
  "false" -> Just False
  "1" -> Just True
  "0" -> Just False
  "yes" -> Just True
  "no" -> Just False
  _ -> Nothing
  where
    toLowerChar c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- | Check if transcription should be performed
shouldTranscribe :: Task -> Bool
shouldTranscribe Transcribe = True
shouldTranscribe Both = True
shouldTranscribe _ = False

-- | Check if translation should be performed
shouldTranslate :: Task -> Bool
shouldTranslate Translate = True
shouldTranslate Both = True
shouldTranslate _ = False

-- | Get device string for Whisper (resolve Auto to cpu or cuda)
getDeviceString :: Device -> IO String
getDeviceString Auto = do
  -- Check if CUDA is available (simple heuristic: check nvidia-smi)
  hasCuda <- checkCuda
  return $ if hasCuda then "cuda" else "cpu"
getDeviceString CPU = return "cpu"
getDeviceString CUDA = return "cuda"

-- | Check if CUDA is available
checkCuda :: IO Bool
checkCuda = do
  result <- (readProcessWithExitCode "nvidia-smi" [] "" >>= \r -> case r of
    (ExitSuccess, _, _) -> return True
    _ -> return False)
    `catch` \(_ :: IOException) -> return False
  return result
