{-# LANGUAGE OverloadedStrings #-}

module STT.PostProcess
  ( ProcessingOptions(..)
  , ProcessedResult(..)
  , processTranscription
  , cleanTranscriptionFile
  , extractTodosFromFile
  ) where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Text (Text)
import Data.Maybe (fromMaybe)
import System.Directory (doesFileExist)
import qualified STT.LLM as LLM
import STT.Config (AppConfig(..))
import qualified STT.Config as Config

-- | Options for post-processing
data ProcessingOptions = ProcessingOptions
  { cleanText :: !Bool
  , extractTodos :: !Bool
  , llamaBinaryPath :: !FilePath
  , modelPath :: !FilePath
  } deriving (Show, Eq)

-- | Result of processing
data ProcessedResult = ProcessedResult
  { originalText :: !Text
  , cleanedText :: !(Maybe Text)
  , todos :: !(Maybe Text)
  , processingErrors :: ![String]
  } deriving (Show, Eq)

-- | Process transcription with optional cleaning and TODO extraction
processTranscription :: ProcessingOptions -> Text -> IO ProcessedResult
processTranscription opts original = do
  -- Clean text if requested
  (cleaned, cleanErr) <- if cleanText opts
    then do
      result <- LLM.cleanText (llamaBinaryPath opts) (modelPath opts) original
      case result of
        Right txt -> return (Just txt, [])
        Left err -> return (Nothing, ["Text cleaning failed: " ++ err])
    else return (Nothing, [])

  -- Extract TODOs if requested
  (todoList, todoErr) <- if extractTodos opts
    then do
      -- Use cleaned text if available, otherwise original
      let sourceText = fromMaybe original cleaned
      result <- LLM.extractTodos (llamaBinaryPath opts) (modelPath opts) sourceText
      case result of
        Right txt -> return (Just txt, [])
        Left err -> return (Nothing, ["TODO extraction failed: " ++ err])
    else return (Nothing, [])

  return ProcessedResult
    { originalText = original
    , cleanedText = cleaned
    , todos = todoList
    , processingErrors = cleanErr ++ todoErr
    }

-- | Clean a transcription file
cleanTranscriptionFile :: FilePath -> FilePath -> FilePath -> IO (Either String Text)
cleanTranscriptionFile llamaBin modelPath filePath = do
  exists <- doesFileExist filePath
  if not exists
    then return $ Left $ "File not found: " ++ filePath
    else do
      content <- TIO.readFile filePath
      LLM.cleanText llamaBin modelPath content

-- | Extract TODOs from a transcription file
extractTodosFromFile :: FilePath -> FilePath -> FilePath -> IO (Either String Text)
extractTodosFromFile llamaBin modelPath filePath = do
  exists <- doesFileExist filePath
  if not exists
    then return $ Left $ "File not found: " ++ filePath
    else do
      content <- TIO.readFile filePath
      LLM.extractTodos llamaBin modelPath content
