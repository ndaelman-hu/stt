{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module STT.Whisper
  ( TranscriptionResult(..)
  , transcribeFile
  , transcribeFileWithConfig
  ) where

import Data.Aeson (FromJSON(..), parseJSON, withObject, (.:), (.:?), decode, Value(..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text as T
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as BSL8
import GHC.Generics (Generic)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
-- System.FilePath not needed anymore
import STT.Config (AppConfig(..), ModelSize(..), Device(..), Task(..))
import qualified STT.Config as Config

-- | Result of transcription
data TranscriptionResult = TranscriptionResult
  { transText :: !Text
  , transLanguage :: !(Maybe Text)
  , transDuration :: !(Maybe Double)
  , transTranslation :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

-- | JSON response from whisper.cpp
data WhisperCppResponse = WhisperCppResponse
  { transcription :: ![TranscriptSegment]
  , resultInfo :: !(Maybe ResultInfo)
  } deriving (Show, Generic)

data TranscriptSegment = TranscriptSegment
  { segmentText :: !Text
  } deriving (Show, Generic)

data ResultInfo = ResultInfo
  { detectedLanguage :: !(Maybe Text)
  } deriving (Show, Generic)

instance FromJSON WhisperCppResponse where
  parseJSON = withObject "WhisperCppResponse" $ \v -> WhisperCppResponse
    <$> v .: "transcription"
    <*> v .:? "result"

instance FromJSON TranscriptSegment where
  parseJSON = withObject "TranscriptSegment" $ \v -> TranscriptSegment
    <$> v .: "text"

instance FromJSON ResultInfo where
  parseJSON = withObject "ResultInfo" $ \v -> ResultInfo
    <$> v .:? "language"

-- | Transcribe audio file using configuration
transcribeFileWithConfig :: AppConfig -> FilePath -> IO (Either String TranscriptionResult)
transcribeFileWithConfig config audioPath = do
  deviceStr <- Config.getDeviceString (device config)
  let modelSizeStr = modelSizeToString (modelSize config)
      taskMode = task config
      langStr = maybe "auto" T.unpack (language config)

  transcribeFile audioPath modelSizeStr deviceStr langStr taskMode

-- | Transcribe audio file with explicit parameters
transcribeFile
  :: FilePath     -- ^ Path to audio file
  -> String       -- ^ Model size (tiny, base, small, medium, large)
  -> String       -- ^ Device (cpu, cuda)
  -> String       -- ^ Language (auto or language code)
  -> Task         -- ^ Task mode
  -> IO (Either String TranscriptionResult)
transcribeFile audioPath modelSize device language taskMode = do
  case taskMode of
    Transcribe -> transcribeOnly audioPath modelSize device language False
    Translate -> transcribeOnly audioPath modelSize device language True
    Both -> transcribeBoth audioPath modelSize device language

-- | Transcribe only (with optional translation)
transcribeOnly :: FilePath -> String -> String -> String -> Bool -> IO (Either String TranscriptionResult)
transcribeOnly audioPath modelSize device language shouldTranslate = do
  let modelPath = "whisper.cpp/models/ggml-" ++ modelSize ++ ".bin"
      jsonOutputPath = audioPath ++ ".json"
      baseArgs = [ "-m", modelPath
                 , "-f", audioPath
                 , "-l", language
                 , "-oj"  -- Output JSON to file
                 ]
      args = if shouldTranslate
             then baseArgs ++ ["--translate"]
             else baseArgs

  -- Execute whisper.cpp
  (exitCode, stdout, stderr) <- readProcessWithExitCode "whisper.cpp/build/bin/whisper-cli" args ""

  case exitCode of
    ExitFailure _ -> return $ Left $ "whisper.cpp failed: " ++ stderr
    ExitSuccess -> do
      -- Read JSON output from file
      jsonContent <- BSL.readFile jsonOutputPath
      case decode jsonContent of
        Nothing -> return $ Left $ "Failed to parse whisper.cpp JSON output"
        Just response -> do
          let text = T.concat $ map segmentText (transcription response)
              lang = case resultInfo response of
                       Just info -> detectedLanguage info
                       Nothing -> Nothing
          return $ Right TranscriptionResult
            { transText = T.strip text
            , transLanguage = lang
            , transDuration = Nothing  -- whisper.cpp doesn't provide total duration easily
            , transTranslation = Nothing
            }

-- | Transcribe and translate (both modes)
transcribeBoth :: FilePath -> String -> String -> String -> IO (Either String TranscriptionResult)
transcribeBoth audioPath modelSize device language = do
  -- First, transcribe
  transResult <- transcribeOnly audioPath modelSize device language False
  case transResult of
    Left err -> return $ Left err
    Right transcription -> do
      -- Then, translate
      translateResult <- transcribeOnly audioPath modelSize device language True
      case translateResult of
        Left err -> return $ Left err
        Right translation ->
          return $ Right transcription
            { transTranslation = Just (transText translation)
            }

-- Helper functions
modelSizeToString :: ModelSize -> String
modelSizeToString Tiny = "tiny"
modelSizeToString Base = "base"
modelSizeToString Small = "small"
modelSizeToString Medium = "medium"
modelSizeToString Large = "large"
