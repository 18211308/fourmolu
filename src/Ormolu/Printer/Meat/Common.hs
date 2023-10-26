{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

-- | Rendering of commonly useful bits.
module Ormolu.Printer.Meat.Common
  ( FamilyStyle (..),
    p_hsmodName,
    p_ieWrappedName,
    p_rdrName,
    p_qualName,
    p_infixDefHelper,
    p_hsDoc,
    p_hsDoc',
    p_sourceText,
  )
where

import Control.Monad
import Data.Foldable (traverse_)
import Data.Text qualified as T
import GHC.Data.FastString
import GHC.Hs.Doc
import GHC.Hs.Extension (GhcPs)
import GHC.Hs.ImpExp
import GHC.LanguageExtensions.Type (Extension (..))
import GHC.Parser.Annotation
import GHC.Types.Name.Occurrence (OccName (..), occNameString)
import GHC.Types.Name.Reader
import GHC.Types.SourceText
import GHC.Types.SrcLoc
import Language.Haskell.Syntax.Module.Name
import Ormolu.Config
import Ormolu.Printer.Combinators
import Ormolu.Utils

-- | Data and type family style.
data FamilyStyle
  = -- | Declarations in type classes
    Associated
  | -- | Top-level declarations
    Free

-- | Outputs the name of the module-like entity, preceeded by the correct prefix ("module" or "signature").
p_hsmodName :: ModuleName -> R ()
p_hsmodName mname = do
  sourceType <- askSourceType
  txt $ case sourceType of
    ModuleSource -> "module"
    SignatureSource -> "signature"
  space
  atom mname

p_ieWrappedName :: IEWrappedName GhcPs -> R ()
p_ieWrappedName = \case
  IEName _ x -> p_rdrName x
  IEPattern _ x -> do
    txt "pattern"
    space
    p_rdrName x
  IEType _ x -> do
    txt "type"
    space
    p_rdrName x

-- | Render a @'LocatedN' 'RdrName'@.
p_rdrName :: LocatedN RdrName -> R ()
p_rdrName l = located l $ \x -> do
  unboxedSums <- isExtensionEnabled UnboxedSums
  let wrapper = \case
        EpAnn {anns} -> case anns of
          NameAnnQuote {nann_quoted} -> tickPrefix . wrapper (ann nann_quoted)
          NameAnn {nann_adornment = NameParens} ->
            parens N . handleUnboxedSumsAndHashInteraction
          NameAnn {nann_adornment = NameBackquotes} -> backticks
          -- whether the `->` identifier is parenthesized
          NameAnnRArrow {nann_mopen = Just _} -> parens N
          -- special case for unboxed unit tuples
          NameAnnOnly {nann_adornment = NameParensHash} -> const $ txt "(# #)"
          _ -> id
        EpAnnNotUsed -> id

      -- When UnboxedSums is enabled, `(#` is a single lexeme, so we have to
      -- insert spaces when we have a parenthesized operator starting with `#`.
      handleUnboxedSumsAndHashInteraction
        | unboxedSums,
          -- Qualified names do not start wth a `#`.
          Unqual (occNameString -> '#' : _) <- x =
            \y -> space *> y <* space
        | otherwise = id

  wrapper (ann . getLoc $ l) $ case x of
    Unqual occName ->
      atom occName
    Qual mname occName ->
      p_qualName mname occName
    Orig _ occName ->
      -- This is used when GHC generates code that will be fed into
      -- the renamer (e.g. from deriving clauses), but where we want
      -- to say that something comes from given module which is not
      -- specified in the source code, e.g. @Prelude.map@.
      --
      -- My current understanding is that the provided module name
      -- serves no purpose for us and can be safely ignored.
      atom occName
    Exact name ->
      atom name
  where
    tickPrefix y = txt "'" *> y

p_qualName :: ModuleName -> OccName -> R ()
p_qualName mname occName = do
  atom mname
  txt "."
  atom occName

-- | A helper for formatting infix constructions in lhs of definitions.
p_infixDefHelper ::
  -- | Whether to format in infix style
  Bool ->
  -- | Whether to bump indentation for arguments
  Bool ->
  -- | How to print the operator\/name
  R () ->
  -- | How to print the arguments
  [R ()] ->
  R ()
p_infixDefHelper isInfix indentArgs name args =
  case (isInfix, args) of
    (True, p0 : p1 : ps) -> do
      let parens' =
            if null ps
              then id
              else parens N . sitcc
      parens' $ do
        p0
        breakpoint
        inci . sitcc $ do
          name
          space
          p1
      unless (null ps) . inciIf indentArgs $ do
        breakpoint
        sitcc (sep breakpoint sitcc ps)
    (_, ps) -> do
      name
      unless (null ps) $ do
        breakpoint
        inciIf indentArgs $ sitcc (sep breakpoint sitcc args)

-- | Print a Haddock.
p_hsDoc ::
  -- | Haddock style
  HaddockStyle ->
  -- | Finish the doc string with a newline
  Bool ->
  -- | The 'LHsDoc' to render
  LHsDoc GhcPs ->
  R ()
p_hsDoc hstyle needsNewline lstr = do
  poHStyle <- getPrinterOpt poHaddockStyle
  p_hsDoc' poHStyle hstyle needsNewline lstr

-- | Print a Haddock.
p_hsDoc' ::
  -- | 'haddock-style' configuration option
  HaddockPrintStyle ->
  -- | Haddock style
  HaddockStyle ->
  -- | Finish the doc string with a newline
  Bool ->
  -- | The 'LHsDoc' to render
  LHsDoc GhcPs ->
  R ()
p_hsDoc' poHStyle hstyle needsNewline (L l str) = do
  let isCommentSpan = \case
        HaddockSpan _ _ -> True
        CommentSpan _ -> True
        _ -> False
  goesAfterComment <- maybe False isCommentSpan <$> getSpanMark
  -- Make sure the Haddock is separated by a newline from other comments.
  when goesAfterComment newline

  let shouldEscapeCommentBraces =
        case poHStyle of
          HaddockSingleLine -> False
          HaddockMultiLine -> True
          HaddockMultiLineCompact -> True
  let docStringLines = splitDocString shouldEscapeCommentBraces $ hsDocString str

  mSrcSpan <- getSrcSpan l

  let useSingleLineComments =
        or
          [ poHStyle == HaddockSingleLine,
            length docStringLines <= 1,
            -- Use multiple single-line comments when the whole comment is indented
            maybe False ((> 1) . srcSpanStartCol) mSrcSpan
          ]

  let body sep' =
        forM_ (zip docStringLines (True : repeat False)) $ \(x, isFirst) -> do
          if isFirst
            then do
              -- prevent trailing space in multi-line comments
              unless (not useSingleLineComments && T.null x) space
            else do
              sep'
          unless (T.null x) (txt x)

  if useSingleLineComments
    then do
      txt $ "-- " <> haddockDelim
      body $ newline >> txt "--" >> space
    else do
      txt . T.concat $
        [ "{-",
          case (hstyle, poHStyle) of
            (Pipe, HaddockMultiLineCompact) -> ""
            _ -> " ",
          haddockDelim
        ]
      -- 'newline' doesn't allow multiple blank newlines, which changes the comment
      -- if the user writes a comment with multiple newlines. So we have to do this
      -- to force the printer to output a newline. The HaddockSingleLine branch
      -- doesn't have this problem because each newline has at least "--".
      --
      -- 'newline' also takes indentation into account, but since multiline comments
      -- are never used in an indented context (see useSingleLineComments), this is
      -- safe
      body $ txt "\n"
      newline
      txt "-}"

  when needsNewline newline
  traverse_ (setSpanMark . HaddockSpan hstyle) mSrcSpan
  where
    haddockDelim =
      case hstyle of
        Pipe -> "|"
        Caret -> "^"
        Asterisk n -> T.replicate n "*"
        Named name -> "$" <> T.pack name
    getSrcSpan = \case
      -- It's often the case that the comment itself doesn't have a span
      -- attached to it and instead its location can be obtained from
      -- nearest enclosing span.
      UnhelpfulSpan _ -> getEnclosingSpan
      RealSrcSpan spn _ -> pure $ Just spn

p_sourceText :: SourceText -> R ()
p_sourceText = \case
  NoSourceText -> pure ()
  SourceText s -> atom @FastString s
