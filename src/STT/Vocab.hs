{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module STT.Vocab
  ( loadVocabTerms
  , buildWhisperPrompt
  , promptTokenBudget
  , estimateTokens
  ) where

import Control.Exception (catch, IOException)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Text (Text)

-- | whisper caps --prompt at n_text_ctx/2 = 224 tokens; stay under it so
-- whisper never truncates for us (it would cut from the end, i.e. the vocab)
promptTokenBudget :: Int
promptTokenBudget = 200

-- | Rough token estimate without a tokenizer; ~4 chars/token is conservative
-- for the technical terms this is used on
estimateTokens :: Text -> Int
estimateTokens t = max 1 (T.length t `div` 4)

-- | Load technical terms from a vocabulary file: one term or phrase per
-- line, blank lines and '#' comments ignored. A missing or unreadable file
-- degrades to no vocabulary with a warning.
loadVocabTerms :: Maybe FilePath -> IO [Text]
loadVocabTerms Nothing = return []
loadVocabTerms (Just path) =
  (parseTerms <$> TIO.readFile path)
    `catch` \(e :: IOException) -> do
      putStrLn $ "Warning: could not read vocabulary file: " ++ show e
      return []
  where
    parseTerms = filter keep . map T.strip . T.lines
    keep line = not (T.null line) && not ("#" `T.isPrefixOf` line)

-- | Combine the session context and vocabulary terms into whisper's initial
-- prompt. The session context comes first and is never dropped; vocabulary
-- terms are appended whole until the token budget is reached.
buildWhisperPrompt :: [Text] -> Maybe Text -> Maybe Text
buildWhisperPrompt vocab sessionContext =
  case (contextPart, vocabPart) of
    (Nothing, Nothing) -> Nothing
    (Just c, Nothing) -> Just c
    (Nothing, Just v) -> Just v
    (Just c, Just v) -> Just (c <> " " <> v)
  where
    cleanContext = T.strip <$> sessionContext
    contextPart = case cleanContext of
      Just c | not (T.null c) -> Just ("Context: " <> ensureFullStop c)
      _ -> Nothing

    contextTokens = maybe 0 estimateTokens contextPart
    vocabBudget = promptTokenBudget - contextTokens

    vocabPart =
      let terms = takeWithinBudget vocabBudget (filter (not . T.null) (map T.strip vocab))
      in if null terms
           then Nothing
           else Just ("Vocabulary: " <> T.intercalate ", " terms <> ".")

    -- Greedily keep whole terms while the running estimate fits; the +3
    -- accounts for the "Vocabulary: " framing and separators
    takeWithinBudget budget = go (budget - 3)
      where
        go _ [] = []
        go remaining (t:ts)
          | cost <= remaining = t : go (remaining - cost) ts
          | otherwise = []
          where cost = estimateTokens t + 1

    ensureFullStop c
      | "." `T.isSuffixOf` c = c
      | otherwise = c <> "."
