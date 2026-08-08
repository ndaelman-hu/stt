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
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
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
import qualified STT.Diarize as Diarize
import qualified STT.LLM as LLM
import qualified STT.Models as Models
import qualified STT.PostProcess as PostProcess
import qualified STT.Markdown as Markdown

-- | Main application loop with interactive menu
runApp :: AppConfig -> IO ()
runApp initialConfig = do
  putStrLn "========================================="
  putStrLn "  Real-time Speech-to-Text Transcriber"
  putStrLn "========================================="
  putStrLn ""
  printConfig initialConfig
  putStrLn ""

  configRef <- newIORef initialConfig

  forever $ do
    putStrLn "\n========================================="
    putStrLn "Main Menu"
    putStrLn "========================================="
    putStrLn ""
    putStrLn "Recording & Transcription:"
    putStrLn "  1. Record and transcribe audio"
    putStrLn "  2. Transcribe existing audio file"
    putStrLn ""
    putStrLn "Configuration:"
    putStrLn "  3. List audio devices"
    putStrLn "  4. Change language settings"
    putStrLn "  5. Change LLM model"
    putStrLn "  6. Toggle speaker diarization"
    putStrLn ""
    putStrLn "Post-Processing:"
    putStrLn "  7. Clean transcription file"
    putStrLn "  8. Extract TODOs from file"
    putStrLn ""
    putStrLn "  9. Quit"
    putStrLn ""
    putStr "Choose an option (1-9): "
    hFlush stdout

    choice <- getLine
    putStrLn ""

    config <- readIORef configRef

    case choice of
      "1" -> recordAndTranscribeMenu config
      "2" -> transcribeExistingMenu config
      "3" -> listDevicesMenu
      "4" -> changeLanguageMenu configRef
      "5" -> changeLlmModelMenu configRef
      "6" -> toggleDiarizationMenu configRef
      "7" -> cleanTranscriptionMenu config
      "8" -> extractTodosMenu config
      "9" -> do
        putStrLn "Goodbye!"
        exitSuccess
      _ -> putStrLn "Invalid choice. Please choose 1-9."

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
  putStrLn $ "  LLM Model: " ++ llmModelPath config
  putStrLn $ "  Speaker Diarization: " ++ (if diarizationEnabled config then "Enabled" else "Disabled")

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

          -- Diarization needs the WAV, so it must run before cleanup
          when (diarizationEnabled config) $
            diarizeAndDisplay config audioPath transcription

          -- Clean up audio file and whisper JSON sidecar if configured
          unless (keepRecordings config) $ do
            removeFile audioPath
            removeIfExists (audioPath ++ ".json")
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
        Right transcription -> do
          displayTranscription config transcription
          when (diarizationEnabled config) $
            diarizeAndDisplay config filePath transcription

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
            , PostProcess.speakerTranscript = Nothing
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

-- | Menu for choosing (and if necessary downloading) the LLM model used
-- for post-processing. Any instruct GGUF works; the curated list covers
-- the speed/quality range for CPU inference.
changeLlmModelMenu :: IORef AppConfig -> IO ()
changeLlmModelMenu configRef = do
  config <- readIORef configRef

  putStrLn $ "Current LLM model: " ++ llmModelPath config
  putStrLn ""
  putStrLn "Available models:"
  mapM_ (printModel config) (zip [1 :: Int ..] Models.knownModels)
  putStrLn ""
  putStr "Choose a model number, or type a path to any instruct GGUF (Enter to keep current): "
  hFlush stdout

  input <- getLine
  case input of
    "" -> putStrLn "LLM model unchanged."
    _ | Just n <- readMaybe input :: Maybe Int
      , Just spec <- lookup n (zip [1 ..] Models.knownModels) -> selectModel spec
      | otherwise -> selectPath input
  where
    printModel config (n, spec) = do
      installed <- Models.isInstalled spec
      let markers = concat
            [ if Models.modelPath spec == llmModelPath config then " [current]" else ""
            , if installed then " [installed]" else ""
            ]
      putStrLn $ "  " ++ show n ++ ". " ++ Models.modelLabel spec
              ++ " (" ++ Models.formatSize (Models.modelSizeMB spec) ++ ")"
              ++ markers
      putStrLn $ "       " ++ Models.modelNotes spec

    selectModel spec = do
      installed <- Models.isInstalled spec
      if installed
        then setModelPath (Models.modelPath spec)
        else do
          putStr $ "Download " ++ Models.modelLabel spec
                ++ " (" ++ Models.formatSize (Models.modelSizeMB spec)
                ++ ")? (Enter to download, anything else cancels): "
          hFlush stdout
          answer <- getLine
          if null answer
            then do
              result <- Models.downloadModel spec
              case result of
                Left err -> putStrLn err
                Right path -> setModelPath path
            else putStrLn "Download cancelled."

    selectPath path = do
      exists <- doesFileExist path
      if exists
        then setModelPath path
        else putStrLn $ "File not found: " ++ path

    setModelPath path = do
      config <- readIORef configRef
      let newConfig = config { llmModelPath = path }
      writeIORef configRef newConfig
      putStrLn $ "LLM model changed to: " ++ path
      putStrLn ""
      putStrLn "Updated configuration:"
      printConfig newConfig
