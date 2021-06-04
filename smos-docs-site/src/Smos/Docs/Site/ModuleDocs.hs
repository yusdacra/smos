{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}

module Smos.Docs.Site.ModuleDocs
  ( module Smos.Docs.Site.ModuleDocs,
    module Smos.Docs.Site.ModuleDocs.TH,
  )
where

import Data.Aeson as JSON
import Data.Map (Map)
import qualified Data.Map as M
import Data.Text (Text)
import Language.Haskell.TH
import Language.Haskell.TH.Load
import Path
import Path.Internal
import Smos.Docs.Site.Constants
import Smos.Docs.Site.ModuleDocs.TH
import System.Environment

nixosModuleDocs :: Load (Map Text JSON.Value)
nixosModuleDocs =
  M.fromList
    <$> $$( do
              md <- runIO $ lookupEnv "MODULE_DOCS"
              runIO $ print md
              let rd = case md of
                    Nothing -> [reldir|static/module-docs.json|]
                    Just mdf -> Path mdf -- Very hacky
              embedReadTextFileWith moduleDocFunc [||moduleDocFunc||] mode rd
          )
