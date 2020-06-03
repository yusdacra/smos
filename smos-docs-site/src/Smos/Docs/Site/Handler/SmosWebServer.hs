{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Smos.Docs.Site.Handler.SmosWebServer
  ( getSmosWebServerR,
  )
where

import qualified Env
import Options.Applicative
import Options.Applicative.Help
import Smos.Docs.Site.Handler.Import
import Smos.Web.Server.OptParse as WebServer
import YamlParse.Applicative

getSmosWebServerR :: Handler Html
getSmosWebServerR = do
  DocPage {..} <- lookupPage "smos-web-server"
  let argsHelpText = getHelpPageOf []
      envHelpText = Env.helpDoc WebServer.environmentParser
      confHelpText = prettySchemaDoc @WebServer.Configuration
  defaultLayout $ do
    setTitle "Smos Documentation - smos-web-server"
    $(widgetFile "args")

getHelpPageOf :: [String] -> String
getHelpPageOf args =
  let res = runArgumentsParser $ args ++ ["--help"]
   in case res of
        Failure fr ->
          let (ph, _, cols) = execFailure fr "smos-web-server"
           in renderHelp cols ph
        _ -> error "Something went wrong while calling the option parser."
