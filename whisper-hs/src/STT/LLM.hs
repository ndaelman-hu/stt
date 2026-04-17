{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module STT.LLM
  ( LLMResponse(..)
  , callLLM
  , cleanText
  , extractTodos
  ) where

import qualified Data.Text as T
import Data.Text (Text)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import Control.Exception (catch, IOException)

-- | Response from LLM
data LLMResponse = LLMResponse
  { responseText :: !Text
  , success :: !Bool
  , errorMsg :: !(Maybe String)
  } deriving (Show, Eq)

-- | Call llama.cpp with a prompt
callLLM
  :: FilePath  -- ^ Path to llama.cpp binary
  -> FilePath  -- ^ Path to model file
  -> Text      -- ^ System prompt
  -> Text      -- ^ User prompt
  -> IO (Either String Text)
callLLM llamaBin modelPath systemPrompt userPrompt = do
  let fullPrompt = formatPrompt systemPrompt userPrompt
      args = [ "-m", modelPath
             , "-p", T.unpack fullPrompt
             , "-n", "2048"  -- Max tokens
             , "--temp", "0.3"  -- Low temperature for consistency
             , "--top-p", "0.9"
             , "-c", "4096"  -- Context size
             , "--no-display-prompt"  -- Don't echo the prompt
             ]

  result <- (readProcessWithExitCode llamaBin args "" >>= \r -> case r of
    (ExitSuccess, stdout, _) -> return $ Right $ T.pack stdout
    (ExitFailure _, _, stderr) -> return $ Left $ "llama.cpp failed: " ++ stderr)
    `catch` \(e :: IOException) -> return $ Left $ "llama.cpp not found: " ++ show e

  case result of
    Right text -> return $ Right $ cleanLLMOutput text
    Left err -> return $ Left err

-- | Format prompt for TinyLlama-Chat format
formatPrompt :: Text -> Text -> Text
formatPrompt systemPrompt userPrompt =
  "<|system|>\n" <> systemPrompt <> "\n<|user|>\n" <> userPrompt <> "\n<|assistant|>\n"

-- | Clean LLM output (remove extra whitespace, trailing artifacts)
cleanLLMOutput :: Text -> Text
cleanLLMOutput = T.strip . T.unlines . filter (not . T.null) . map T.strip . T.lines

-- | Clean and fix grammar/punctuation in text
cleanText :: FilePath -> FilePath -> Text -> IO (Either String Text)
cleanText llamaBin modelPath rawText = do
  let systemPrompt = "You are a text correction assistant. Fix grammar, add proper punctuation and capitalization. Preserve the original meaning and technical terms. Output only the corrected text without any explanations."
      userPrompt = "Fix this transcription:\n\n" <> rawText

  callLLM llamaBin modelPath systemPrompt userPrompt

-- | Extract TODO items from meeting transcript
extractTodos :: FilePath -> FilePath -> Text -> IO (Either String Text)
extractTodos llamaBin modelPath transcript = do
  let systemPrompt = "You are a meeting assistant. Extract action items and TODOs from meeting transcripts. Format each as: '- [ ] [Person/Team]: [Task description] (Due: [date if mentioned])'. If no person is mentioned, use '- [ ] [Task description]'. Only output the TODO list."
      userPrompt = "Extract action items from this meeting:\n\n" <> transcript

  callLLM llamaBin modelPath systemPrompt userPrompt
