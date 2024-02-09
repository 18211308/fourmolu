{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

-- | Pretty-printer for Haskell AST.
module Ormolu.Printer
  ( printSnippets,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Ormolu.Parser.Result
import Ormolu.Printer.Combinators
import Ormolu.Printer.Meat.Module
import Ormolu.Printer.SpanStream
import Ormolu.Processing.Common

-- | Render several source snippets.
printSnippets ::
  -- | Whether to print out debug information during printing
  Bool ->
  -- | Result of parsing
  [SourceSnippet] ->
  -- | Resulting rendition
  Text
printSnippets debug = T.concat . fmap printSnippet
  where
    printSnippet = \case
      ParsedSnippet ParseResult {..} ->
        reindent prIndent $
          runR
            ( p_hsModule
                prStackHeader
                prPragmas
                prParsedSource
            )
            (mkSpanStream prParsedSource)
            prCommentStream
            prSourceType
            prExtensions
            prModuleFixityMap
            debug
      RawSnippet r -> r
