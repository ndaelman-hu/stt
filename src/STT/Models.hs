{-# LANGUAGE ScopedTypeVariables #-}

-- | Curated model registries for the two engines the app drives, plus
-- shared install/download helpers. Whisper models are GGML files from
-- the whisper.cpp release on Hugging Face; LLM models are instruct GGUFs.
module STT.Models
  ( ModelSpec(..)
  , knownModels
  , knownWhisperModels
  , modelsDir
  , whisperModelsDir
  , modelPath
  , resolveWhisperModel
  , isInstalled
  , downloadModel
  , formatSize
  ) where

import Control.Exception (catch, try, IOException, SomeException)
import Control.Monad (when)
import Data.List (isSuffixOf)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.FilePath ((</>))
import System.Process (callProcess, readProcessWithExitCode)
import Text.Printf (printf)

-- | A curated, known-good model. Whisper entries are GGML files that
-- whisper-cli loads directly; LLM entries are instruct GGUFs that work
-- with the template-agnostic LLM layer. Within each registry the entries
-- differ in speed and quality.
data ModelSpec = ModelSpec
  { modelKey :: !String     -- ^ short stable identifier
  , modelLabel :: !String   -- ^ human-readable name
  , modelDir :: !FilePath   -- ^ directory the model file lives in
  , modelFile :: !FilePath  -- ^ file name under 'modelDir'
  , modelUrl :: !String     -- ^ direct download URL
  , modelSizeMB :: !Int     -- ^ approximate download size
  , modelNotes :: !String   -- ^ one-line guidance for choosing
  } deriving (Show, Eq)

-- | Where LLM (GGUF) models live
modelsDir :: FilePath
modelsDir = "llama.cpp/models"

-- | Where whisper (GGML) models live
whisperModelsDir :: FilePath
whisperModelsDir = "whisper.cpp/models"

-- | Curated whisper models, ordered small to large. Names match the
-- whisper.cpp release files (ggml-<name>.bin), so 'resolveWhisperModel'
-- finds them from the bare name.
knownWhisperModels :: [ModelSpec]
knownWhisperModels =
  [ whisperModel "base" "Whisper base" 141
      "fastest, lowest quality (setup.sh default)"
  , whisperModel "small" "Whisper small" 465
      "clearly better than base, still quick"
  , whisperModel "medium" "Whisper medium" 1463
      "high quality but slow on CPU; turbo is usually the better choice"
  , whisperModel "large-v3-turbo-q5_0" "Whisper large-v3-turbo (Q5_0)" 547
      "quantized turbo: near-turbo quality at a third of the download"
  , whisperModel "large-v3-turbo" "Whisper large-v3-turbo" 1549
      "recommended: large-v3 quality at a fraction of its cost"
  , whisperModel "large-v3" "Whisper large-v3" 2952
      "best quality, several times slower than turbo"
  ]
  where
    whisperModel name label sizeMB notes = ModelSpec
      { modelKey = name
      , modelLabel = label
      , modelDir = whisperModelsDir
      , modelFile = whisperModelFile name
      , modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" ++ whisperModelFile name
      , modelSizeMB = sizeMB
      , modelNotes = notes
      }

whisperModelFile :: String -> FilePath
whisperModelFile name = "ggml-" ++ name ++ ".bin"

-- | Resolve the WHISPER_MODEL setting to a file. A bare name such as
-- "large-v3-turbo" maps to the conventional file under 'whisperModelsDir';
-- anything that looks like a path (contains a slash or ends in .bin) is
-- used as given, so any GGML file anywhere can be selected.
resolveWhisperModel :: String -> FilePath
resolveWhisperModel name
  | '/' `elem` name || ".bin" `isSuffixOf` name = name
  | otherwise = whisperModelsDir </> whisperModelFile name

-- | Curated LLM models, ordered small to large. All are Q4_K_M
-- quantizations suitable for CPU inference.
knownModels :: [ModelSpec]
knownModels =
  [ ModelSpec
      { modelKey = "tinyllama-1.1b"
      , modelLabel = "TinyLlama 1.1B Chat"
      , modelDir = modelsDir
      , modelFile = "tinyllama-1.1b-chat.gguf"
      , modelUrl = "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
      , modelSizeMB = 669
      , modelNotes = "fastest, lowest quality (setup.sh default)"
      }
  , ModelSpec
      { modelKey = "llama3.2-3b"
      , modelLabel = "Llama 3.2 3B Instruct"
      , modelDir = modelsDir
      , modelFile = "llama-3.2-3b-instruct-q4_k_m.gguf"
      , modelUrl = "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
      , modelSizeMB = 2020
      , modelNotes = "fast with solid quality"
      }
  , ModelSpec
      { modelKey = "qwen3-4b"
      , modelLabel = "Qwen3 4B Instruct"
      , modelDir = modelsDir
      , modelFile = "qwen3-4b-instruct-2507-q4_k_m.gguf"
      , modelUrl = "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
      , modelSizeMB = 2500
      , modelNotes = "recommended: strong multilingual quality at good speed"
      }
  , ModelSpec
      { modelKey = "qwen2.5-7b"
      , modelLabel = "Qwen2.5 7B Instruct"
      , modelDir = modelsDir
      , modelFile = "qwen2.5-7b-instruct-q4_k_m.gguf"
      , modelUrl = "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
      , modelSizeMB = 4680
      , modelNotes = "best quality, noticeably slower on CPU"
      }
  ]

modelPath :: ModelSpec -> FilePath
modelPath spec = modelDir spec </> modelFile spec

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
  createDirectoryIfMissing True (modelDir spec)
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
