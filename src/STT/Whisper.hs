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
import qualified Data.ByteString.Lazy as BSL
import GHC.Generics (Generic)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import STT.Config (AppConfig(..), ModelSize(..), Task(..))
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

newtype TranscriptSegment = TranscriptSegment
  { segmentText :: Text
  } deriving (Show, Generic)

newtype ResultInfo = ResultInfo
  { detectedLanguage :: Maybe Text
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
transcribeFile audioPath modelSz dev lang taskMode =
  case taskMode of
    Transcribe -> transcribeOnly audioPath modelSz dev lang False
    Translate -> transcribeOnly audioPath modelSz dev lang True
    Both -> transcribeBoth audioPath modelSz dev lang

-- | Transcribe only (with optional translation)
transcribeOnly :: FilePath -> String -> String -> String -> Bool -> IO (Either String TranscriptionResult)
transcribeOnly audioPath modelSz _dev lang shouldTranslate = do
  let modelPath = "whisper.cpp/models/ggml-" ++ modelSz ++ ".bin"
      jsonOutputPath = audioPath ++ ".json"
      baseArgs = [ "-m", modelPath
                 , "-f", audioPath
                 , "-l", lang
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
        Nothing -> return $ Left "Failed to parse whisper.cpp JSON output"
        Just resp -> do
          let text = T.concat $ map segmentText (transcription resp)
              lang = case resultInfo resp of
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
transcribeBoth audioPath modelSz dev lang = do
  -- First, transcribe
  transResult <- transcribeOnly audioPath modelSz dev lang False
  case transResult of
    Left err -> return $ Left err
    Right trans -> do
      -- Then, translate
      translateResult <- transcribeOnly audioPath modelSz dev lang True
      case translateResult of
        Left err -> return $ Left err
        Right translation ->
          return $ Right trans
            { transTranslation = Just (transText translation)
            }

-- Helper functions
modelSizeToString :: ModelSize -> String
modelSizeToString Tiny = "tiny"
modelSizeToString Base = "base"
modelSizeToString Small = "small"
modelSizeToString Medium = "medium"
modelSizeToString Large = "large"
