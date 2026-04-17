{-# LANGUAGE OverloadedStrings #-}

module STT.Markdown
  ( formatMeetingMinutes
  , saveMeetingMinutes
  ) where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import STT.PostProcess (ProcessedResult(..))

-- | Format meeting minutes as Markdown
formatMeetingMinutes :: ProcessedResult -> IO Text
formatMeetingMinutes result = do
  timestamp <- formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" <$> getCurrentTime

  let header = "# Meeting Transcription - " <> T.pack timestamp <> "\n\n"

      cleanedSection = case cleanedText result of
        Just cleaned ->
          "## Cleaned Transcript\n\n" <> cleaned <> "\n\n"
        Nothing -> ""

      originalSection = if cleanedText result == Nothing
        then "## Original Transcript\n\n" <> originalText result <> "\n\n"
        else "## Original Transcript\n\n" <> originalText result <> "\n\n"

      todosSection = case todos result of
        Just todoList ->
          "## Action Items\n\n" <> todoList <> "\n\n"
        Nothing -> ""

      errorsSection = if null (processingErrors result)
        then ""
        else "## Processing Notes\n\n" <>
             T.unlines (map (\e -> "- " <> T.pack e) (processingErrors result)) <> "\n"

      footer = "---\n*Generated with whisper-hs*\n"

  return $ T.concat
    [ header
    , cleanedSection
    , todosSection
    , originalSection
    , errorsSection
    , footer
    ]

-- | Save meeting minutes to a Markdown file
saveMeetingMinutes :: FilePath -> ProcessedResult -> IO ()
saveMeetingMinutes outputPath result = do
  markdown <- formatMeetingMinutes result
  TIO.writeFile outputPath markdown
  putStrLn $ "Meeting minutes saved to: " ++ outputPath
