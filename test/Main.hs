{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (Arbitrary(..), elements)
import Control.Exception (finally)
import qualified Data.Text as T
import Data.Aeson (decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.List (nub)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (openBinaryTempFile, hClose)
import STT.Audio (fixWavHeader, locateDataChunk, peakDbfs)
import STT.Config
import STT.Diarize
import STT.LLM (extractReply, parseRoleSuggestions)
import qualified STT.Models as Models
import STT.Vocab
import STT.Whisper (WhisperCppResponse(..), TranscriptSegment(..), ResultInfo(..))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Whisper-HS Tests"
  [ configParserTests
  , validationTests
  , jsonParsingTests
  , modelRegistryTests
  , extractReplyTests
  , diarizationTests
  , roleSuggestionTests
  , vocabTests
  , audioTests
  ]

-- | WAV header repair and level measurement
audioTests :: TestTree
audioTests = testGroup "Audio / WAV"
  [ testCase "locateDataChunk finds the canonical 44-byte header" $
      locateDataChunk (wavHeader 1000) @?= Just 44
  , testCase "locateDataChunk skips extra chunks" $
      locateDataChunk (BS.concat ["RIFF", le32 100, "WAVE", "LIST", le32 4, "abcd", "data", le32 0])
        @?= Just 32
  , testCase "locateDataChunk rejects non-WAV data" $
      locateDataChunk "not a wav file at all" @?= Nothing
  , testCase "fixWavHeader repairs the sizes of an interrupted recording" $
      withTempWav (wavHeader 172800000 <> BS.replicate 8 0) $ \path -> do
        fixWavHeader path
        fixed <- BS.readFile path
        BS.take 4 (BS.drop 4 fixed) @?= le32 (BS.length fixed - 8)
        BS.take 4 (BS.drop 40 fixed) @?= le32 8
  , testCase "peakDbfs reports digital silence as -96 dBFS" $
      withTempWav (wavHeader 8 <> BS.replicate 8 0) $ \path ->
        peakDbfs path >>= (@?= Just (-96))
  , testCase "peakDbfs reports a half-scale sample near -6 dBFS" $
      withTempWav (wavHeader 4 <> BS.pack [0, 0, 0, 0x40]) $ \path -> do
        level <- peakDbfs path
        case level of
          Just db -> assertBool ("got " ++ show db) (abs (db + 6.02) < 0.1)
          Nothing -> assertFailure "no level measured"
  ]

-- | A 16-bit mono 16 kHz WAV header claiming the given data size
wavHeader :: Int -> BS.ByteString
wavHeader dataSize = BS.concat
  [ "RIFF", le32 (36 + dataSize), "WAVE"
  , "fmt ", le32 16, le16 1, le16 1, le32 16000, le32 32000, le16 2, le16 16
  , "data", le32 dataSize
  ]

le32 :: Int -> BS.ByteString
le32 v = BS.pack [fromIntegral (v `div` 256 ^ i `mod` 256) | i <- [0 .. 3 :: Int]]

le16 :: Int -> BS.ByteString
le16 v = BS.pack [fromIntegral (v `div` 256 ^ i `mod` 256) | i <- [0 .. 1 :: Int]]

withTempWav :: BS.ByteString -> (FilePath -> IO a) -> IO a
withTempWav bytes action = do
  dir <- getTemporaryDirectory
  (path, h) <- openBinaryTempFile dir "whisper-hs-test.wav"
  BS.hPut h bytes
  hClose h
  action path `finally` removeFile path

-- | Test configuration parsers
configParserTests :: TestTree
configParserTests = testGroup "Config Parsers"
  [ testGroup "parseWhisperModel"
      [ testCase "accepts a bare model name" $
          parseWhisperModel "base" @?= Just "base"
      , testCase "lower-cases names (release files are lower-case)" $
          parseWhisperModel "Large-V3-Turbo" @?= Just "large-v3-turbo"
      , testCase "accepts quantization suffixes" $
          parseWhisperModel "large-v3-turbo-q5_0" @?= Just "large-v3-turbo-q5_0"
      , testCase "keeps paths verbatim, including case" $
          parseWhisperModel "/Models/My-Model.bin" @?= Just "/Models/My-Model.bin"
      , testCase "rejects empty" $
          parseWhisperModel "" @?= Nothing
      , testCase "rejects whitespace" $
          parseWhisperModel "large v3" @?= Nothing
      ]

  , testGroup "isLanguageCode"
      [ testCase "accepts ISO codes" $
          assertBool "en, de, yue" (all isLanguageCode ["en", "de", "yue"])
      , testCase "accepts whisper's English names" $
          assertBool "english" (isLanguageCode "english")
      , testCase "rejects glibc locale strings" $
          assertBool "en_US:en, de_DE.UTF-8, C" (not (any isLanguageCode ["en_US:en", "de_DE.UTF-8", "C"]))
      , testCase "rejects empty" $
          isLanguageCode "" @?= False
      ]

  , testGroup "parseDevice"
      [ testCase "parses 'auto'" $
          parseDevice "auto" @?= Just Auto
      , testCase "parses 'CPU' (case insensitive)" $
          parseDevice "CPU" @?= Just CPU
      , testCase "parses 'cuda'" $
          parseDevice "cuda" @?= Just CUDA
      , testCase "rejects invalid" $
          parseDevice "invalid" @?= Nothing
      ]

  , testGroup "parseStopSignal"
      [ testCase "parses 'ctrl_c'" $
          parseStopSignal "ctrl_c" @?= Just CtrlC
      , testCase "parses 'ENTER' (case insensitive)" $
          parseStopSignal "ENTER" @?= Just Enter
      , testCase "parses 'space'" $
          parseStopSignal "space" @?= Just Space
      ]

  , testGroup "parseTask"
      [ testCase "parses 'transcribe'" $
          parseTask "transcribe" @?= Just Transcribe
      , testCase "parses 'TRANSLATE' (case insensitive)" $
          parseTask "TRANSLATE" @?= Just Translate
      , testCase "parses 'both'" $
          parseTask "both" @?= Just Both
      ]

  , testGroup "parseDouble"
      [ testCase "parses '0.5'" $
          parseDouble "0.5" @?= Just 0.5
      , testCase "rejects garbage" $
          parseDouble "high" @?= Nothing
      ]

  , testGroup "parsePositiveInt"
      [ testCase "parses '2'" $
          parsePositiveInt "2" @?= Just 2
      , testCase "rejects 0" $
          parsePositiveInt "0" @?= Nothing
      , testCase "rejects negative" $
          parsePositiveInt "-3" @?= Nothing
      ]

  , testGroup "parseBool"
      [ testCase "parses 'true'" $
          parseBool "true" @?= Just True
      , testCase "parses 'FALSE' (case insensitive)" $
          parseBool "FALSE" @?= Just False
      , testCase "parses '1'" $
          parseBool "1" @?= Just True
      , testCase "parses '0'" $
          parseBool "0" @?= Just False
      , testCase "parses 'yes'" $
          parseBool "yes" @?= Just True
      , testCase "parses 'no'" $
          parseBool "no" @?= Just False
      ]
  ]

-- | Test validation functions
validationTests :: TestTree
validationTests = testGroup "Validation"
  [ testGroup "mkSampleRate"
      [ testCase "accepts 16000" $
          mkSampleRate 16000 @?= Just (SampleRate 16000)
      , testCase "accepts 8000 (minimum)" $
          mkSampleRate 8000 @?= Just (SampleRate 8000)
      , testCase "accepts 48000 (maximum)" $
          mkSampleRate 48000 @?= Just (SampleRate 48000)
      , testCase "rejects 7999 (too low)" $
          mkSampleRate 7999 @?= Nothing
      , testCase "rejects 48001 (too high)" $
          mkSampleRate 48001 @?= Nothing
      ]

  , testGroup "mkMinutes"
      [ testCase "accepts 90" $
          mkMinutes 90 @?= Just (Minutes 90)
      , testCase "accepts 1 (minimum)" $
          mkMinutes 1 @?= Just (Minutes 1)
      , testCase "accepts 300 (maximum)" $
          mkMinutes 300 @?= Just (Minutes 300)
      , testCase "rejects 0 (too low)" $
          mkMinutes 0 @?= Nothing
      , testCase "rejects 301 (too high)" $
          mkMinutes 301 @?= Nothing
      ]
  ]

-- | Test JSON parsing of whisper.cpp output
jsonParsingTests :: TestTree
jsonParsingTests = testGroup "JSON Parsing"
  [ testCase "parses segment without offsets" $ do
      let json = BSL.pack $ concat
            [ "{"
            , "\"transcription\": [{\"text\": \" Hello world\"}],"
            , "\"result\": {\"language\": \"en\"}"
            , "}"
            ]
      case decode json of
        Nothing -> assertFailure "failed to decode response"
        Just resp -> do
          map segmentText (transcription resp) @?= [" Hello world"]
          map segmentFromMs (transcription resp) @?= [Nothing]
          fmap detectedLanguage (resultInfo resp) @?= Just (Just "en")

  , testCase "parses whisper-cli fixture with offsets" $ do
      json <- BSL.readFile "test/fixtures/whisper-response.json"
      case decode json of
        Nothing -> assertFailure "failed to decode fixture"
        Just resp -> do
          let segments = transcription resp
          length segments @?= 1
          segmentFromMs (head segments) @?= Just 0
          segmentToMs (head segments) @?= Just 10500
  ]

-- | Test diarization output parsing and speaker alignment
diarizationTests :: TestTree
diarizationTests = testGroup "Diarization"
  [ testGroup "parseDiarizationOutput"
      [ testCase "parses well-formed lines" $
          parseDiarizationOutput "0.318 -- 6.865 speaker_00\n7.010 -- 12.3 speaker_01\n"
            @?= [ SpeakerInterval 0.318 6.865 "speaker_00"
                , SpeakerInterval 7.010 12.3 "speaker_01"
                ]
      , testCase "skips log noise" $
          parseDiarizationOutput "Loading model...\n0.5 -- 2.0 speaker_00\nDone in 3s\n"
            @?= [SpeakerInterval 0.5 2.0 "speaker_00"]
      , testCase "skips lines with unreadable times" $
          parseDiarizationOutput "abc -- def speaker_00\n" @?= []
      , testCase "handles empty input" $
          parseDiarizationOutput "" @?= []
      ]

  , testGroup "assignSpeakers"
      [ testCase "assigns by overlap and merges consecutive turns" $ do
          let intervals = [ SpeakerInterval 0 5 "speaker_00"
                          , SpeakerInterval 5 10 "speaker_01"
                          ]
              segments = [ seg " Hi." 0 2000
                         , seg " How are you?" 2000 4500
                         , seg " Fine, thanks." 5500 9000
                         ]
          assignSpeakers intervals segments
            @?= [ SpeakerTurn "Speaker 1" 0 4.5 "Hi. How are you?"
                , SpeakerTurn "Speaker 2" 5.5 9 "Fine, thanks."
                ]
      , testCase "straddling segment goes to larger overlap" $ do
          let intervals = [ SpeakerInterval 0 3 "speaker_00"
                          , SpeakerInterval 3 10 "speaker_01"
                          ]
              segments = [seg " Borderline." 2000 8000]
          map stSpeaker (assignSpeakers intervals segments) @?= ["Speaker 1"]
            -- speaker_01 overlaps 5s vs 1s for speaker_00, but labels are
            -- normalized by first appearance, so speaker_01 becomes Speaker 1
      , testCase "segment in a silence gap uses nearest interval" $ do
          let intervals = [ SpeakerInterval 0 2 "speaker_00"
                          , SpeakerInterval 8 10 "speaker_01"
                          ]
              segments = [seg " Lost in the gap." 6500 7500]
          map stSpeaker (assignSpeakers intervals segments) @?= ["Speaker 1"]
      , testCase "no intervals yields a single speaker" $ do
          let segments = [ seg " One." 0 1000
                         , seg " Two." 1000 2000
                         ]
          assignSpeakers [] segments
            @?= [SpeakerTurn "Speaker 1" 0 2 "One. Two."]
      , testCase "segments without offsets inherit the previous speaker" $ do
          let intervals = [SpeakerInterval 0 5 "speaker_00"]
              segments = [ seg " Timed." 0 2000
                         , TranscriptSegment " Untimed." Nothing Nothing
                         ]
          map stSpeaker (assignSpeakers intervals segments) @?= ["Speaker 1"]
      ]

  , testGroup "smoothShortTurns"
      [ testCase "a short turn between two turns of one speaker is absorbed" $
          map stSpeaker (smoothShortTurns 1.5
            [ SpeakerTurn "A" 0 10 "Long."
            , SpeakerTurn "B" 10 10.8 "Glitch."
            , SpeakerTurn "A" 10.8 20 "Long again."
            ]) @?= ["A", "A", "A"]
      , testCase "a short opening turn joins the long turn after it" $
          map stSpeaker (smoothShortTurns 1.5
            [ SpeakerTurn "B" 0 0.9 "Uh."
            , SpeakerTurn "A" 0.9 12 "Long."
            ]) @?= ["A", "A"]
      , testCase "a short turn between two different speakers is kept" $
          map stSpeaker (smoothShortTurns 1.5
            [ SpeakerTurn "A" 0 10 "Long."
            , SpeakerTurn "C" 10 10.8 "Yes."
            , SpeakerTurn "B" 10.8 20 "Long."
            ]) @?= ["A", "C", "B"]
      , testCase "long turns are untouched" $
          map stSpeaker (smoothShortTurns 1.5
            [ SpeakerTurn "A" 0 5 "One.", SpeakerTurn "B" 5 10 "Two.", SpeakerTurn "A" 10 15 "Three." ])
            @?= ["A", "B", "A"]
      , testCase "assignSpeakers merges a glitch so the phantom speaker disappears" $ do
          let intervals = [ SpeakerInterval 0 10 "speaker_00"
                          , SpeakerInterval 10 10.8 "speaker_01"
                          , SpeakerInterval 10.8 20 "speaker_00"
                          ]
              segments = [ seg " First part." 0 10000
                         , seg " glitch" 10000 10800
                         , seg " second part." 10800 20000
                         ]
          assignSpeakers intervals segments
            @?= [SpeakerTurn "Speaker 1" 0 20 "First part. glitch second part."]
      ]

  , testGroup "renderSpeakerTurns"
      [ testCase "applies confirmed roles, keeping labels without one" $ do
          let turns = [ SpeakerTurn "Speaker 1" 0 5 "Hello."
                      , SpeakerTurn "Speaker 2" 5 9 "Hi there."
                      ]
          renderSpeakerTurns [("Speaker 1", "Interviewer")] turns
            @?= "Interviewer: Hello.\n\nSpeaker 2: Hi there."
      ]
  ]
  where
    seg t fromMs toMs = TranscriptSegment t (Just fromMs) (Just toMs)

-- | Test vocabulary loading and whisper prompt construction
vocabTests :: TestTree
vocabTests = testGroup "Vocabulary"
  [ testGroup "loadVocabTerms"
      [ testCase "returns nothing when no file configured" $ do
          terms <- loadVocabTerms Nothing
          terms @?= []
      , testCase "missing file degrades to no vocabulary" $ do
          terms <- loadVocabTerms (Just "test/fixtures/does-not-exist.txt")
          terms @?= []
      , testCase "parses example file, skipping comments and blanks" $ do
          terms <- loadVocabTerms (Just "vocab.example.txt")
          length terms @?= 12
          head terms @?= "whisper.cpp"
      ]

  , testGroup "buildWhisperPrompt"
      [ testCase "empty inputs yield no prompt" $
          buildWhisperPrompt [] Nothing @?= Nothing
      , testCase "blank context yields no prompt" $
          buildWhisperPrompt [] (Just "   ") @?= Nothing
      , testCase "context only" $
          buildWhisperPrompt [] (Just "A talk about GGML quantization")
            @?= Just "Context: A talk about GGML quantization."
      , testCase "vocabulary only" $
          buildWhisperPrompt ["GGML", "GGUF"] Nothing
            @?= Just "Vocabulary: GGML, GGUF."
      , testCase "context precedes vocabulary" $
          buildWhisperPrompt ["GGML"] (Just "Weekly sync.")
            @?= Just "Context: Weekly sync. Vocabulary: GGML."
      , testCase "stays within the token budget without splitting terms" $ do
          let longTerm = T.replicate 40 "x"  -- ~10 tokens each
              manyTerms = replicate 100 longTerm
              prompt = buildWhisperPrompt manyTerms Nothing
          case prompt of
            Nothing -> assertFailure "expected a prompt"
            Just p -> do
              assertBool "within budget" (estimateTokens p <= promptTokenBudget)
              assertBool "keeps whole terms" (T.isSuffixOf (longTerm <> ".") p)
      , testCase "session context survives even with a huge vocabulary" $ do
          let manyTerms = replicate 500 (T.replicate 40 "x")
              prompt = buildWhisperPrompt manyTerms (Just "The important context")
          case prompt of
            Nothing -> assertFailure "expected a prompt"
            Just p -> assertBool "context kept" (T.isPrefixOf "Context: The important context." p)
      ]
  ]

-- | Test lenient parsing of LLM role suggestions
roleSuggestionTests :: TestTree
roleSuggestionTests = testGroup "Role Suggestions"
  [ testCase "extracts known speakers from noisy output" $
      parseRoleSuggestions ["Speaker 1", "Speaker 2"]
        "Sure! Here are the roles:\nSpeaker 1: Alice\n\nSpeaker 2: Interviewer\nHope that helps!"
        @?= [("Speaker 1", "Alice"), ("Speaker 2", "Interviewer")]
  , testCase "ignores unknown speaker labels" $
      parseRoleSuggestions ["Speaker 1"] "Speaker 3: Ghost\nSpeaker 1: Bob"
        @?= [("Speaker 1", "Bob")]
  , testCase "drops empty roles" $
      parseRoleSuggestions ["Speaker 1"] "Speaker 1:  " @?= []
  , testCase "drops sentence-length roles (echoed transcript)" $
      parseRoleSuggestions ["Speaker 1"]
        "Speaker 1: And so my fellow Americans ask not what your country can do for you."
        @?= []
  , testCase "strips trailing punctuation from roles" $
      parseRoleSuggestions ["Speaker 1"] "Speaker 1: Project lead." @?= [("Speaker 1", "Project lead")]
  ]

-- | Sanity checks on the curated LLM registry
modelRegistryTests :: TestTree
modelRegistryTests = testGroup "Model Registry"
  [ testCase "keys are unique" $
      length (nub (map Models.modelKey Models.knownModels))
        @?= length Models.knownModels
  , testCase "file names are unique" $
      length (nub (map Models.modelFile Models.knownModels))
        @?= length Models.knownModels
  , testCase "URLs are https" $
      assertBool "all https" (all (("https://" ==) . take 8 . Models.modelUrl) Models.knownModels)
  , testCase "sizes are positive" $
      assertBool "positive sizes" (all ((> 0) . Models.modelSizeMB) Models.knownModels)
  , testCase "default setup model is in the registry" $
      assertBool "tinyllama present"
        (any (("tinyllama-1.1b-chat.gguf" ==) . Models.modelFile) Models.knownModels)
  , testCase "whisper keys are unique" $
      length (nub (map Models.modelKey Models.knownWhisperModels))
        @?= length Models.knownWhisperModels
  , testCase "whisper URLs are https" $
      assertBool "all https"
        (all (("https://" ==) . take 8 . Models.modelUrl) Models.knownWhisperModels)
  , testCase "whisper names resolve to their registry files" $
      assertBool "resolveWhisperModel matches modelPath"
        (all (\m -> Models.resolveWhisperModel (Models.modelKey m) == Models.modelPath m)
             Models.knownWhisperModels)
  , testCase "default whisper model is in the registry" $
      assertBool "base present" (any (("base" ==) . Models.modelKey) Models.knownWhisperModels)
  , testCase "resolveWhisperModel keeps explicit paths" $
      Models.resolveWhisperModel "/tmp/custom.bin" @?= "/tmp/custom.bin"
  , testCase "resolveWhisperModel treats .bin names as files" $
      Models.resolveWhisperModel "ggml-custom.bin" @?= "ggml-custom.bin"
  ]

-- | Test extraction of the assistant reply from llama-cli stdout
extractReplyTests :: TestTree
extractReplyTests = testGroup "extractReply"
  [ testCase "single-line prompt" $
      extractReply "What color is the sky?"
        (T.unlines
          [ "build      : b8831"
          , "available commands:"
          , "  /exit or Ctrl+C     stop or exit"
          , ""
          , "> What color is the sky?"
          , ""
          , "Blue."
          , ""
          , "[ Prompt: 159,6 t/s | Generation: 51,5 t/s ]"
          , ""
          , "Exiting..."
          ])
        @?= "Blue."
  , testCase "multi-line prompt echo is skipped" $
      extractReply "fix this:\n\nme and him goes\nthey was happy"
        (T.unlines
          [ "banner"
          , "> fix this:"
          , ""
          , "me and him goes"
          , "they was happy"
          , ""
          , "He and I went."
          , "They were happy."
          , ""
          , "[ Prompt: 102,8 t/s ]"
          ])
        @?= "He and I went.\nThey were happy."
  , testCase "no echo marker falls back to trailer-stripped output" $
      extractReply "prompt" "Some reply.\nExiting...\n" @?= "Some reply."
  ]

-- | Property-based tests
instance Arbitrary Device where
  arbitrary = elements [Auto, CPU, CUDA]

instance Arbitrary StopSignal where
  arbitrary = elements [CtrlC, Enter, Space]

instance Arbitrary Task where
  arbitrary = elements [Transcribe, Translate, Both]
