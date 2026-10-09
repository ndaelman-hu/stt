{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module STT.Whisper
  ( TranscriptionResult(..)
  , PromptOptions(..)
  , WhisperCppResponse(..)
  , TranscriptSegment(..)
  , ResultInfo(..)
  , transcribeFile
  , transcribeFileWithConfig
  , transcribeFileWithPrompt
  ) where

import Data.Aeson (FromJSON(..), parseJSON, withObject, (.:), (.:?), decode)
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.ByteString.Lazy as BSL
import GHC.Generics (Generic)
import GHC.Conc (getNumProcessors)
import System.Directory (doesFileExist)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import STT.Config (AppConfig(..), Device(..), Task(..))
import qualified STT.Models as Models

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
transcribeFileWithConfig config = transcribeFileWithPrompt config Nothing

-- | Transcribe audio file using configuration, with an optional initial
-- prompt to bias recognition (e.g. towards technical vocabulary)
transcribeFileWithPrompt :: AppConfig -> Maybe Text -> FilePath -> IO (Either String TranscriptionResult)
transcribeFileWithPrompt config initialPrompt audioPath = do
  threads <- maybe defaultThreads return (whisperThreads config)
  let modelFile = Models.resolveWhisperModel (whisperModel config)
      -- whisper-cli offloads to whatever GPU backend it was built with
      -- (Vulkan in the Nix shell, CUDA in a CUDA build) unless told not to
      useGpu = device config /= CPU
      taskMode = task config
      langStr = maybe "auto" T.unpack (language config)
      prompt = PromptOptions initialPrompt (whisperCarryPrompt config)
      -- Speaker alignment needs fine-grained segment timestamps; whisper
      -- sometimes emits sentence-spanning segments (especially for languages
      -- without word spacing), which caps how many speakers can be told apart
      fineSegments = diarizationEnabled config

  modelExists <- doesFileExist modelFile
  if modelExists
    then transcribeFile (whisperBinaryPath config) audioPath modelFile threads useGpu langStr prompt fineSegments taskMode
    else return $ Left $ "Whisper model not found: " ++ modelFile
           ++ ". Pick one under \"Change Whisper model\" in the menu (it can download it), or set WHISPER_MODEL."

-- | Threads for whisper when WHISPER_THREADS is unset: all but two logical
-- processors, leaving headroom for recording and the UI. whisper.cpp's own
-- default is a fixed 4, which leaves most of a modern laptop idle.
defaultThreads :: IO Int
defaultThreads = max 1 . subtract 2 <$> getNumProcessors

-- | Initial prompt for whisper and whether to re-inject it every window
data PromptOptions = PromptOptions !(Maybe Text) !Bool

-- | Transcribe audio file with explicit parameters
transcribeFile
  :: FilePath       -- ^ Path to the whisper-cli binary
  -> FilePath       -- ^ Path to audio file
  -> FilePath       -- ^ Path to the GGML model file
  -> Int            -- ^ CPU threads for whisper
  -> Bool           -- ^ Allow GPU offload (False forces CPU with -ng)
  -> String         -- ^ Language (auto or language code)
  -> PromptOptions  -- ^ Initial prompt settings
  -> Bool           -- ^ Split output into fine-grained segments (for diarization)
  -> Task           -- ^ Task mode
  -> IO (Either String TranscriptionResult)
transcribeFile whisperBin audioPath modelFile threads useGpu lang prompt fineSegments taskMode =
  case taskMode of
    Transcribe -> transcribeOnly whisperBin audioPath modelFile threads useGpu lang prompt fineSegments False
    Translate -> transcribeOnly whisperBin audioPath modelFile threads useGpu lang prompt fineSegments True
    Both -> transcribeBoth whisperBin audioPath modelFile threads useGpu lang prompt fineSegments

-- | Transcribe only (with optional translation)
transcribeOnly :: FilePath -> FilePath -> FilePath -> Int -> Bool -> String -> PromptOptions -> Bool -> Bool -> IO (Either String TranscriptionResult)
transcribeOnly whisperBin audioPath modelFile threads useGpu lang (PromptOptions initialPrompt carryPrompt) fineSegments shouldTranslate = do
  let jsonOutputPath = audioPath ++ ".json"
      baseArgs = [ "-m", modelFile
                 , "-f", audioPath
                 , "-l", lang
                 , "-t", show threads
                 , "-oj"  -- Output JSON to file
                 ]
                 ++ ["-ng" | not useGpu]
      promptArgs = case initialPrompt of
        Nothing -> []
        Just p -> ["--prompt", T.unpack p]
                  ++ ["--carry-initial-prompt" | carryPrompt]
      -- -ml caps segment length (in tokens); segments are re-merged per
      -- speaker turn later, so short segments never surface to the user
      segmentArgs = if fineSegments then ["-ml", "24"] else []
      args = baseArgs
             ++ promptArgs
             ++ segmentArgs
             ++ ["--translate" | shouldTranslate]

  -- Execute whisper.cpp
  (exitCode, stdout, stderr) <- readProcessWithExitCode whisperBin args ""
  -- whisper-cli exits 0 for some usage errors (e.g. an unknown language), so
  -- a missing JSON file is the reliable sign that nothing was transcribed
  jsonWritten <- doesFileExist jsonOutputPath

  case exitCode of
    ExitFailure _ -> return $ Left $ "whisper.cpp failed: " ++ stderr
    ExitSuccess | not jsonWritten ->
      return $ Left $ "whisper.cpp produced no output: " ++ T.unpack (T.strip (T.pack (stderr ++ stdout)))
    ExitSuccess -> do
      -- Read JSON output from file
      jsonContent <- BSL.readFile jsonOutputPath
      case decode jsonContent of
        Nothing -> return $ Left "Failed to parse whisper.cpp JSON output"
        Just resp -> do
          let text = T.concat $ map segmentText (transcription resp)
              detectedLang = case resultInfo resp of
                       Just info -> detectedLanguage info
                       Nothing -> Nothing
          return $ Right TranscriptionResult
            { transText = T.strip text
            , transLanguage = detectedLang
            , transDuration = Nothing  -- whisper.cpp doesn't provide total duration easily
            , transTranslation = Nothing
            , transSegments = transcription resp
            }

-- | Transcribe and translate (both modes)
transcribeBoth :: FilePath -> FilePath -> FilePath -> Int -> Bool -> String -> PromptOptions -> Bool -> IO (Either String TranscriptionResult)
transcribeBoth whisperBin audioPath modelFile threads useGpu lang prompt fineSegments = do
  -- First, transcribe
  transResult <- transcribeOnly whisperBin audioPath modelFile threads useGpu lang prompt fineSegments False
  case transResult of
    Left err -> return $ Left err
    Right trans -> do
      -- Then, translate
      translateResult <- transcribeOnly whisperBin audioPath modelFile threads useGpu lang prompt fineSegments True
      case translateResult of
        Left err -> return $ Left err
        Right translation ->
          return $ Right trans
            { transTranslation = Just (transText translation)
            }
