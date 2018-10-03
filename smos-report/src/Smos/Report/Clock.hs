{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Report.Clock where

import GHC.Generics (Generic)

import Data.Maybe

import Data.Function
import Data.List
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.IO as T
import Data.Time
import Data.Time.Calendar.WeekDate
import Data.Tree
import Data.Validity
import Text.Printf

import Path

import Conduit

import Smos.Data

import Smos.Report.Formatting
import Smos.Report.OptParse
import Smos.Report.Streaming

clock :: ClockSettings -> Settings -> IO ()
clock ClockSettings {..} Settings {..} = do
    tups <-
        sourceToList $
        sourceFilesInNonHiddenDirsRecursively setWorkDir .| filterSmosFiles .|
        parseSmosFiles setWorkDir .|
        printShouldPrint setShouldPrint
    now <- getZonedTime
    T.putStr $
        renderClockTable clockSetResolution $
        makeClockTable $
        divideIntoBlocks (zonedTimeZone now) clockSetBlock $
        concatMap
            (mapMaybe (trimClockTime now clockSetPeriod) .
             uncurry findClockTimes)
            tups

findClockTimes :: Path Rel File -> SmosFile -> [ClockTime]
findClockTimes rf = mapMaybe go . concatMap flatten . smosFileForest
  where
    go :: Entry -> Maybe ClockTime
    go Entry {..} =
        case entryLogbook of
            LogOpen _ es -> go' es
            LogClosed es -> go' es
      where
        go' es = do
            ne <- NE.nonEmpty es
            pure $
                ClockTime
                    { clockTimeFile = rf
                    , clockTimeHeader = entryHeader
                    , clockTimeEntries = ne
                    }

trimClockTime :: ZonedTime -> ClockPeriod -> ClockTime -> Maybe ClockTime
trimClockTime zt cp ct = do
    let entries =
            mapMaybe (trimLogbookEntry zt cp) $ NE.toList $ clockTimeEntries ct
    ne <- NE.nonEmpty entries
    pure ct {clockTimeEntries = ne}

data ClockTime = ClockTime
    { clockTimeFile :: Path Rel File
    , clockTimeHeader :: Header
    , clockTimeEntries :: NonEmpty LogbookEntry
    } deriving (Show, Eq, Generic)

trimLogbookEntry ::
       ZonedTime -> ClockPeriod -> LogbookEntry -> Maybe LogbookEntry
trimLogbookEntry now cp =
    case cp of
        AllTime -> pure
        Today -> trimToToday
        ThisWeek -> trimToThisWeek
  where
    tz :: TimeZone
    tz = zonedTimeZone now
    nowLocal :: LocalTime
    nowLocal = zonedTimeToLocalTime now
    today :: Day
    today = localDay nowLocal
    todayStart :: LocalTime
    todayStart = nowLocal {localTimeOfDay = midnight}
    todayEnd :: LocalTime
    todayEnd = nowLocal {localDay = addDays 1 today, localTimeOfDay = midnight}
    trimToToday :: LogbookEntry -> Maybe LogbookEntry
    trimToToday = trimLogbookEntryTo tz todayStart todayEnd
    thisWeekStart :: LocalTime
    thisWeekStart =
        let (y, wn, _) = toWeekDate today
         in LocalTime (fromWeekDate y wn 1) midnight
    thisWeekEnd :: LocalTime
    thisWeekEnd =
        let (y, wn, _) = toWeekDate today
         in LocalTime (fromWeekDate y (wn + 1) 1) midnight -- FIXME this can wrong at the end of the year
    trimToThisWeek :: LogbookEntry -> Maybe LogbookEntry
    trimToThisWeek = trimLogbookEntryTo tz thisWeekStart thisWeekEnd

trimLogbookEntryTo ::
       TimeZone -> LocalTime -> LocalTime -> LogbookEntry -> Maybe LogbookEntry
trimLogbookEntryTo tz begin end LogbookEntry {..} =
    constructValid $
    LogbookEntry
        { logbookEntryStart =
              if toLocal logbookEntryStart >= begin
                  then logbookEntryStart
                  else fromLocal begin
        , logbookEntryEnd =
              if toLocal logbookEntryEnd < end
                  then logbookEntryEnd
                  else fromLocal end
        }
  where
    toLocal :: UTCTime -> LocalTime
    toLocal = utcToLocalTime tz
    fromLocal :: LocalTime -> UTCTime
    fromLocal = localTimeToUTC tz

data ClockTimeBlock a = ClockTimeBlock
    { clockTimeBlockName :: a
    , clockTimeBlockEntries :: [ClockTime]
    } deriving (Show, Eq, Generic, Functor)

divideIntoBlocks ::
       TimeZone -> ClockBlock -> [ClockTime] -> [ClockTimeBlock Text]
divideIntoBlocks tz cb cts =
    case cb of
        OneBlock ->
            [ ClockTimeBlock
                  {clockTimeBlockName = "All Time", clockTimeBlockEntries = cts}
            ]
        DailyBlock ->
            map (fmap (T.pack . show)) $
            combineBlocksByName $
            concatMap (divideClockTimeIntoDailyBlocks tz) cts

combineBlocksByName :: Ord a => [ClockTimeBlock a] -> [ClockTimeBlock a]
combineBlocksByName =
    map combine .
    groupBy ((==) `on` clockTimeBlockName) . sortOn clockTimeBlockName
  where
    combine :: [ClockTimeBlock a] -> ClockTimeBlock a
    combine [] = error "cannot happen due to groupBy above"
    combine bs@(h:_) =
        ClockTimeBlock
            { clockTimeBlockName = clockTimeBlockName h
            , clockTimeBlockEntries = concatMap clockTimeBlockEntries bs
            }

divideClockTimeIntoDailyBlocks :: TimeZone -> ClockTime -> [ClockTimeBlock Day]
divideClockTimeIntoDailyBlocks tz = combineByDay . divideClockTime
  where
    combineByDay :: [(Day, ClockTime)] -> [ClockTimeBlock Day]
    combineByDay = map combine . groupBy ((==) `on` fst) . sortOn fst
      where
        combine [] = error "cannot happen due to groupBy above"
        combine ts@((d, _):_) =
            ClockTimeBlock
                {clockTimeBlockName = d, clockTimeBlockEntries = map snd ts}
    toLocal :: UTCTime -> LocalTime
    toLocal = utcToLocalTime tz
    divideClockTime :: ClockTime -> [(Day, ClockTime)]
    divideClockTime ct =
        mapMaybe
            (\(d, es) ->
                 (,) d <$>
                 ((\ne -> ct {clockTimeEntries = ne}) <$> NE.nonEmpty es)) $
        combineEntriesByDay . concatMap divideLogbookEntry $ clockTimeEntries ct
      where
        combineEntriesByDay :: [(Day, LogbookEntry)] -> [(Day, [LogbookEntry])]
        combineEntriesByDay = map combine . groupBy ((==) `on` fst) . sortOn fst
          where
            combine [] = error "cannot happen due to groupBy above"
            combine ts@((d, _):_) = (d, map snd ts)
    divideLogbookEntry :: LogbookEntry -> [(Day, LogbookEntry)]
    divideLogbookEntry lbe@LogbookEntry {..} =
        flip mapMaybe dayRange $ \d ->
            (,) d <$>
            trimLogbookEntryTo
                tz
                (LocalTime d midnight)
                (LocalTime (addDays 1 d) midnight)
                lbe
      where
        startDay = localDay $ toLocal logbookEntryStart
        endDay = localDay $ toLocal logbookEntryEnd
        dayRange = [startDay .. endDay]

type ClockTable = [ClockTableBlock]

data ClockTableBlock = ClockTableBlock
    { clockTableBlockName :: Text
    , clockTableBlockEntries :: [ClockTableEntry]
    } deriving (Show, Eq, Generic)

makeClockTable :: [ClockTimeBlock Text] -> [ClockTableBlock]
makeClockTable = map makeClockTableBlock

makeClockTableBlock :: ClockTimeBlock Text -> ClockTableBlock
makeClockTableBlock ClockTimeBlock {..} =
    ClockTableBlock
        { clockTableBlockName = clockTimeBlockName
        , clockTableBlockEntries = map makeClockTableEntry clockTimeBlockEntries
        }

data ClockTableEntry = ClockTableEntry
    { clockTableEntryFile :: Path Rel File
    , clockTableEntryHeader :: Header
    , clockTableEntryTime :: NominalDiffTime
    } deriving (Show, Eq, Generic)

makeClockTableEntry :: ClockTime -> ClockTableEntry
makeClockTableEntry ClockTime {..} =
    ClockTableEntry
        { clockTableEntryFile = clockTimeFile
        , clockTableEntryHeader = clockTimeHeader
        , clockTableEntryTime = sumLogbookEntryTime $ NE.toList clockTimeEntries
        }

sumLogbookEntryTime :: [LogbookEntry] -> NominalDiffTime
sumLogbookEntryTime = sum . map go
  where
    go :: LogbookEntry -> NominalDiffTime
    go LogbookEntry {..} = diffUTCTime logbookEntryEnd logbookEntryStart

renderClockTable :: ClockResolution -> [ClockTableBlock] -> Text
renderClockTable res = T.pack . formatAsTable . concatMap goB
  where
    goB :: ClockTableBlock -> [[String]]
    goB ClockTableBlock {..} =
        [T.unpack clockTableBlockName, "", ""] : map go clockTableBlockEntries
    go :: ClockTableEntry -> [String]
    go ClockTableEntry {..} =
        [ fromRelFile clockTableEntryFile
        , T.unpack $ headerText clockTableEntryHeader
        , T.unpack $ renderNominalDiffTime res clockTableEntryTime
        ]

renderNominalDiffTime :: ClockResolution -> NominalDiffTime -> Text
renderNominalDiffTime res ndt =
    T.intercalate ":" $
    concat
        [ [T.pack $ printf "%5.2d" hours | res <= HoursResolution]
        , [T.pack $ printf "%.2d" minutes | res <= MinutesResolution]
        , [T.pack $ printf "%.2d" seconds | res <= SecondsResolution]
        ]
  where
    totalSeconds = round ndt :: Int
    totalMinutes = totalSeconds `div` secondsInAMinute
    totalHours = totalMinutes `div` minutesInAnHour
    secondsInAMinute = 60
    minutesInAnHour = 60
    hours = totalHours
    minutes = totalMinutes - minutesInAnHour * totalHours
    seconds = totalSeconds - secondsInAMinute * totalMinutes
