{-# LANGUAGE OverloadedStrings #-}

module STT.Audio
  ( -- * Audio Recording
    recordAudio
  , recordAudioTimed
  , recordAudioManual

    -- * Device Management
  , listAudioDevices
  , Device(..)
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, wait)
import Control.Concurrent.STM (TVar, newTVarIO, readTVar, writeTVar, atomically)
import Control.Exception (bracket, finally, catch, SomeException)
import Control.Monad (when, unless, void)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Process (readProcessWithExitCode, callProcess, spawnProcess, waitForProcess, terminateProcess, ProcessHandle)
import System.Exit (ExitCode(..))
import System.IO (hSetEcho, hSetBuffering, stdin, BufferMode(..), hReady, hGetChar)
import System.Posix.Signals (installHandler, Handler(Catch), sigINT)
import System.IO.Temp (withSystemTempFile)
import System.FilePath ((</>), (<.>))
import STT.Config (AppConfig(..), StopSignal(..), SampleRate(..), Minutes(..))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)

-- | Audio device information
data Device = Device
  { deviceId :: !Int
  , deviceName :: !Text
  } deriving (Show, Eq)

-- | List available audio devices using arecord
listAudioDevices :: IO [Device]
listAudioDevices = do
  (exitCode, stdout, _) <- readProcessWithExitCode "arecord" ["-L"] ""
  case exitCode of
    ExitFailure _ -> return []
    ExitSuccess -> return $ parseDevices (T.pack stdout)
  where
    parseDevices :: Text -> [Device]
    parseDevices output =
      let deviceLines = filter (not . T.null) $ T.lines output
          -- Simple parsing: just enumerate lines as devices
          indexed = zip [0..] deviceLines
      in [Device idx name | (idx, name) <- indexed, not (T.isPrefixOf " " name)]

-- | Record audio with configuration (chooses timed or manual based on duration)
recordAudio :: AppConfig -> Maybe Int -> Maybe Int -> IO (Maybe FilePath)
recordAudio config duration device =
  case duration of
    Just d -> recordAudioTimed config d device
    Nothing -> recordAudioManual config device

-- | Record audio for a fixed duration
recordAudioTimed :: AppConfig -> Int -> Maybe Int -> IO (Maybe FilePath)
recordAudioTimed config durationSecs deviceId = do
  timestamp <- formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
  let filename = "recording_" ++ timestamp ++ ".wav"
      tempDir = "/tmp"
      outputPath = tempDir </> filename

  putStrLn $ "Recording for " ++ show durationSecs ++ " seconds..."
  putStrLn $ "Output: " ++ outputPath

  let sampleRateStr = show $ unSampleRate (sampleRate config)
      deviceArg = case deviceId of
        Nothing -> []
        Just d -> ["-D", "hw:" ++ show d]

  (exitCode, _, stderr) <- readProcessWithExitCode "arecord"
    (deviceArg ++ ["-f", "S16_LE", "-c", "1", "-r", sampleRateStr, "-d", show durationSecs, outputPath])
    ""

  case exitCode of
    ExitSuccess -> do
      putStrLn "Recording complete."
      return $ Just outputPath
    ExitFailure code -> do
      putStrLn $ "Recording failed with exit code " ++ show code
      putStrLn stderr
      return Nothing

-- | Record audio with manual stop (Enter, Space, or Ctrl+C)
recordAudioManual :: AppConfig -> Maybe Int -> IO (Maybe FilePath)
recordAudioManual config deviceId = do
  timestamp <- formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
  let filename = "recording_" ++ timestamp ++ ".wav"
      tempDir = "/tmp"
      outputPath = tempDir </> filename

  let stopSig = stopSignal config
  putStrLn "Recording started..."
  putStrLn $ case stopSig of
    CtrlC -> "Press Ctrl+C to stop recording."
    Enter -> "Press Enter to stop recording."
    Space -> "Press Space to stop recording."

  -- Create stop flag
  stopFlag <- newTVarIO False

  -- Set up stop signal handler
  case stopSig of
    CtrlC -> do
      void $ installHandler sigINT (Catch $ atomically $ writeTVar stopFlag True) Nothing
    _ -> return ()

  let sampleRateStr = show $ unSampleRate (sampleRate config)
      deviceArg = case deviceId of
        Nothing -> []
        Just d -> ["-D", "hw:" ++ show d]
      maxDurationSecs = unMinutes (maxDurationMinutes config) * 60

  -- Start recording process
  recordingProcess <- spawnProcess "arecord"
    (deviceArg ++ ["-f", "S16_LE", "-c", "1", "-r", sampleRateStr, "-d", show maxDurationSecs, outputPath])

  -- Start key listener thread for Enter/Space
  keyListener <- case stopSig of
    CtrlC -> return Nothing
    Enter -> Just <$> async (waitForKey '\n' stopFlag)
    Space -> Just <$> async (waitForKey ' ' stopFlag)

  -- Wait for stop signal
  let waitLoop = do
        stopped <- atomically $ readTVar stopFlag
        unless stopped $ do
          threadDelay 100000  -- 100ms
          waitLoop

  waitLoop `finally` do
    -- Stop recording
    terminateProcess recordingProcess
    void $ waitForProcess recordingProcess
    maybe (return ()) cancel keyListener

  putStrLn "Recording stopped."
  return $ Just outputPath

-- | Wait for a specific key press
waitForKey :: Char -> TVar Bool -> IO ()
waitForKey expectedKey stopFlag = do
  -- Set terminal to raw mode (no buffering, no echo)
  hSetBuffering stdin NoBuffering
  hSetEcho stdin False

  let loop = do
        ready <- hReady stdin
        when ready $ do
          c <- hGetChar stdin
          when (c == expectedKey) $ atomically $ writeTVar stopFlag True
        stopped <- atomically $ readTVar stopFlag
        unless stopped $ do
          threadDelay 100000  -- 100ms
          loop

  loop `finally` do
    -- Restore terminal to normal mode
    hSetBuffering stdin LineBuffering
    hSetEcho stdin True
