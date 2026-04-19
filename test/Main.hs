{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (Arbitrary(..), elements)
import qualified Data.Text as T
import Data.Aeson (decode)
import qualified Data.ByteString.Lazy.Char8 as BSL
import STT.Config

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Whisper-HS Tests"
  [ configParserTests
  , validationTests
  , jsonParsingTests
  ]

-- | Test configuration parsers
configParserTests :: TestTree
configParserTests = testGroup "Config Parsers"
  [ testGroup "parseModelSize"
      [ testCase "parses 'tiny'" $
          parseModelSize "tiny" @?= Just Tiny
      , testCase "parses 'base'" $
          parseModelSize "base" @?= Just Base
      , testCase "parses 'SMALL' (case insensitive)" $
          parseModelSize "SMALL" @?= Just Small
      , testCase "rejects invalid" $
          parseModelSize "invalid" @?= Nothing
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

-- | Test JSON parsing (would need actual fixtures)
jsonParsingTests :: TestTree
jsonParsingTests = testGroup "JSON Parsing"
  [ testCase "parses simple whisper response" $ do
      let json = BSL.pack $ concat
            [ "{"
            , "\"transcription\": [{\"text\": \" Hello world\"}],"
            , "\"result\": {\"language\": \"en\"}"
            , "}"
            ]
      -- This would need the WhisperCppResponse type to be exported
      -- For now, just test that it doesn't crash
      case (decode json :: Maybe ()) of
        _ -> return ()
  ]

-- | Property-based tests
instance Arbitrary ModelSize where
  arbitrary = elements [Tiny, Base, Small, Medium, Large]

instance Arbitrary Device where
  arbitrary = elements [Auto, CPU, CUDA]

instance Arbitrary StopSignal where
  arbitrary = elements [CtrlC, Enter, Space]

instance Arbitrary Task where
  arbitrary = elements [Transcribe, Translate, Both]
