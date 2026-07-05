{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module STT.LLM
  ( LLMResponse(..)
  , callLLM
  , extractReply
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

-- | Call llama.cpp with a prompt. The chat template embedded in the GGUF is
-- applied by llama-cli itself (conversation mode), so any instruct model
-- works here — nothing is hardcoded to a particular model family.
callLLM
  :: FilePath  -- ^ Path to llama.cpp binary
  -> FilePath  -- ^ Path to model file
  -> Text      -- ^ System prompt
  -> Text      -- ^ User prompt
  -> IO (Either String Text)
callLLM llamaBin modelPath systemPrompt userPrompt = do
  let args = [ "-m", modelPath
             , "-sys", T.unpack systemPrompt
             , "-p", T.unpack userPrompt
             , "-st"  -- single conversation turn, then exit
             , "--simple-io"  -- no spinner/ANSI escapes in subprocess output
             , "-n", "2048"  -- Max tokens
             , "--temp", "0.3"  -- Low temperature for consistency
             , "--top-p", "0.9"
             , "-c", "4096"  -- Context size
             ]

  result <- (readProcessWithExitCode llamaBin args "" >>= \case
    (ExitSuccess, stdout, _) -> return $ Right $ T.pack stdout
    (ExitFailure _, _, stderr) -> return $ Left $ "llama.cpp failed: " ++ stderr)
    `catch` \(e :: IOException) -> return $ Left $ "llama.cpp not found: " ++ show e

  case result of
    Right text -> return $ Right $ extractReply userPrompt text
    Left err -> return $ Left err

-- | Extract the assistant reply from llama-cli's conversation-mode stdout.
-- The stream is: banner noise, the user prompt echoed after a "> " marker,
-- the reply, then a "[ Prompt: ... ]" stats trailer and "Exiting...".
extractReply :: Text -> Text -> Text
extractReply userPrompt out = cleanLLMOutput (T.unlines reply)
  where
    allLines = T.lines out
    promptLineCount = length (T.lines userPrompt)
    afterEcho = case break ("> " `T.isPrefixOf`) allLines of
      -- No echo marker (unexpected build): keep everything before the trailer
      (_, []) -> allLines
      -- The echo spans the "> " line plus the remaining prompt lines
      (_, _echoStart:rest) -> drop (promptLineCount - 1) rest
    reply = takeWhile (not . isTrailer) afterEcho
    isTrailer line =
      "[ Prompt:" `T.isPrefixOf` T.strip line || T.strip line == "Exiting..."

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
