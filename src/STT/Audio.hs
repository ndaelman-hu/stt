{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Microphone capture through PipeWire (pw-record) or ALSA (arecord), with
-- the post-processing both need: a repaired WAV header and a level check.
module STT.Audio
  ( -- * Audio Recording
    recordAudio
  , recordAudioTimed
  , recordAudioManual

    -- * Backends and Devices
  , Backend(..)
  , backendName
  , detectBackend
  , listAudioDevices
  , Device(..)

    -- * WAV helpers (exported for tests)
  , fixWavHeader
  , locateDataChunk
  , peakDbfs
  , silenceThresholdDbfs
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO, writeTVar, atomically)
import Control.Exception (catch, finally, try, IOException)
import Control.Monad (when, unless, void)
import Data.Aeson (Value(..), decode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe, parseJSON)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import System.Directory (doesFileExist, doesPathExist, getFileSize)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.IO (IOMode(..), SeekMode(..), BufferMode(..), hSetEcho, hSetBuffering, stdin, hReady, withBinaryFile, hFileSize, hSeek)
import System.Posix.Signals (installHandler, Handler(Catch), sigINT, signalProcess)
import System.Process (ProcessHandle, readProcessWithExitCode, spawnProcess, waitForProcess, terminateProcess, getProcessExitCode, getPid)
import System.Timeout (timeout)
import Text.Printf (printf)
import STT.Config (AppConfig(..), StopSignal(..), SampleRate(..), Minutes(..), RecordBackend(..))

-- | How audio is captured
data Backend
  = PipeWire  -- ^ pw-record: follows the desktop's default microphone; devices are PipeWire nodes
  | Alsa      -- ^ arecord: raw ALSA; without the pipewire-alsa plugin "default" is the first sound card
  deriving (Show, Eq)

backendName :: Backend -> String
backendName PipeWire = "PipeWire (pw-record)"
backendName Alsa = "ALSA (arecord)"

-- | The configured backend, or for "auto" PipeWire whenever pw-record and a
-- running PipeWire daemon are both present, else ALSA
detectBackend :: AppConfig -> IO Backend
detectBackend config = case recordBackend config of
  PipeWireBackend -> return PipeWire
  AlsaBackend -> return Alsa
  AutoBackend -> do
    hasPwRecord <- commandExists "pw-record"
    runtimeDir <- lookupEnv "XDG_RUNTIME_DIR"
    daemonUp <- maybe (return False) (\d -> doesPathExist (d </> "pipewire-0")) runtimeDir
    return $ if hasPwRecord && daemonUp then PipeWire else Alsa

-- | A capture device as the user selects it
data Device = Device
  { deviceId :: !Text        -- ^ what to pass as input device: a PipeWire node id or an ALSA PCM name
  , deviceName :: !Text
  , deviceIsDefault :: !Bool -- ^ what gets used when no device is given
  } deriving (Show, Eq)

-- | List capture devices of the backend
listAudioDevices :: Backend -> IO [Device]
listAudioDevices PipeWire = do
  (exitCode, stdout, _) <- runTool "pw-dump" []
  return $ case exitCode of
    ExitSuccess -> maybe [] parsePipeWireDump (decode (BSL.fromStrict (TE.encodeUtf8 (T.pack stdout))))
    _ -> []
listAudioDevices Alsa = do
  (exitCode, stdout, _) <- runTool "arecord" ["-L"]
  return $ case exitCode of
    ExitSuccess -> parseArecordList (T.pack stdout)
    _ -> []

-- | Audio sources from pw-dump's object list, with the default source marked
parsePipeWireDump :: Value -> [Device]
parsePipeWireDump (Array objs) =
  [ Device (T.pack (show nodeId)) description (Just name == defaultSource)
  | obj <- toList objs
  , Just props <- [field "info" obj >>= field "props"]
  , field "media.class" props == Just (String "Audio/Source")
  , Just nodeId <- [field "id" obj >>= asInt]
  , let name = fromMaybe "" (field "node.name" props >>= asText)
        description = fromMaybe name (field "node.description" props >>= asText)
  ]
  where
    defaultSource = listToMaybe
      [ name
      | obj <- toList objs
      , field "type" obj == Just (String "PipeWire:Interface:Metadata")
      , (field "props" obj >>= field "metadata.name") == Just (String "default")
      , Just (Array entries) <- [field "metadata" obj]
      , entry <- toList entries
      , field "key" entry == Just (String "default.audio.source")
      , Just name <- [field "value" entry >>= field "name" >>= asText]
      ]
parsePipeWireDump _ = []

field :: Text -> Value -> Maybe Value
field key (Object o) = KM.lookup (Key.fromText key) o
field _ _ = Nothing

asText :: Value -> Maybe Text
asText (String t) = Just t
asText _ = Nothing

asInt :: Value -> Maybe Int
asInt = parseMaybe parseJSON

-- | arecord -L prints one PCM name per unindented line, each followed by
-- indented description lines; "default" is used when no device is given
parseArecordList :: Text -> [Device]
parseArecordList = go . T.lines
  where
    go (line : rest)
      | T.null line || T.isPrefixOf " " line || line == "null" = go rest
      | otherwise =
          let (descLines, rest') = span (T.isPrefixOf " ") rest
              description = if null descLines then line else T.unwords (map T.strip descLines)
          in Device line description (line == "default") : go rest'
    go [] = []

-- | Record audio: for a fixed duration, or until the stop signal
recordAudio :: AppConfig -> Maybe Int -> Maybe String -> IO (Maybe FilePath)
recordAudio config duration dev = case duration of
  Just d -> recordAudioTimed config d dev
  Nothing -> recordAudioManual config dev

-- | Record for a fixed number of seconds
recordAudioTimed :: AppConfig -> Int -> Maybe String -> IO (Maybe FilePath)
recordAudioTimed config durationSecs dev = do
  putStrLn $ "Recording for " ++ show durationSecs ++ " seconds..."
  recordUntil config dev $ \recorder ->
    let loop remainingMs = when (remainingMs > 0) $ do
          finished <- getProcessExitCode recorder
          when (isNothing finished) $ do
            threadDelay 100000
            loop (remainingMs - 100 :: Int)
    in loop (durationSecs * 1000)

-- | Record until the configured stop signal (Enter, Space, or Ctrl+C) or
-- the maximum duration
recordAudioManual :: AppConfig -> Maybe String -> IO (Maybe FilePath)
recordAudioManual config dev = do
  let stopSig = stopSignal config
      maxMs = unMinutes (maxDurationMinutes config) * 60 * 1000
  putStrLn "Recording started..."
  putStrLn $ case stopSig of
    CtrlC -> "Press Ctrl+C to stop recording."
    Enter -> "Press Enter to stop recording."
    Space -> "Press Space to stop recording."

  stopFlag <- newTVarIO False
  -- Ctrl+C sets the flag instead of killing the app; the previous handler
  -- is restored afterwards so Ctrl+C in the menu behaves as usual
  previousHandler <- case stopSig of
    CtrlC -> Just <$> installHandler sigINT (Catch $ atomically $ writeTVar stopFlag True) Nothing
    _ -> return Nothing

  let record = recordUntil config dev $ \recorder -> do
        keyListener <- case stopSig of
          CtrlC -> return Nothing
          Enter -> Just <$> async (waitForKey '\n' stopFlag)
          Space -> Just <$> async (waitForKey ' ' stopFlag)
        let loop elapsedMs = do
              stopped <- readTVarIO stopFlag
              finished <- getProcessExitCode recorder
              unless (stopped || isJust finished || elapsedMs >= maxMs) $ do
                threadDelay 100000
                loop (elapsedMs + 100)
        loop 0 `finally` maybe (return ()) cancel keyListener

  record `finally` maybe (return ()) (\h -> void $ installHandler sigINT h Nothing) previousHandler

-- | Start the recorder, run the waiting action, then stop the recorder
-- gracefully, repair the WAV header and check the level
recordUntil :: AppConfig -> Maybe String -> (ProcessHandle -> IO ()) -> IO (Maybe FilePath)
recordUntil config dev waitToStop = do
  backend <- detectBackend config
  timestamp <- formatTime defaultTimeLocale "%Y%m%d_%H%M%S" <$> getCurrentTime
  let outputPath = "/tmp" </> ("recording_" ++ timestamp ++ ".wav")
      (cmd, args) = recorderCommand backend config dev outputPath

  started <- try (spawnProcess cmd args)
  case started of
    Left (e :: IOException) -> do
      putStrLn $ "Recording failed: could not start " ++ cmd ++ ": " ++ show e
      return Nothing
    Right recorder -> do
      waitToStop recorder `finally` stopRecorder recorder
      putStrLn "Recording stopped."

      exists <- doesFileExist outputPath
      size <- if exists then getFileSize outputPath else return 0
      if size <= 44
        then do
          putStrLn $ "Recording failed: " ++ cmd ++ " produced no audio."
          putStrLn $ deviceHint backend
          return Nothing
        else do
          fixWavHeader outputPath
          level <- peakDbfs outputPath
          case level of
            Just db | db < silenceThresholdDbfs -> do
              printf "Warning: the recording is nearly silent (peak %.0f dBFS); whisper tends to hallucinate on silence.\n" db
              putStrLn $ deviceHint backend
            _ -> return ()
          return (Just outputPath)

-- | The capture command for a backend: 16-bit mono at the configured rate
recorderCommand :: Backend -> AppConfig -> Maybe String -> FilePath -> (String, [String])
recorderCommand backend config dev outputPath = case backend of
  PipeWire ->
    ( "pw-record"
    , ["--rate", rate, "--channels", "1", "--format", "s16"]
        ++ maybe [] (\target -> ["--target", target]) dev
        ++ [outputPath]
    )
  Alsa ->
    ( "arecord"
    , maybe [] (\d -> ["-D", d]) dev
        ++ ["-f", "S16_LE", "-c", "1", "-r", rate, outputPath]
    )
  where
    rate = show (unSampleRate (sampleRate config))

-- | Ask the recorder to stop with SIGINT, which both tools treat as "finish
-- the file", escalating to SIGTERM if it does not exit promptly
stopRecorder :: ProcessHandle -> IO ()
stopRecorder recorder = do
  running <- isNothing <$> getProcessExitCode recorder
  when running $ do
    mpid <- getPid recorder
    maybe (terminateProcess recorder) (signalProcess sigINT) mpid
    exited <- timeout 3000000 (waitForProcess recorder)
    when (isNothing exited) $ terminateProcess recorder
  void $ waitForProcess recorder

deviceHint :: Backend -> String
deviceHint PipeWire =
  "Check the input device: \"List audio devices\" shows the PipeWire sources and the current default. "
  ++ "Pass a source id as the input device, or change the default with: wpctl set-default <id>"
deviceHint Alsa =
  "Check the input device: without the pipewire-alsa plugin, arecord's default is the first sound card, "
  ++ "often an empty headset jack. Install pipewire-alsa, or pass a device from \"List audio devices\" "
  ++ "such as plughw:CARD=...,DEV=..."

-- | Rewrite the RIFF and data chunk sizes to match the file. arecord writes
-- the header for the requested duration up front and does not correct it
-- when interrupted; whisper tolerates that, sherpa-onnx refuses the file.
fixWavHeader :: FilePath -> IO ()
fixWavHeader path = withBinaryFile path ReadWriteMode $ \h -> do
  size <- hFileSize h
  header <- BS.hGet h (fromIntegral (min 4096 size))
  case locateDataChunk header of
    Nothing -> return ()
    Just dataStart -> do
      let riffSize = fromIntegral size - 8
          dataSize = fromIntegral size - dataStart
          writeLE32 off v = hSeek h AbsoluteSeek (fromIntegral off) >> BS.hPut h (le32 v)
      when (le32At header 4 /= riffSize) $ writeLE32 (4 :: Int) riffSize
      when (le32At header (dataStart - 4) /= dataSize) $ writeLE32 (dataStart - 4) dataSize

-- | Offset of the first audio sample: walk the RIFF chunks to the data chunk
locateDataChunk :: BS.ByteString -> Maybe Int
locateDataChunk bs
  | BS.length bs < 12 || BS.take 4 bs /= "RIFF" || BS.take 4 (BS.drop 8 bs) /= "WAVE" = Nothing
  | otherwise = go 12
  where
    go off
      | off + 8 > BS.length bs = Nothing
      | BS.take 4 (BS.drop off bs) == "data" = Just (off + 8)
      | otherwise = let n = le32At bs (off + 4) in go (off + 8 + n + n `mod` 2)

le32 :: Int -> BS.ByteString
le32 v = BS.pack [fromIntegral ((v `shiftR` s) .&. 0xff) | s <- [0, 8, 16, 24]]

le32At :: BS.ByteString -> Int -> Int
le32At bs off = sum [fromIntegral (BS.index bs (off + i)) `shiftL` (8 * i) | i <- [0 .. 3]]

-- | Peak level of 16-bit PCM in dBFS: 0 is full scale, -96 is digital silence
peakDbfs :: FilePath -> IO (Maybe Double)
peakDbfs path = do
  contents <- BSL.readFile path
  let header = BSL.toStrict (BSL.take 4096 contents)
  return $ do
    dataStart <- locateDataChunk header
    let peak = peakSample (BSL.drop (fromIntegral dataStart) contents)
    Just (if peak == 0 then -96 else 20 * logBase 10 (fromIntegral peak / 32768))

-- | Below this peak a recording is treated as silent (an open mic in a quiet
-- room still peaks well above -40 dBFS)
silenceThresholdDbfs :: Double
silenceThresholdDbfs = -55

-- | Largest absolute sample of little-endian signed 16-bit PCM
peakSample :: BSL.ByteString -> Int
peakSample = BSL.foldlChunks chunkPeak 0
  where
    chunkPeak acc chunk = go acc 0
      where
        n = BS.length chunk
        go !m i
          | i + 1 >= n = m
          | otherwise =
              let lo = fromIntegral (BS.index chunk i) :: Int
                  hi = fromIntegral (BS.index chunk (i + 1)) :: Int
                  v = (hi `shiftL` 8) .|. lo
                  s = if v >= 32768 then v - 65536 else v
              in go (max m (abs s)) (i + 2)

-- | Wait for a specific key press
waitForKey :: Char -> TVar Bool -> IO ()
waitForKey expectedKey stopFlag = do
  -- Set terminal to raw mode (no buffering, no echo)
  hSetBuffering stdin NoBuffering
  hSetEcho stdin False

  let loop = do
        ready <- hReady stdin
        when ready $ do
          c <- getChar
          when (c == expectedKey) $ atomically $ writeTVar stopFlag True
        stopped <- readTVarIO stopFlag
        unless stopped $ do
          threadDelay 100000  -- 100ms
          loop

  loop `finally` do
    -- Restore terminal to normal mode
    hSetBuffering stdin LineBuffering
    hSetEcho stdin True

-- | Run a tool, treating a missing executable like a failed run
runTool :: FilePath -> [String] -> IO (ExitCode, String, String)
runTool cmd args =
  readProcessWithExitCode cmd args ""
    `catch` \(e :: IOException) -> return (ExitFailure 127, "", show e)

commandExists :: String -> IO Bool
commandExists cmd =
  (True <$ readProcessWithExitCode cmd ["--version"] "")
    `catch` \(_ :: IOException) -> return False
