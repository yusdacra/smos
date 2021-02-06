{-# LANGUAGE TypeApplications #-}

module Smos.Cursor.Report.WaitingSpec where

import Smos.Cursor.Report.Waiting
import Smos.Cursor.Report.Waiting.Gen ()
import Smos.Report.Archive.Gen ()
import Smos.Report.Filter.Gen ()
import Smos.Report.ShouldPrint
import Smos.Report.TestUtils
import Test.Syd
import Test.Syd.Validity

spec :: Spec
spec = do
  genValidSpec @WaitingReportCursor
  describe "waitingReportCursorNext" $ it "produces valid cursors" $ producesValidsOnValids waitingReportCursorNext
  describe "waitingReportCursorPrev" $ it "produces valid cursors" $ producesValidsOnValids waitingReportCursorPrev
  describe "waitingReportCursorFirst" $ it "produces valid cursors" $ producesValidsOnValids waitingReportCursorFirst
  describe "waitingReportCursorLast" $ it "produces valid cursors" $ producesValidsOnValids waitingReportCursorLast
  describe "makeWaitingEntryCursor" $ it "produces valid cursors" $ producesValidsOnValids makeWaitingEntryCursor
  describe "makeWaitingEntryCursor'" $ it "produces valid cursors" $ producesValidsOnValids2 makeWaitingEntryCursor'
  modifyMaxSuccess (`div` 10) $
    describe "produceWaitingReportCursor" $
      it "produces valid reports for interesting stores" $
        forAllValid $ \mf ->
          forAllValid $ \ha ->
            withInterestingStore $ \dc -> do
              wrc <- produceWaitingReportCursor mf ha DontPrint dc
              shouldBeValid wrc
