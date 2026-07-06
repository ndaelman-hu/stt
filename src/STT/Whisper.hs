{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module STT.Whisper
  ( TranscriptionResult(..)
  , WhisperCppResponse(..)
  , TranscriptSegment(..)
  , ResultInfo(..)
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
  , transSegments :: ![TranscriptSegment]
  } deriving (Show, Eq, Generic)

-- | JSON response from whisper.cpp
data WhisperCppResponse = WhisperCppResponse
  { transcription :: ![TranscriptSegment]
  , resultInfo :: !(Maybe ResultInfo)
  } deriving (Show, Generic)

-- | A single transcription segment; offsets are milliseconds from the
-- start of the audio and absent in JSON emitted by older whisper.cpp builds
data TranscriptSegment = TranscriptSegment
  { segmentText :: !Text
  , segmentFromMs :: !(Maybe Int)
  , segmentToMs :: !(Maybe Int)
  } deriving (Show, Eq, Generic)

newtype ResultInfo = ResultInfo
  { detectedLanguage :: Maybe Text
  } deriving (Show, Generic)

instance FromJSON WhisperCppResponse where
  parseJSON = withObject "WhisperCppResponse" $ \v -> WhisperCppResponse
    <$> v .: "transcription"
    <*> v .:? "result"

instance FromJSON TranscriptSegment where
  parseJSON = withObject "TranscriptSegment" $ \v -> do
    text <- v .: "text"
    maybeOffsets <- v .:? "offsets"
    (fromMs, toMs) <- case maybeOffsets of
      Nothing -> return (Nothing, Nothing)
      Just offsets -> flip (withObject "offsets") offsets $ \o ->
        (,) <$> (Just <$> o .: "from") <*> (Just <$> o .: "to")
    return $ TranscriptSegment text fromMs toMs

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
      -- Speaker alignment needs fine-grained segment timestamps; whisper
      -- sometimes emits sentence-spanning segments (especially for languages
      -- without word spacing), which caps how many speakers can be told apart
      fineSegments = diarizationEnabled config

  transcribeFile audioPath modelSizeStr deviceStr langStr fineSegments taskMode

-- | Transcribe audio file with explicit parameters
transcribeFile
  :: FilePath     -- ^ Path to audio file
  -> String       -- ^ Model size (tiny, base, small, medium, large)
  -> String       -- ^ Device (cpu, cuda)
  -> String       -- ^ Language (auto or language code)
  -> Bool         -- ^ Split output into fine-grained segments (for diarization)
  -> Task         -- ^ Task mode
  -> IO (Either String TranscriptionResult)
transcribeFile audioPath modelSz dev lang fineSegments taskMode =
  case taskMode of
    Transcribe -> transcribeOnly audioPath modelSz dev lang fineSegments False
    Translate -> transcribeOnly audioPath modelSz dev lang fineSegments True
    Both -> transcribeBoth audioPath modelSz dev lang fineSegments

-- | Transcribe only (with optional translation)
transcribeOnly :: FilePath -> String -> String -> String -> Bool -> Bool -> IO (Either String TranscriptionResult)
transcribeOnly audioPath modelSz _dev lang fineSegments shouldTranslate = do
  let modelPath = "whisper.cpp/models/ggml-" ++ modelSz ++ ".bin"
      jsonOutputPath = audioPath ++ ".json"
      baseArgs = [ "-m", modelPath
                 , "-f", audioPath
                 , "-l", lang
                 , "-oj"  -- Output JSON to file
                 ]
      -- -ml caps segment length (in tokens); segments are re-merged per
      -- speaker turn later, so short segments never surface to the user
      segmentArgs = if fineSegments then ["-ml", "24"] else []
      args = baseArgs
             ++ segmentArgs
             ++ ["--translate" | shouldTranslate]

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
            , transSegments = transcription resp
            }

-- | Transcribe and translate (both modes)
transcribeBoth :: FilePath -> String -> String -> String -> Bool -> IO (Either String TranscriptionResult)
transcribeBoth audioPath modelSz dev lang fineSegments = do
  -- First, transcribe
  transResult <- transcribeOnly audioPath modelSz dev lang fineSegments False
  case transResult of
    Left err -> return $ Left err
    Right trans -> do
      -- Then, translate
      translateResult <- transcribeOnly audioPath modelSz dev lang fineSegments True
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
