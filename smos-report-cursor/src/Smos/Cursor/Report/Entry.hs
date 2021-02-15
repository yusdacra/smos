{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Cursor.Report.Entry where

import Conduit
import Control.DeepSeq
import Cursor.Forest
import Cursor.Simple.List.NonEmpty
import Cursor.Simple.Tree
import Cursor.Text
import Cursor.Types
import qualified Data.Conduit.Combinators as C
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Validity
import GHC.Generics (Generic)
import Lens.Micro
import Path
import Smos.Cursor.SmosFile
import Smos.Data
import Smos.Report.Archive
import Smos.Report.Config
import Smos.Report.Filter
import Smos.Report.Projection
import Smos.Report.ShouldPrint
import Smos.Report.Streaming

data EntryReportCursor a = EntryReportCursor
  { entryReportCursorEntryReportEntryCursors :: ![EntryReportEntryCursor a],
    entryReportCursorSelectedEntryReportEntryCursors :: !(Maybe (NonEmptyCursor (EntryReportEntryCursor a))),
    entryReportCursorFilterBar :: !TextCursor,
    entryReportCursorSelection :: !EntryReportCursorSelection
  }
  deriving (Show, Eq, Generic)

instance Validity a => Validity (EntryReportCursor a)

-- TODO add constraint: The selected list needs to be a subset of the total one
-- TODO add constraint: The selected list needs to be a subset of the total one generated by whichever filter is on the filter bar.

instance NFData a => NFData (EntryReportCursor a)

emptyEntryReportCursor :: EntryReportCursor a
emptyEntryReportCursor =
  EntryReportCursor
    { entryReportCursorEntryReportEntryCursors = [],
      entryReportCursorSelectedEntryReportEntryCursors = Nothing,
      entryReportCursorFilterBar = emptyTextCursor,
      entryReportCursorSelection = EntryReportSelected
    }

data EntryReportCursorSelection
  = EntryReportSelected
  | EntryReportFilterSelected
  deriving (Show, Eq, Generic)

instance Validity EntryReportCursorSelection

instance NFData EntryReportCursorSelection

produceEntryReportCursor ::
  MonadIO m =>
  (Path Rel File -> ForestCursor Entry Entry -> [a]) ->
  ([EntryReportEntryCursor a] -> [EntryReportEntryCursor a]) ->
  Maybe EntryFilterRel ->
  HideArchive ->
  ShouldPrint ->
  DirectoryConfig ->
  m (EntryReportCursor a)
produceEntryReportCursor func finalise mf ha sp dc = produceReport ha sp dc (entryReportCursorConduit func finalise mf)

entryReportCursorConduit ::
  Monad m =>
  (Path Rel File -> ForestCursor Entry Entry -> [a]) ->
  ([EntryReportEntryCursor a] -> [EntryReportEntryCursor a]) ->
  Maybe EntryFilterRel ->
  ConduitT (Path Rel File, SmosFile) void m (EntryReportCursor a)
entryReportCursorConduit func finalise mf =
  makeEntryReportCursor . finalise
    <$> (entryReportEntryCursorConduit func mf .| sinkList)

entryReportCursorEntryReportEntryCursorsL :: Lens' (EntryReportCursor a) [EntryReportEntryCursor a]
entryReportCursorEntryReportEntryCursorsL =
  lens entryReportCursorEntryReportEntryCursors (\narc naecs -> narc {entryReportCursorEntryReportEntryCursors = naecs})

entryReportCursorSelectedEntryReportEntryCursorsL :: Lens' (EntryReportCursor a) (Maybe (NonEmptyCursor (EntryReportEntryCursor a)))
entryReportCursorSelectedEntryReportEntryCursorsL =
  lens
    entryReportCursorSelectedEntryReportEntryCursors
    (\narc necM -> narc {entryReportCursorSelectedEntryReportEntryCursors = necM})

entryReportCursorSelectionL :: Lens' (EntryReportCursor a) EntryReportCursorSelection
entryReportCursorSelectionL = lens entryReportCursorSelection (\narc cs -> narc {entryReportCursorSelection = cs})

entryReportCursorFilterBarL :: Lens' (EntryReportCursor a) TextCursor
entryReportCursorFilterBarL =
  lens entryReportCursorFilterBar $
    \narc@EntryReportCursor {..} tc ->
      let query = parseEntryFilterRel $ rebuildTextCursor tc
       in case query of
            Left _ ->
              narc
                { entryReportCursorFilterBar = tc
                }
            Right ef ->
              let filteredIn =
                    filterEntryReportEntryCursors ef
                      . toList
                      $ entryReportCursorEntryReportEntryCursors
               in narc
                    { entryReportCursorFilterBar = tc,
                      entryReportCursorSelectedEntryReportEntryCursors =
                        makeNEEntryReportEntryCursor filteredIn
                    }

filterEntryReportEntryCursors :: EntryFilterRel -> [EntryReportEntryCursor a] -> [EntryReportEntryCursor a]
filterEntryReportEntryCursors ef = filter (filterPredicate ef . unwrapEntryReportEntryCursor)

makeEntryReportCursor :: [EntryReportEntryCursor a] -> EntryReportCursor a
makeEntryReportCursor naecs =
  EntryReportCursor
    { entryReportCursorEntryReportEntryCursors = naecs,
      entryReportCursorSelectedEntryReportEntryCursors = makeNEEntryReportEntryCursor naecs,
      entryReportCursorFilterBar = emptyTextCursor,
      entryReportCursorSelection = EntryReportSelected
    }

makeNEEntryReportEntryCursor :: [EntryReportEntryCursor a] -> Maybe (NonEmptyCursor (EntryReportEntryCursor a))
makeNEEntryReportEntryCursor = fmap makeNonEmptyCursor . NE.nonEmpty

entryReportCursorBuildSmosFileCursor :: Path Abs Dir -> EntryReportCursor a -> Maybe (Path Abs File, SmosFileCursor)
entryReportCursorBuildSmosFileCursor pad narc = do
  selected <- nonEmptyCursorCurrent <$> entryReportCursorSelectedEntryReportEntryCursors narc
  pure (pad </> entryReportEntryCursorFilePath selected, makeSmosFileCursorFromSimpleForestCursor $ entryReportEntryCursorForestCursor selected)

entryReportCursorNext :: EntryReportCursor a -> Maybe (EntryReportCursor a)
entryReportCursorNext = entryReportCursorSelectedEntryReportEntryCursorsL $ \mnec -> do
  nec <- mnec
  case nonEmptyCursorSelectNext nec of
    Just nec' -> Just $ Just nec'
    Nothing -> Nothing

entryReportCursorPrev :: EntryReportCursor a -> Maybe (EntryReportCursor a)
entryReportCursorPrev = entryReportCursorSelectedEntryReportEntryCursorsL $ \mnec -> do
  nec <- mnec
  case nonEmptyCursorSelectPrev nec of
    Just nec' -> Just $ Just nec'
    Nothing -> Nothing

entryReportCursorFirst :: EntryReportCursor a -> EntryReportCursor a
entryReportCursorFirst = entryReportCursorSelectedEntryReportEntryCursorsL %~ fmap nonEmptyCursorSelectFirst

entryReportCursorLast :: EntryReportCursor a -> EntryReportCursor a
entryReportCursorLast = entryReportCursorSelectedEntryReportEntryCursorsL %~ fmap nonEmptyCursorSelectLast

entryReportCursorSelectReport :: EntryReportCursor a -> Maybe (EntryReportCursor a)
entryReportCursorSelectReport = entryReportCursorSelectionL $
  \case
    EntryReportSelected -> Nothing
    EntryReportFilterSelected -> Just EntryReportSelected

entryReportCursorSelectFilter :: EntryReportCursor a -> Maybe (EntryReportCursor a)
entryReportCursorSelectFilter = entryReportCursorSelectionL $
  \case
    EntryReportFilterSelected -> Nothing
    EntryReportSelected -> Just EntryReportFilterSelected

entryReportCursorInsert :: Char -> EntryReportCursor a -> Maybe (EntryReportCursor a)
entryReportCursorInsert c = entryReportCursorFilterBarL $ textCursorInsert c

entryReportCursorAppend :: Char -> EntryReportCursor a -> Maybe (EntryReportCursor a)
entryReportCursorAppend c = entryReportCursorFilterBarL $ textCursorAppend c

entryReportCursorRemove :: EntryReportCursor a -> Maybe (EntryReportCursor a)
entryReportCursorRemove =
  entryReportCursorFilterBarL $
    \tc ->
      case textCursorRemove tc of
        Nothing -> Nothing
        Just Deleted -> Nothing
        Just (Updated narc) -> Just narc

entryReportCursorDelete :: EntryReportCursor a -> Maybe (EntryReportCursor a)
entryReportCursorDelete =
  entryReportCursorFilterBarL $
    \tc ->
      case textCursorDelete tc of
        Nothing -> Nothing
        Just Deleted -> Nothing
        Just (Updated narc) -> Just narc

entryReportEntryCursorConduit :: Monad m => (Path Rel File -> ForestCursor Entry Entry -> [a]) -> Maybe EntryFilterRel -> ConduitT (Path Rel File, SmosFile) (EntryReportEntryCursor a) m ()
entryReportEntryCursorConduit func mf =
  smosFileCursors
    .| smosMFilter mf
    .| C.concatMap (\(rf, fc) -> makeEntryReportEntryCursor rf fc <$> func rf fc)

data EntryReportEntryCursor a = EntryReportEntryCursor
  { entryReportEntryCursorFilePath :: !(Path Rel File),
    entryReportEntryCursorForestCursor :: !(ForestCursor Entry Entry),
    entryReportEntryCursorVal :: !a
  }
  deriving (Show, Eq, Generic)

instance Validity a => Validity (EntryReportEntryCursor a)

instance NFData a => NFData (EntryReportEntryCursor a)

unwrapEntryReportEntryCursor :: EntryReportEntryCursor a -> (Path Rel File, ForestCursor Entry Entry)
unwrapEntryReportEntryCursor EntryReportEntryCursor {..} =
  (entryReportEntryCursorFilePath, entryReportEntryCursorForestCursor)

makeEntryReportEntryCursor :: Path Rel File -> ForestCursor Entry Entry -> a -> EntryReportEntryCursor a
makeEntryReportEntryCursor rp fc a =
  EntryReportEntryCursor
    { entryReportEntryCursorFilePath = rp,
      entryReportEntryCursorForestCursor = fc,
      entryReportEntryCursorVal = a
    }

entryReportEntryCursorForestCursorL :: Lens' (EntryReportEntryCursor a) (ForestCursor Entry Entry)
entryReportEntryCursorForestCursorL =
  lens entryReportEntryCursorForestCursor $ \nac fc -> nac {entryReportEntryCursorForestCursor = fc}

entryReportEntryCursorEntryL :: Lens' (EntryReportEntryCursor a) Entry
entryReportEntryCursorEntryL =
  entryReportEntryCursorForestCursorL . forestCursorSelectedTreeL . treeCursorCurrentL

projectEntryReportEntryCursor :: NonEmpty Projection -> EntryReportEntryCursor () -> NonEmpty Projectee
projectEntryReportEntryCursor projection EntryReportEntryCursor {..} = performProjectionNE projection entryReportEntryCursorFilePath entryReportEntryCursorForestCursor
