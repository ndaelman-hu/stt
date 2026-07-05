{-# LANGUAGE ScopedTypeVariables #-}

module STT.Models
  ( ModelSpec(..)
  , knownModels
  , modelsDir
  , modelPath
  , isInstalled
  , downloadModel
  , formatSize
  ) where

import Control.Exception (catch, try, IOException, SomeException)
import Control.Monad (when)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.FilePath ((</>))
import System.Process (callProcess, readProcessWithExitCode)
import Text.Printf (printf)

-- | A curated, known-good instruct model in GGUF format. Any of these works
-- with the template-agnostic LLM layer; they differ in speed and quality.
data ModelSpec = ModelSpec
  { modelKey :: !String     -- ^ short stable identifier
  , modelLabel :: !String   -- ^ human-readable name
  , modelFile :: !FilePath  -- ^ file name under 'modelsDir'
  , modelUrl :: !String     -- ^ direct GGUF download URL
  , modelSizeMB :: !Int     -- ^ approximate download size
  , modelNotes :: !String   -- ^ one-line guidance for choosing
  } deriving (Show, Eq)

modelsDir :: FilePath
modelsDir = "llama.cpp/models"

-- | Curated models, ordered small to large. All are Q4_K_M quantizations
-- suitable for CPU inference.
knownModels :: [ModelSpec]
knownModels =
  [ ModelSpec
      { modelKey = "tinyllama-1.1b"
      , modelLabel = "TinyLlama 1.1B Chat"
      , modelFile = "tinyllama-1.1b-chat.gguf"
      , modelUrl = "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
      , modelSizeMB = 669
      , modelNotes = "fastest, lowest quality (setup.sh default)"
      }
  , ModelSpec
      { modelKey = "llama3.2-3b"
      , modelLabel = "Llama 3.2 3B Instruct"
      , modelFile = "llama-3.2-3b-instruct-q4_k_m.gguf"
      , modelUrl = "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
      , modelSizeMB = 2020
      , modelNotes = "fast with solid quality"
      }
  , ModelSpec
      { modelKey = "qwen3-4b"
      , modelLabel = "Qwen3 4B Instruct"
      , modelFile = "qwen3-4b-instruct-2507-q4_k_m.gguf"
      , modelUrl = "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
      , modelSizeMB = 2500
      , modelNotes = "recommended: strong multilingual quality at good speed"
      }
  , ModelSpec
      { modelKey = "qwen2.5-7b"
      , modelLabel = "Qwen2.5 7B Instruct"
      , modelFile = "qwen2.5-7b-instruct-q4_k_m.gguf"
      , modelUrl = "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
      , modelSizeMB = 4680
      , modelNotes = "best quality, noticeably slower on CPU"
      }
  ]

modelPath :: ModelSpec -> FilePath
modelPath spec = modelsDir </> modelFile spec

isInstalled :: ModelSpec -> IO Bool
isInstalled = doesFileExist . modelPath

-- | Human-readable size, e.g. "0.7 GB"
formatSize :: Int -> String
formatSize mb = printf "%.1f GB" (fromIntegral mb / 1024 :: Double)

-- | Download a model with wget or curl (whichever is available), showing
-- their progress output. Downloads go to a ".part" file first so an
-- interrupted transfer never leaves a half-written model behind.
downloadModel :: ModelSpec -> IO (Either String FilePath)
downloadModel spec = do
  createDirectoryIfMissing True modelsDir
  let dest = modelPath spec
      partial = dest ++ ".part"

  result <- try (fetch (modelUrl spec) partial)
  case result of
    Left (e :: SomeException) -> do
      partialExists <- doesFileExist partial
      when partialExists $ removeFile partial
      return $ Left $ "Download failed: " ++ show e
    Right () -> do
      renameFile partial dest
      return $ Right dest

-- | Fetch a URL, preferring wget for its resumable, progress-friendly output
fetch :: String -> FilePath -> IO ()
fetch url dest = do
  wgetAvailable <- commandExists "wget"
  if wgetAvailable
    then callProcess "wget" [url, "-O", dest]
    else callProcess "curl" ["-L", "--fail", "--progress-bar", "-o", dest, url]

commandExists :: String -> IO Bool
commandExists cmd =
  (True <$ readProcessWithExitCode cmd ["--version"] "")
    `catch` \(_ :: IOException) -> return False
