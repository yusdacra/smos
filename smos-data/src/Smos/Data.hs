{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Data
  ( module Smos.Data.Types,
    versionCheck,
    dataVersionCheck,
    VersionCheck (..),
    versionsErrorHelp,
    readWriteDataVersionsHelpMessage,
    writeDataVersionsHelpMessage,
    readDataVersionsHelpMessage,
    readSmosFile,
    writeSmosFile,
    parseSmosFile,
    parseSmosFileYaml,
    parseSmosFileJSON,
    parseSmosData,
    parseSmosDataYaml,
    parseSmosDataJSON,
    smosFileBS,
    smosFileYamlBS,
    smosFileJSONBS,
    smosFileJSONPrettyBS,
    emptySmosFile,
    makeSmosFile,
    prettySmosForest,
    smosFileClockOutEverywhere,
    entryClockIn,
    entryClockOut,
    logbookClockIn,
    mkLogOpen,
    logbookClockOut,
    mkLogbookEntry,
    todoStateIsDone,
    mTodoStateIsDone,
    entryIsDone,
    stateHistoryState,
    stateHistorySetState,
    mkStateHistoryEntry,
    entryState,
    entrySetState,
  )
where

import Control.Arrow
import Data.Aeson as JSON
import Data.Aeson.Encode.Pretty as JSON
import Data.ByteString (ByteString)
import qualified Data.ByteString as SB
import qualified Data.ByteString.Lazy as LB
import Data.SemVer as Version
import qualified Data.Text as T
import Data.Time
import Data.Tree
import Data.Validity
import Data.Yaml as Yaml
import Data.Yaml.Builder as Yaml
import GHC.Generics (Generic)
import Lens.Micro
import Path
import Path.IO
import Smos.Data.Types
import UnliftIO.IO.File

readSmosFile :: Path Abs File -> IO (Maybe (Either String SmosFile))
readSmosFile fp = do
  mContents <- forgivingAbsence $ SB.readFile $ toFilePath fp
  case mContents of
    Nothing -> pure Nothing
    Just "" -> pure $ Just $ Right emptySmosFile
    Just contents_ -> pure $ Just $ parseSmosFile contents_

writeSmosFile :: Path Abs File -> SmosFile -> IO ()
writeSmosFile fp sf = do
  ensureDir $ parent fp
  writeBinaryFileDurableAtomic (toFilePath fp) (smosFileBS sf)

parseSmosFile :: ByteString -> Either String SmosFile
parseSmosFile = parseWithVersionCheck parseSmosData

parseSmosFileYaml :: ByteString -> Either String SmosFile
parseSmosFileYaml = parseWithVersionCheck parseSmosDataYaml

parseSmosFileJSON :: ByteString -> Either String SmosFile
parseSmosFileJSON = parseWithVersionCheck parseSmosDataJSON

data VersionCheck
  = OlderThanSupported
  | Supported
  | NewerThanSupported
  deriving (Show, Eq, Generic)

versionCheck :: Version -> Version -> Version -> VersionCheck
versionCheck oldestSupported newestSupported versionToCheck =
  let parsedMajor = versionToCheck ^. Version.major
      oldestMajor = oldestSupported ^. Version.major
      newestMajor = newestSupported ^. Version.major
   in if parsedMajor >= oldestMajor
        then
          if parsedMajor <= newestMajor
            then Supported
            else NewerThanSupported
        else OlderThanSupported

dataVersionCheck :: Version -> VersionCheck
dataVersionCheck = versionCheck oldestParsableDataVersion newestParsableDataVersion

parseWithVersionCheck :: (forall a. FromJSON a => ByteString -> Either String a) -> ByteString -> Either String SmosFile
parseWithVersionCheck parseFunc sb =
  case parseFunc sb of
    Right sf -> Right sf
    Left _ -> do
      Versioned {..} <- parseFunc sb
      case dataVersionCheck versionedVersion of
        OlderThanSupported ->
          Left $
            unlines $
              [ unwords
                  [ "This file was generated by an older version of smos, downgrade to support version",
                    Version.toString (version (versionedVersion ^. Version.major) 0 0 [] []),
                    "of the smos data format to parse it."
                  ],
                ""
              ]
                ++ versionsErrorHelp oldestParsableDataVersion versionedVersion newestParsableDataVersion
        NewerThanSupported ->
          Left $
            unlines $
              [ unwords
                  [ "This file was generated by a newer version of smos, upgrade to support version",
                    Version.toString (version (versionedVersion ^. Version.major) 0 0 [] []),
                    "of the smos data format to parse it."
                  ],
                ""
              ]
                ++ versionsErrorHelp oldestParsableDataVersion versionedVersion newestParsableDataVersion
        Supported -> parseEither parseJSON versionedValue

versionsErrorHelp :: Version -> Version -> Version -> [String]
versionsErrorHelp oldestSupported current newestSupported =
  [ unwords ["Oldest supported: ", Version.toString oldestSupported],
    unwords ["Newest supported: ", Version.toString newestSupported],
    "",
    unwords ["Checked:          ", Version.toString current]
  ]

readWriteDataVersionsHelpMessage :: [String]
readWriteDataVersionsHelpMessage =
  concat
    [ writeDataVersionsHelpMessage,
      [""],
      readDataVersionsHelpMessage
    ]

writeDataVersionsHelpMessage :: [String]
writeDataVersionsHelpMessage =
  [ unwords ["Current Smos data format version:", Version.toString currentDataVersion]
  ]

readDataVersionsHelpMessage :: [String]
readDataVersionsHelpMessage =
  [ unwords ["Oldest parseable Smos data format version:", Version.toString oldestParsableDataVersion],
    unwords ["Newest parseable Smos data format version:", Version.toString newestParsableDataVersion]
  ]

parseSmosData :: FromJSON a => ByteString -> Either String a
parseSmosData bs =
  case parseSmosDataYaml bs of
    Right pyv -> pure pyv
    Left pye -> case parseSmosDataJSON bs of
      Right pjv -> pure pjv
      Left pje -> Left $ unlines ["Failed to parse smos data as json:", pje, "and also as yaml:", pye]

parseSmosDataYaml :: FromJSON a => ByteString -> Either String a
parseSmosDataYaml = left Yaml.prettyPrintParseException . Yaml.decodeEither'

parseSmosDataJSON :: FromJSON a => ByteString -> Either String a
parseSmosDataJSON = JSON.eitherDecode . LB.fromStrict

smosFileBS :: SmosFile -> ByteString
smosFileBS = smosFileYamlBS

smosFileYamlBS :: SmosFile -> ByteString
smosFileYamlBS = Yaml.toByteString . Versioned currentDataVersion

smosFileJSONBS :: SmosFile -> LB.ByteString
smosFileJSONBS = JSON.encode . Versioned currentDataVersion

smosFileJSONPrettyBS :: SmosFile -> LB.ByteString
smosFileJSONPrettyBS = JSON.encodePretty . Versioned currentDataVersion

emptySmosFile :: SmosFile
emptySmosFile = makeSmosFile []

makeSmosFile :: Forest Entry -> SmosFile
makeSmosFile f = SmosFile {smosFileForest = f}

prettySmosForest :: Forest Entry -> String
prettySmosForest ts = unlines $ map prettySmosTree ts

prettySmosTree :: Tree Entry -> String
prettySmosTree Node {..} = unlines [prettySmosEntry rootLabel, prettySmosForest subForest]

prettySmosEntry :: Entry -> String
prettySmosEntry Entry {..} = T.unpack $ headerText entryHeader

smosFileClockOutEverywhere :: UTCTime -> SmosFile -> SmosFile
smosFileClockOutEverywhere now sf = sf {smosFileForest = goF (smosFileForest sf)}
  where
    goT (Node e f_) = Node (entryClockOut now e) (goF f_)
    goF = map goT

entryClockIn :: UTCTime -> Entry -> Entry
entryClockIn now e = maybe e (\lb -> e {entryLogbook = lb}) $ logbookClockIn now (entryLogbook e)

entryClockOut :: UTCTime -> Entry -> Entry
entryClockOut now e = maybe e (\lb -> e {entryLogbook = lb}) $ logbookClockOut now (entryLogbook e)

todoStateIsDone :: TodoState -> Bool
todoStateIsDone = \case
  "CANCELLED" -> True
  "DONE" -> True
  "FAILED" -> True
  _ -> False

-- | 'False' if 'Nothing'.
mTodoStateIsDone :: Maybe TodoState -> Bool
mTodoStateIsDone = maybe False todoStateIsDone

entryIsDone :: Entry -> Bool
entryIsDone = mTodoStateIsDone . entryState

logbookClockIn :: UTCTime -> Logbook -> Maybe Logbook
logbookClockIn now lb =
  case lb of
    LogClosed es ->
      let d = mkLogOpen now es
       in case es of
            [] -> d
            (LogbookEntry {..} : rest) ->
              if logbookEntryEnd == now
                then mkLogOpen logbookEntryStart rest
                else d
    LogOpen {} -> Nothing

logbookClockOut :: UTCTime -> Logbook -> Maybe Logbook
logbookClockOut now lb =
  case lb of
    LogClosed {} -> Nothing
    LogOpen start es -> do
      e <- mkLogbookEntry start now
      constructValid $ LogClosed $ e : es

mkLogOpen :: UTCTime -> [LogbookEntry] -> Maybe Logbook
mkLogOpen now es = constructValid $ LogOpen (mkImpreciseUTCTime now) es

mkLogbookEntry :: UTCTime -> UTCTime -> Maybe LogbookEntry
mkLogbookEntry start now = constructValid $ LogbookEntry (mkImpreciseUTCTime start) (mkImpreciseUTCTime now)

stateHistoryState :: StateHistory -> Maybe TodoState
stateHistoryState (StateHistory tups) =
  case tups of
    [] -> Nothing
    (StateHistoryEntry mts _ : _) -> mts

stateHistorySetState :: UTCTime -> Maybe TodoState -> StateHistory -> Maybe StateHistory
stateHistorySetState now mts sh = do
  let e = mkStateHistoryEntry now mts
  constructValid $ sh {unStateHistory = e : unStateHistory sh}

mkStateHistoryEntry :: UTCTime -> Maybe TodoState -> StateHistoryEntry
mkStateHistoryEntry now mts = StateHistoryEntry mts (mkImpreciseUTCTime now)

entryState :: Entry -> Maybe TodoState
entryState = stateHistoryState . entryStateHistory

entrySetState :: UTCTime -> Maybe TodoState -> Entry -> Maybe Entry
entrySetState now mts e = do
  sh' <- stateHistorySetState now mts $ entryStateHistory e
  pure $ e {entryStateHistory = sh'}