-- | Remove a file if it exists (whisper's -oj sidecar may or may not be there)
removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  exists <- doesFileExist path
  when exists $ removeFile path

-- | Run diarization, let the LLM suggest speaker roles, confirm them with
-- the user, then display and save the speaker-labeled transcript
diarizeAndDisplay :: AppConfig -> FilePath -> Whisper.TranscriptionResult -> IO ()
diarizeAndDisplay config audioPath transcription = do
  available <- Diarize.checkDiarizationAvailable config
  case available of
    Left hint -> putStrLn hint
    Right () -> do
      putStrLn "Identifying speakers..."
      result <- Diarize.runDiarization config audioPath
      case result of
        Left err -> putStrLn $ "Diarization error: " ++ err
        Right intervals -> do
          let turns = Diarize.assignSpeakers intervals (Whisper.transSegments transcription)
              speakers = Diarize.speakerLabels turns

          putStrLn "\n========================================="
          putStrLn "Speaker Transcript"
          putStrLn "========================================="
          TIO.putStrLn $ Diarize.renderSpeakerTurns [] turns

          suggestions <- if llmEnableCleaning config
            then do
              putStrLn "\nSuggesting speaker roles..."
              suggested <- LLM.suggestSpeakerRoles
                             (llmBinaryPath config)
                             (llmModelPath config)
                             speakers
                             (Diarize.renderSpeakerTurns [] turns)
              case suggested of
                Left err -> do
                  putStrLn $ "Role suggestion failed: " ++ err
                  return []
                Right roles -> return roles
            else return []

          roleMap <- confirmRoles speakers suggestions turns
          let finalTranscript = Diarize.renderSpeakerTurns roleMap turns

          putStrLn "\n========================================="
          putStrLn "Speaker Transcript (final)"
          putStrLn "========================================="
          TIO.putStrLn finalTranscript

          -- Save alongside a timestamp so repeated runs don't clobber
          timestamp <- formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
          let outputPath = "transcript_speakers_" ++ timestamp ++ ".md"
              processedResult = PostProcess.ProcessedResult
                { PostProcess.originalText = Whisper.transText transcription
                , PostProcess.cleanedText = Nothing
                , PostProcess.todos = Nothing
                , PostProcess.speakerTranscript = Just finalTranscript
                , PostProcess.processingErrors = []
                }
          Markdown.saveMeetingMinutes outputPath processedResult

-- | Ask the user to confirm or override each suggested speaker role
confirmRoles :: [T.Text] -> [(T.Text, T.Text)] -> [Diarize.SpeakerTurn] -> IO [(T.Text, T.Text)]
confirmRoles speakers suggestions turns = do
  putStrLn "\nAssign speaker roles (Enter accepts the suggestion, '-' keeps the plain label):"
  concat <$> mapM askOne speakers
  where
    askOne speaker = do
      let suggestion = lookup speaker suggestions
          excerpt = case [Diarize.stText t | t <- turns, Diarize.stSpeaker t == speaker] of
            (firstUtterance:_) -> T.take 80 firstUtterance
            [] -> ""
      putStrLn ""
      putStrLn $ T.unpack speaker ++ ": \"" ++ T.unpack excerpt ++ "...\""
      case suggestion of
        Just role -> putStr $ "  Role [" ++ T.unpack role ++ "]: "
        Nothing -> putStr "  Role (Enter to keep plain label): "
      hFlush stdout
      input <- getLine
      return $ case (input, suggestion) of
        ("-", _) -> []
        ("", Just role) -> [(speaker, role)]
        ("", Nothing) -> []
        (typed, _) -> [(speaker, T.pack typed)]

-- | Menu for toggling speaker diarization
toggleDiarizationMenu :: IORef AppConfig -> IO ()
toggleDiarizationMenu configRef = do
  config <- readIORef configRef
  let newEnabled = not (diarizationEnabled config)
      newConfig = config { diarizationEnabled = newEnabled }

  when newEnabled $ do
    available <- Diarize.checkDiarizationAvailable config
    case available of
      Left hint -> putStrLn hint
      Right () -> return ()
    when (Config.unSampleRate (sampleRate config) /= 16000) $
      putStrLn "Warning: sherpa-onnx expects 16 kHz audio; set SAMPLE_RATE=16000 for recordings you want to diarize."

  writeIORef configRef newConfig
  putStrLn $ "Speaker diarization " ++ (if newEnabled then "enabled." else "disabled.")
  putStrLn ""
  putStrLn "Updated configuration:"
  printConfig newConfig

-- | Menu for changing language settings
changeLanguageMenu :: IORef AppConfig -> IO ()
changeLanguageMenu configRef = do
  config <- readIORef configRef

  putStrLn $ "Current language: " ++ maybe "auto" T.unpack (language config)
  putStrLn ""
  putStrLn "Common language codes:"
  putStrLn "  auto - Automatic detection"
  putStrLn "  en   - English"
  putStrLn "  es   - Spanish"
  putStrLn "  fr   - French"
  putStrLn "  de   - German"
  putStrLn "  it   - Italian"
  putStrLn "  pt   - Portuguese"
  putStrLn "  nl   - Dutch"
  putStrLn "  ja   - Japanese"
  putStrLn "  zh   - Chinese"
  putStrLn "  ko   - Korean"
  putStrLn "  ru   - Russian"
  putStrLn "  ar   - Arabic"
  putStrLn ""
  putStr "Enter language code (or press Enter to keep current): "
  hFlush stdout

  input <- getLine

  if null input
    then putStrLn "Language unchanged."
    else do
      let newLang = if input == "auto"
                    then Nothing
                    else Just (T.pack input)
      let newConfig = config { language = newLang }
      writeIORef configRef newConfig
      putStrLn $ "Language changed to: " ++ maybe "auto" T.unpack newLang
      putStrLn ""
      putStrLn "Updated configuration:"
      printConfig newConfig
