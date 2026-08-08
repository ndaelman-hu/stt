{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module STT.Diarize
  ( SpeakerInterval(..)
  , SpeakerTurn(..)
  , checkDiarizationAvailable
  , runDiarization
  , parseDiarizationOutput
  , assignSpeakers
  , renderSpeakerTurns
  , speakerLabels
  ) where

import Control.Exception (catch, IOException)
import Control.Monad (filterM)
import Data.List (maximumBy, minimumBy, nub)
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import qualified Data.Text as T
import Data.Text (Text)
import System.Directory (doesFileExist)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

import STT.Config (AppConfig(..))
import STT.Whisper (TranscriptSegment(..))

-- | A time interval attributed to one speaker by the diarization backend
data SpeakerInterval = SpeakerInterval
  { siStart :: !Double  -- ^ seconds
  , siEnd :: !Double    -- ^ seconds
  , siSpeaker :: !Text  -- ^ raw label, e.g. "speaker_00"
  } deriving (Show, Eq)

-- | A run of consecutive transcript segments spoken by the same speaker
data SpeakerTurn = SpeakerTurn
  { stSpeaker :: !Text  -- ^ normalized label, e.g. "Speaker 1"
  , stStart :: !Double  -- ^ seconds
  , stEnd :: !Double    -- ^ seconds
  , stText :: !Text
  } deriving (Show, Eq)

-- | Verify the sherpa-onnx binary and models are installed
checkDiarizationAvailable :: AppConfig -> IO (Either String ())
checkDiarizationAvailable config = do
  let paths = [ diarizeBinaryPath config
              , diarizeSegModelPath config
              , diarizeEmbModelPath config
              ]
  missing <- filterM (fmap not . doesFileExist) paths
  return $ if null missing
    then Right ()
    else Left $ "Speaker diarization is not set up. Missing:\n"
             ++ unlines (map ("  - " ++) missing)
             ++ "Run ./setup.sh to build sherpa-onnx and download the diarization models."

-- | Run sherpa-onnx speaker diarization on a WAV file (must be 16 kHz)
runDiarization :: AppConfig -> FilePath -> IO (Either String [SpeakerInterval])
runDiarization config audioPath = do
  let clusteringArg = case diarizeNumSpeakers config of
        Just n -> "--clustering.num-clusters=" ++ show n
        Nothing -> "--clustering.cluster-threshold=" ++ show (diarizeClusterThreshold config)
      args = [ "--segmentation.pyannote-model=" ++ diarizeSegModelPath config
             , "--embedding.model=" ++ diarizeEmbModelPath config
             , clusteringArg
             , audioPath
             ]

  result <- (readProcessWithExitCode (diarizeBinaryPath config) args "" >>= \case
    (ExitSuccess, stdout, _) -> return $ Right $ parseDiarizationOutput (T.pack stdout)
    (ExitFailure _, _, stderr) -> return $ Left $ "sherpa-onnx failed: " ++ stderr)
    `catch` \(e :: IOException) -> return $ Left $ "sherpa-onnx not found: " ++ show e

  case result of
    Right [] -> return $ Left "sherpa-onnx produced no speaker segments"
    other -> return other

-- | Parse diarization stdout lines of the form "0.318 -- 6.865 speaker_00",
-- skipping any log or progress lines that don't match
parseDiarizationOutput :: Text -> [SpeakerInterval]
parseDiarizationOutput = concatMap parseLine . T.lines
  where
    parseLine line = case T.words line of
      [startTxt, "--", endTxt, speaker] ->
        case (readMaybe (T.unpack startTxt), readMaybe (T.unpack endTxt)) of
          (Just start, Just end) -> [SpeakerInterval start end speaker]
          _ -> []
      _ -> []

-- | Assign a speaker to each transcript segment by maximal temporal overlap
-- with the diarization intervals, then merge consecutive same-speaker
-- segments into turns. Raw labels are normalized to "Speaker 1", "Speaker 2",
-- ... in order of first appearance.
assignSpeakers :: [SpeakerInterval] -> [TranscriptSegment] -> [SpeakerTurn]
assignSpeakers intervals segments =
  mergeTurns $ normalizeLabels $ go Nothing segments
  where
    go _ [] = []
    go prevSpeaker (seg:rest) =
      let speaker = case (segmentFromMs seg, segmentToMs seg) of
            (Just fromMs, Just toMs) ->
              pickSpeaker (fromIntegral fromMs / 1000) (fromIntegral toMs / 1000)
            -- No timestamps: stay with the current speaker
            _ -> fromMaybe fallbackSpeaker prevSpeaker
          turn = (speaker, seg)
      in turn : go (Just speaker) rest

    fallbackSpeaker = case intervals of
      [] -> "speaker_00"
      (i:_) -> siSpeaker i

    pickSpeaker segStart segEnd =
      let bySpeaker = [ (spk, totalOverlap spk) | spk <- nub (map siSpeaker intervals) ]
          totalOverlap spk = sum [ overlap i | i <- intervals, siSpeaker i == spk ]
          overlap i = max 0 (min segEnd (siEnd i) - max segStart (siStart i))
          segMid = (segStart + segEnd) / 2
          nearest = minimumBy (comparing (\i -> abs ((siStart i + siEnd i) / 2 - segMid))) intervals
      in case bySpeaker of
           [] -> fallbackSpeaker
           _ | all ((<= 0) . snd) bySpeaker -> siSpeaker nearest
             | otherwise -> fst (maximumBy (comparing snd) bySpeaker)

    normalizeLabels labeled =
      let order = nub (map fst labeled)
          rename raw = "Speaker " <> T.pack (show (1 + fromMaybe 0 (lookup raw (zip order [0 :: Int ..]))))
      in [ (rename raw, seg) | (raw, seg) <- labeled ]

    mergeTurns [] = []
    mergeTurns ((speaker, seg):rest) =
      let (same, others) = span ((== speaker) . fst) rest
          run = seg : map snd same
          startS = maybe 0 ((/ 1000) . fromIntegral) (segmentFromMs seg)
          endS = maybe startS ((/ 1000) . fromIntegral) (segmentToMs (last run))
          text = T.strip $ T.intercalate " " (map (T.strip . segmentText) run)
      in SpeakerTurn speaker startS endS text : mergeTurns others

-- | Normalized speaker labels present in a set of turns, in order of appearance
speakerLabels :: [SpeakerTurn] -> [Text]
speakerLabels = nub . map stSpeaker

-- | Render turns as "<role-or-label>: <text>" paragraphs; the first argument
-- maps speaker labels to user-confirmed roles
renderSpeakerTurns :: [(Text, Text)] -> [SpeakerTurn] -> Text
renderSpeakerTurns roleMap turns =
  T.intercalate "\n\n" [ label (stSpeaker t) <> ": " <> stText t | t <- turns ]
  where
    label spk = fromMaybe spk (lookup spk roleMap)
