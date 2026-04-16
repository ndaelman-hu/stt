{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module STT.Whisper
  ( TranscriptionResult(..)
  , transcribeFile
  , transcribeFileWithConfig
  ) where

import Data.Aeson (FromJSON(..), parseJSON, withObject, (.:), (.:?), decode)
import qualified Data.Text as T
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import qualified Data.ByteString.Lazy as BSL
import GHC.Generics (Generic)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import STT.Config (AppConfig(..), ModelSize(..), Device(..), Task(..))
import qualified STT.Config as Config

-- | Result of transcription
data TranscriptionResult = TranscriptionResult
  { transText :: !Text
  , transLanguage :: !(Maybe Text)
  , transDuration :: !(Maybe Double)
  , transTranslation :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

-- | JSON response from Python wrapper
data WhisperResponse = WhisperResponse
  { success :: !Bool
  , resText :: !(Maybe Text)
  , resLanguage :: !(Maybe Text)
  , resDuration :: !(Maybe Double)
  , resTranslation :: !(Maybe Text)
  , resError :: !(Maybe Text)
  } deriving (Show, Generic)

instance FromJSON WhisperResponse where
  parseJSON = withObject "WhisperResponse" $ \v -> WhisperResponse
    <$> v .: "success"
    <*> v .:? "text"
    <*> v .:? "language"
    <*> v .:? "duration"
    <*> v .:? "translation"
    <*> v .:? "error"

-- | Transcribe audio file using configuration
transcribeFileWithConfig :: AppConfig -> FilePath -> IO (Either String TranscriptionResult)
transcribeFileWithConfig config audioPath = do
  deviceStr <- Config.getDeviceString (device config)
  let modelSizeStr = modelSizeToString (modelSize config)
      taskStr = taskToString (task config)
      langStr = maybe "" T.unpack (language config)

  transcribeFile audioPath modelSizeStr deviceStr langStr taskStr

-- | Transcribe audio file with explicit parameters
transcribeFile
  :: FilePath  -- ^ Path to audio file
  -> String    -- ^ Model size (tiny, base, small, medium, large)
  -> String    -- ^ Device (cpu, cuda)
  -> String    -- ^ Language (empty string for auto-detect)
  -> String    -- ^ Task (transcribe, translate, both)
  -> IO (Either String TranscriptionResult)
transcribeFile audioPath modelSize device language task = do
  -- Construct command
  -- Script path: look in whisper-hs/scripts first, then scripts/
  let scriptPath = "whisper-hs/scripts/whisper_wrapper.py"
      args = [ scriptPath
             , audioPath
             , "--model-size", modelSize
             , "--device", device
             , "--task", task
             ] ++ (if null language then [] else ["--language", language])

  -- Execute Python wrapper
  (exitCode, stdout, stderr) <- readProcessWithExitCode "python3" args ""

  case exitCode of
    ExitFailure _ -> return $ Left $ "Whisper process failed: " ++ stderr
    ExitSuccess -> do
      -- Parse JSON response
      case decode (BSL.fromStrict $ encodeUtf8 $ T.pack stdout) of
        Nothing -> return $ Left $ "Failed to parse JSON response: " ++ stdout
        Just response ->
          if success response
            then case resText response of
              Nothing -> return $ Left "Response missing 'text' field"
              Just txt -> return $ Right TranscriptionResult
                { transText = txt
                , transLanguage = resLanguage response
                , transDuration = resDuration response
                , transTranslation = resTranslation response
                }
            else return $ Left $ maybe "Unknown error" T.unpack (resError response)

-- Helper functions
modelSizeToString :: ModelSize -> String
modelSizeToString Tiny = "tiny"
modelSizeToString Base = "base"
modelSizeToString Small = "small"
modelSizeToString Medium = "medium"
modelSizeToString Large = "large"

taskToString :: Task -> String
taskToString Transcribe = "transcribe"
taskToString Translate = "translate"
taskToString Both = "both"
