{-# LANGUAGE OverloadedStrings #-}

module STT.App
  ( runApp
  , recordAndTranscribe
  , transcribeExistingFile
  , cleanTranscriptionMenu
  , extractTodosMenu
  ) where

import Control.Monad (forever, when, unless)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (removeFile, doesFileExist)
import System.Exit (exitSuccess)
import System.IO (hFlush, stdout)
import Text.Read (readMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)

import STT.Config (AppConfig(..), Task(..))
import qualified STT.Config as Config
import qualified STT.Audio as Audio
import qualified STT.Whisper as Whisper
import qualified STT.PostProcess as PostProcess
import qualified STT.Markdown as Markdown

-- | Main application loop with interactive menu
runApp :: AppConfig -> IO ()
runApp config = do
  putStrLn "========================================="
  putStrLn "  Real-time Speech-to-Text Transcriber"
  putStrLn "========================================="
  putStrLn ""
  printConfig config
  putStrLn ""

  forever $ do
    putStrLn "\nOptions:"
    putStrLn "1. Record and transcribe audio"
    putStrLn "2. Transcribe existing audio file"
    putStrLn "3. List audio devices"
    putStrLn "4. Clean transcription file"
    putStrLn "5. Extract TODOs from file"
    putStrLn "6. Quit"
    putStr "\nChoose an option (1-6): "
    hFlush stdout

    choice <- getLine
    putStrLn ""

    case choice of
      "1" -> recordAndTranscribeMenu config
      "2" -> transcribeExistingMenu config
      "3" -> listDevicesMenu
      "4" -> cleanTranscriptionMenu config
      "5" -> extractTodosMenu config
      "6" -> do
        putStrLn "Goodbye!"
        exitSuccess
      _ -> putStrLn "Invalid choice. Please choose 1-6."

-- | Print current configuration
printConfig :: AppConfig -> IO ()
printConfig config = do
  deviceStr <- Config.getDeviceString (device config)
  putStrLn "Current Configuration:"
  putStrLn $ "  Model: " ++ show (modelSize config)
  putStrLn $ "  Device: " ++ deviceStr
  putStrLn $ "  Sample Rate: " ++ show (Config.unSampleRate $ sampleRate config) ++ " Hz"
  putStrLn $ "  Max Duration: " ++ show (Config.unMinutes $ maxDurationMinutes config) ++ " minutes"
  putStrLn $ "  Stop Signal: " ++ show (stopSignal config)
  putStrLn $ "  Language: " ++ maybe "auto" T.unpack (language config)
  putStrLn $ "  Task: " ++ show (task config)
  putStrLn $ "  Keep Recordings: " ++ show (keepRecordings config)

-- | Menu for recording and transcribing
recordAndTranscribeMenu :: AppConfig -> IO ()
recordAndTranscribeMenu config = do
  putStr "Duration in seconds (press Enter for manual stop): "
  hFlush stdout
  durationInput <- getLine

  let duration = if null durationInput
                 then Nothing
                 else readMaybe durationInput

  putStr "Device ID (press Enter for default): "
  hFlush stdout
  deviceInput <- getLine

  let deviceId = if null deviceInput
                 then Nothing
                 else readMaybe deviceInput

  recordAndTranscribe config duration deviceId

-- | Menu for transcribing existing files
transcribeExistingMenu :: AppConfig -> IO ()
transcribeExistingMenu config = do
  putStr "Enter path to audio file: "
  hFlush stdout
  filePath <- getLine
  transcribeExistingFile config filePath

-- | Menu for listing devices
listDevicesMenu :: IO ()
listDevicesMenu = do
  putStrLn "Available audio devices:"
  devices <- Audio.listAudioDevices
  if null devices
    then putStrLn "No devices found or arecord not available."
    else mapM_ printDevice devices
  where
    printDevice dev =
      putStrLn $ "  " ++ show (Audio.deviceId dev) ++ ": " ++ T.unpack (Audio.deviceName dev)

-- | Record audio and transcribe it
recordAndTranscribe :: AppConfig -> Maybe Int -> Maybe Int -> IO ()
recordAndTranscribe config duration deviceId = do
  -- Record audio
  maybeAudioPath <- Audio.recordAudio config duration deviceId

  case maybeAudioPath of
    Nothing -> putStrLn "Recording failed or was interrupted."
    Just audioPath -> do
      putStrLn $ "Audio saved to: " ++ audioPath
      putStrLn "Transcribing..."

      -- Transcribe
      result <- Whisper.transcribeFileWithConfig config audioPath

      case result of
        Left err -> putStrLn $ "Transcription error: " ++ err
        Right transcription -> do
          displayTranscription config transcription

          -- Clean up audio file if configured
          unless (keepRecordings config) $ do
            removeFile audioPath
            putStrLn $ "Removed temporary file: " ++ audioPath

-- | Transcribe an existing audio file
transcribeExistingFile :: AppConfig -> FilePath -> IO ()
transcribeExistingFile config filePath = do
  exists <- doesFileExist filePath
  if not exists
    then putStrLn $ "File not found: " ++ filePath
    else do
      putStrLn "Transcribing..."
      result <- Whisper.transcribeFileWithConfig config filePath

      case result of
        Left err -> putStrLn $ "Transcription error: " ++ err
        Right transcription -> displayTranscription config transcription

-- | Display transcription results
displayTranscription :: AppConfig -> Whisper.TranscriptionResult -> IO ()
displayTranscription config result = do
  putStrLn "\n========================================="
  putStrLn "Transcription Results"
  putStrLn "========================================="

  when (Config.shouldTranscribe (task config)) $
    putStrLn $ "\nText: " ++ T.unpack (Whisper.transText result)

  when (Config.shouldTranslate (task config) && task config == Both) $
    case Whisper.transTranslation result of
      Just trans -> putStrLn $ "\nTranslation: " ++ T.unpack trans
      Nothing -> return ()

  case Whisper.transLanguage result of
    Just lang -> putStrLn $ "\nDetected Language: " ++ T.unpack lang
    Nothing -> return ()

  case Whisper.transDuration result of
    Just dur -> putStrLn $ "Duration: " ++ show (round dur :: Int) ++ " seconds"
    Nothing -> return ()

  putStrLn "========================================="

-- | Menu for cleaning transcription files
cleanTranscriptionMenu :: AppConfig -> IO ()
cleanTranscriptionMenu config = do
  putStr "Enter path to transcription file: "
  hFlush stdout
  filePath <- getLine

  putStrLn "Cleaning transcription..."
  result <- PostProcess.cleanTranscriptionFile
              (llmBinaryPath config)
              (llmModelPath config)
              filePath

  case result of
    Left err -> putStrLn $ "Error: " ++ err
    Right cleanedText -> do
      -- Save to new file
      timestamp <- formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
      let outputPath = filePath ++ ".cleaned_" ++ timestamp ++ ".txt"
      TIO.writeFile outputPath cleanedText
      putStrLn $ "\nCleaned transcription saved to: " ++ outputPath
      putStrLn "\n--- Preview (first 500 chars) ---"
      putStrLn $ T.unpack $ T.take 500 cleanedText
      putStrLn "..."

-- | Menu for extracting TODOs from transcription
extractTodosMenu :: AppConfig -> IO ()
extractTodosMenu config = do
  putStr "Enter path to transcription file: "
  hFlush stdout
  filePath <- getLine

  putStrLn "Extracting action items..."
  result <- PostProcess.extractTodosFromFile
              (llmBinaryPath config)
              (llmModelPath config)
              filePath

  case result of
    Left err -> putStrLn $ "Error: " ++ err
    Right todos -> do
      -- Also read original for meeting minutes
      originalText <- TIO.readFile filePath

      -- Create meeting minutes
      let processedResult = PostProcess.ProcessedResult
            { PostProcess.originalText = originalText
            , PostProcess.cleanedText = Nothing
            , PostProcess.todos = Just todos
            , PostProcess.processingErrors = []
            }

      -- Save to markdown
      timestamp <- formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
      let outputPath = filePath ++ ".minutes_" ++ timestamp ++ ".md"
      Markdown.saveMeetingMinutes outputPath processedResult

      -- Also print to console
      putStrLn "\n========================================="
      putStrLn "Action Items Extracted"
      putStrLn "========================================="
      TIO.putStrLn todos
      putStrLn "========================================="
