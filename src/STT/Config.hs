{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module STT.Config
  ( -- * Configuration Types
    AppConfig(..)
  , Device(..)
  , StopSignal(..)
  , Task(..)
  , RecordBackend(..)
  , SampleRate(..)
  , Minutes(..)

    -- * Configuration Loading
  , loadConfig
  , defaultAppConfig

    -- * Helper Functions
  , shouldTranscribe
  , shouldTranslate
  , getDeviceString
  , mkSampleRate
  , mkMinutes

    -- * Parsers (for testing)
  , parseWhisperModel
  , isLanguageCode
  , parseDevice
  , parseStopSignal
  , parseTask
  , parseRecordBackend
  , parseBool
  , parseDouble
  , parsePositiveInt
  ) where

import Data.Aeson (FromJSON(..), ToJSON)
import qualified Data.Text as T
import Data.Text (Text)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe)
import GHC.Generics (Generic)
import System.Environment (lookupEnv)
import qualified Configuration.Dotenv as Dotenv
import Text.Read (readMaybe)
import Control.Exception (catch, IOException)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))

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

-- | How audio is captured
data RecordBackend
  = AutoBackend      -- ^ PipeWire when pw-record and a running daemon are found, else ALSA
  | PipeWireBackend  -- ^ pw-record
  | AlsaBackend      -- ^ arecord
  deriving (Show, Read, Eq, Generic)

instance FromJSON RecordBackend
instance ToJSON RecordBackend

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
  { whisperModel :: !String          -- ^ whisper.cpp model name or GGML file path
  , whisperThreads :: !(Maybe Int)   -- ^ CPU threads for whisper; Nothing = derive from the machine
  , device :: !Device
  , sampleRate :: !SampleRate
  , maxDurationMinutes :: !Minutes
  , stopSignal :: !StopSignal
  , recordBackend :: !RecordBackend
  , language :: !(Maybe Text)
  , task :: !Task
  , keepRecordings :: !Bool
  , whisperBinaryPath :: !FilePath
  -- LLM post-processing settings
  , llmBinaryPath :: !FilePath
  , llmModelPath :: !FilePath
  , llmEnableCleaning :: !Bool
  , llmExtractTodos :: !Bool
  -- Vocabulary / context prompt settings
  , vocabFilePath :: !(Maybe FilePath)
  , whisperCarryPrompt :: !Bool
  -- Speaker diarization settings
  , diarizationEnabled :: !Bool
  , diarizeBinaryPath :: !FilePath
  , diarizeSegModelPath :: !FilePath
  , diarizeEmbModelPath :: !FilePath
  , diarizeNumSpeakers :: !(Maybe Int)
  , diarizeClusterThreshold :: !Double
  } deriving (Show, Generic)

-- | Default configuration values
defaultAppConfig :: AppConfig
defaultAppConfig = AppConfig
  { whisperModel = "base"
  , whisperThreads = Nothing
  , device = Auto
  , sampleRate = SampleRate 16000
  , maxDurationMinutes = Minutes 90
  , stopSignal = Enter
  , recordBackend = AutoBackend
  , language = Nothing
  , task = Transcribe
  , keepRecordings = False
  , whisperBinaryPath = "whisper.cpp/build/bin/whisper-cli"
  -- LLM defaults
  , llmBinaryPath = "llama.cpp/build/bin/llama-cli"
  , llmModelPath = "llama.cpp/models/tinyllama-1.1b-chat.gguf"
  , llmEnableCleaning = True
  , llmExtractTodos = False
  -- Vocabulary defaults
  , vocabFilePath = Nothing
  , whisperCarryPrompt = True
  -- Diarization defaults
  , diarizationEnabled = True
  , diarizeBinaryPath = "sherpa-onnx/build/bin/sherpa-onnx-offline-speaker-diarization"
  , diarizeSegModelPath = "sherpa-onnx/models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
  , diarizeEmbModelPath = "sherpa-onnx/models/wespeaker_en_voxceleb_CAM++.onnx"
  , diarizeNumSpeakers = Nothing
  , diarizeClusterThreshold = 0.7
  }

-- | Load configuration from .env file
loadConfig :: FilePath -> IO AppConfig
loadConfig envFile = do
  -- Load .env file if it exists (ignore if file doesn't exist)
  _ <- Dotenv.loadFile (Dotenv.defaultConfig { Dotenv.configPath = [envFile] })
       `catch` \(_ :: IOException) -> return ()

  -- Read environment variables with defaults.
  -- WHISPER_MODEL supersedes MODEL_SIZE, which older .env files still set;
  -- the old variable is honoured as the fallback so they keep working.
  legacyModel <- (>>= parseWhisperModel) <$> lookupEnv "MODEL_SIZE"
  whisperModel' <- readEnvWithDefault "WHISPER_MODEL"
                     (fromMaybe (whisperModel defaultAppConfig) legacyModel) parseWhisperModel
  whisperThreads' <- readEnvWithDefault "WHISPER_THREADS" (whisperThreads defaultAppConfig) (fmap Just . parsePositiveInt)
  device' <- readEnvWithDefault "DEVICE" (device defaultAppConfig) parseDevice
  sampleRate' <- readEnvWithDefault "SAMPLE_RATE" (sampleRate defaultAppConfig) parseSampleRate
  maxDuration' <- readEnvWithDefault "MAX_DURATION_MINUTES" (maxDurationMinutes defaultAppConfig) parseMinutes
  stopSignal' <- readEnvWithDefault "STOP_SIGNAL" (stopSignal defaultAppConfig) parseStopSignal
  recordBackend' <- readEnvWithDefault "RECORD_BACKEND" (recordBackend defaultAppConfig) parseRecordBackend
  language' <- readLanguage
  task' <- readEnvWithDefault "TASK" (task defaultAppConfig) parseTask
  keepRecordings' <- readEnvWithDefault "KEEP_RECORDINGS" (keepRecordings defaultAppConfig) parseBool
  whisperBin' <- readEnvWithDefault "WHISPER_BINARY_PATH" (whisperBinaryPath defaultAppConfig) Just

  -- LLM settings
  llmBinPath' <- readEnvWithDefault "LLM_BINARY_PATH" (llmBinaryPath defaultAppConfig) Just
  llmModelPath' <- readEnvWithDefault "LLM_MODEL_PATH" (llmModelPath defaultAppConfig) Just
  llmCleaning' <- readEnvWithDefault "LLM_ENABLE_CLEANING" (llmEnableCleaning defaultAppConfig) parseBool
  llmTodos' <- readEnvWithDefault "LLM_EXTRACT_TODOS" (llmExtractTodos defaultAppConfig) parseBool

  -- Vocabulary settings
  vocabFile' <- (>>= nonEmpty) <$> lookupEnv "VOCAB_FILE"
  carryPrompt' <- readEnvWithDefault "WHISPER_CARRY_PROMPT" (whisperCarryPrompt defaultAppConfig) parseBool

  -- Diarization settings
  diarEnabled' <- readEnvWithDefault "DIARIZATION_ENABLED" (diarizationEnabled defaultAppConfig) parseBool
  diarBin' <- readEnvWithDefault "DIARIZE_BINARY_PATH" (diarizeBinaryPath defaultAppConfig) Just
  diarSegModel' <- readEnvWithDefault "DIARIZE_SEGMENTATION_MODEL" (diarizeSegModelPath defaultAppConfig) Just
  diarEmbModel' <- readEnvWithDefault "DIARIZE_EMBEDDING_MODEL" (diarizeEmbModelPath defaultAppConfig) Just
  diarSpeakers' <- readEnvWithDefault "DIARIZE_NUM_SPEAKERS" (diarizeNumSpeakers defaultAppConfig) (fmap Just . parsePositiveInt)
  diarThreshold' <- readEnvWithDefault "DIARIZE_CLUSTER_THRESHOLD" (diarizeClusterThreshold defaultAppConfig) parseDouble

  return AppConfig
    { whisperModel = whisperModel'
    , whisperThreads = whisperThreads'
    , device = device'
    , sampleRate = sampleRate'
    , maxDurationMinutes = maxDuration'
    , stopSignal = stopSignal'
    , recordBackend = recordBackend'
    , language = language'
    , task = task'
    , keepRecordings = keepRecordings'
    , whisperBinaryPath = whisperBin'
    , llmBinaryPath = llmBinPath'
    , llmModelPath = llmModelPath'
    , llmEnableCleaning = llmCleaning'
    , llmExtractTodos = llmTodos'
    , vocabFilePath = vocabFile'
    , whisperCarryPrompt = carryPrompt'
    , diarizationEnabled = diarEnabled'
    , diarizeBinaryPath = diarBin'
    , diarizeSegModelPath = diarSegModel'
    , diarizeEmbModelPath = diarEmbModel'
    , diarizeNumSpeakers = diarSpeakers'
    , diarizeClusterThreshold = diarThreshold'
    }

-- | Read the transcription language. LANGUAGE doubles as glibc's locale
-- variable (Debian desktops export e.g. "en_US:en"), which the dev shell
-- inherits and whisper rejects, so only plausible whisper codes are taken.
readLanguage :: IO (Maybe Text)
readLanguage = do
  raw <- (>>= nonEmpty) <$> lookupEnv "LANGUAGE"
  case raw of
    Nothing -> return Nothing
    Just code
      | isLanguageCode code -> return (Just (T.pack code))
      | otherwise -> do
          putStrLn $ "Warning: LANGUAGE=" ++ code
                  ++ " is not a whisper language code (it looks like a system locale). Using auto-detection."
          return Nothing

-- | Whisper accepts ISO codes ("en", "yue") and English names ("english"),
-- all lower-case letters; locale strings carry '_', ':' or '.'
isLanguageCode :: String -> Bool
isLanguageCode s = length s >= 2 && all isAsciiLower s

-- | Treat an empty string as unset
nonEmpty :: String -> Maybe String
nonEmpty "" = Nothing
nonEmpty s = Just s

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

-- | A whisper model: either a bare whisper.cpp model name such as "base" or
-- "large-v3-turbo" (lower-cased, since the release files are), or a path to
-- a GGML file (anything with a slash or a .bin suffix, kept verbatim)
parseWhisperModel :: String -> Maybe String
parseWhisperModel s
  | null s || any isSpace s = Nothing
  | '/' `elem` s || ".bin" `isSuffixOf` s = Just s
  | all validNameChar lowered = Just lowered
  | otherwise = Nothing
  where
    lowered = map toLowerChar s
    toLowerChar c = if isAsciiUpper c then toEnum (fromEnum c + 32) else c
    validNameChar c = isAsciiLower c || isDigit c || c `elem` ("._-" :: String)

parseDevice :: String -> Maybe Device
parseDevice s = case map toLowerChar s of
  "auto" -> Just Auto
  "cpu" -> Just CPU
  "cuda" -> Just CUDA
  _ -> Nothing
  where
    toLowerChar c = if isAsciiUpper c then toEnum (fromEnum c + 32) else c

parseStopSignal :: String -> Maybe StopSignal
parseStopSignal s = case map toLowerChar s of
  "ctrl_c" -> Just CtrlC
  "enter" -> Just Enter
  "space" -> Just Space
  _ -> Nothing
  where
    toLowerChar c = if isAsciiUpper c then toEnum (fromEnum c + 32) else c

parseTask :: String -> Maybe Task
parseTask s = case map toLowerChar s of
  "transcribe" -> Just Transcribe
  "translate" -> Just Translate
  "both" -> Just Both
  _ -> Nothing
  where
    toLowerChar c = if isAsciiUpper c then toEnum (fromEnum c + 32) else c

parseRecordBackend :: String -> Maybe RecordBackend
parseRecordBackend s = case map toLowerChar s of
  "auto" -> Just AutoBackend
  "pipewire" -> Just PipeWireBackend
  "alsa" -> Just AlsaBackend
  _ -> Nothing
  where
    toLowerChar c = if isAsciiUpper c then toEnum (fromEnum c + 32) else c

parseDouble :: String -> Maybe Double
parseDouble = readMaybe

parsePositiveInt :: String -> Maybe Int
parsePositiveInt s = readMaybe s >>= \n -> if n >= 1 then Just n else Nothing

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
    toLowerChar c = if isAsciiUpper c then toEnum (fromEnum c + 32) else c

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
checkCuda =
  (readProcessWithExitCode "nvidia-smi" [] "" >>= \case
    (ExitSuccess, _, _) -> return True
    _ -> return False)
    `catch` \(_ :: IOException) -> return False
