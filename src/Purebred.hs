module Purebred (
  module Types,
  module UI.Actions,
  module UI.Index.Keybindings,
  module UI.Mail.Keybindings,
  Event(..),
  Key(..),
  Modifier(..),
  List(..),
  Next,
  getDatabasePath,
  defaultConfig,
  solarizedDark,
  solarizedLight,
  (</>),
  module Control.Lens,
  genBoundary,
  Mailbox(..),
  AddrSpec(..),
  Domain(..),
  purebred) where

import UI.App (theApp, initialState)

import qualified Control.DeepSeq
import Control.Exception.Base (SomeException(..), IOException, catch)
import Control.Monad ((>=>), unless, void)
import Options.Applicative hiding (str)
import qualified Options.Applicative.Builder as Builder
import Data.Semigroup ((<>))
import System.Process
       (createProcess, proc, runProcess, waitForProcess, ProcessHandle)
import System.Info (arch, os)
import System.Exit (ExitCode(..), exitWith)
import System.Environment (getProgName, lookupEnv, getArgs)
import System.Environment.XDG.BaseDir (getUserConfigDir)
import System.Directory (getModificationTime, getCurrentDirectory)
import System.FilePath.Posix ((</>))
import System.IO (hPrint, stderr, hFlush)
import Data.Maybe (fromMaybe)
import System.Random (RandomGen, getStdGen, randomRs)

import UI.Index.Keybindings
import UI.Mail.Keybindings
import UI.Actions
import Storage.Notmuch (getDatabasePath)
import Config.Main (defaultConfig, solarizedDark, solarizedLight)
import Types

-- re-exports for configuration
import Graphics.Vty.Input.Events (Event(..), Key(..), Modifier(..))
import Brick.Main (defaultMain)
import Brick.Types (Next)
import Brick.Widgets.List (List(..))
import Control.Lens ((&), over, set)
import Data.MIME (Mailbox(..), AddrSpec(..), Domain(..))

newtype AppConfig = AppConfig
    { databaseFilepath :: Maybe String
    }

appconfig :: Parser AppConfig
appconfig =
    AppConfig <$> optional
     ( Builder.option
         Builder.str
         (long "database" <> metavar "DATABASE" <>
          help "Filepath to notmuch database") )

purebred :: UserConfiguration -> IO ()
purebred config = do
    appconf <- execParser opts
    let
      setDB = maybe id (const . pure) (databaseFilepath appconf)
      cfg' = over (confNotmuch . nmDatabase) setDB config
    buildLaunch `catch`
        \e -> hPrint stderr (e :: IOException) >> hFlush stderr
    launch cfg'
  where
    opts =
        info
            (appconfig <**> helper)
            (fullDesc <> progDesc "purebred" <>
             header "a search based, terminal mail user agent")

-- | Try to compile the config if it has changed and execute it
-- Note: This code is mostly borrowed from XMonad.Main.hs with the exception
-- that we're not handling any signals, but leave that up to System.Process for
-- good or worse.
buildLaunch :: IO ()
buildLaunch = do
    void $ recompile False
    configDir <- getPurebredConfigDir
    whoami <- getProgName
    args <- getArgs
    let bin = purebredCompiledName
    unless (whoami == bin) $
        createProcess (proc (configDir </> bin) args) >>=
        \(_,_,_,ph) -> waitForProcess ph >>=
        exitWith

launch :: UserConfiguration -> IO ()
launch cfg = do
    b <- genBoundary <$> getStdGen
    -- Set the boundary generator (an INFINITE [Char]) /after/ deepseq'ing :)
    -- FIXME: seems like something that shouldn't be exposed in user config
    cfg' <- set (confComposeView . cvBoundary) b <$> processConfig cfg
    s <- initialState cfg'
    void $ defaultMain (theApp s) s

-- | Process the user config into an internal configuration, then
-- fully evaluates it.
processConfig :: UserConfiguration -> IO InternalConfiguration
processConfig = fmap Control.DeepSeq.force . (
  (confNotmuch . nmDatabase) id
  >=> confEditor id
  >=> (confFileBrowserView . fbHomePath) id
  )


-- RFC2046 5.1.1
boundaryChars :: String
boundaryChars = ['0'..'9'] <> ['a'..'z'] <> ['A'..'Z'] <> "'()+_,-./:=?"

genBoundary :: RandomGen g => g -> String
genBoundary = filter isBoundaryChar . randomRs (minimum boundaryChars, maximum boundaryChars)
  where
    isBoundaryChar = (`elem` boundaryChars)

-- | Recompile the config file if it has changed based on the modification timestamp
-- Node: Mostly a XMonad.Main.hs rip-off.
recompile :: Bool -> IO Bool
recompile force = do
    configDir <- getPurebredConfigDir
    currDir <- getCurrentDirectory
    let binName = purebredCompiledName
        bin = configDir </> binName
        configSrc = configDir </> "config.hs"

    srcT <- getModTime configSrc
    binT <- getModTime bin

    if force || any (binT <) [srcT]
        then do
            status <- waitForProcess =<< compileGHC bin currDir configSrc
            pure (status == ExitSuccess)
        else pure True
  where
    getModTime f = catch (Just <$> getModificationTime f) (\(SomeException _) -> pure Nothing)

-- | Runs GHC to compile the given source file.
-- Note: This is also borrowed from XMonad.Main.hs, with the exception that I've
-- added the possibility to invoke stacks' GHC in case the user is in a stack
-- project. Copying configuration files around for development and (local)
-- testing could otherwise become a nuisance.
compileGHC :: String -> FilePath -> FilePath -> IO ProcessHandle
compileGHC bin cfgdir sourcePath = do
    compiler <- lookupEnv "GHC"
    compiler_opts <- lookupEnv "GHC_ARGS"
    let ghc = fromMaybe "ghc" compiler
    let ghcopts = fromMaybe [] compiler_opts
    runProcess
        ghc
        (words ghcopts <>
         [ "-threaded"
         , "--make"
         , sourcePath
         , "-i"
         , "-ilib"
         , "-fforce-recomp"
         , "-main-is"
         , "main"
         , "-v0"
         , "-o"
         , bin])
        (Just cfgdir)
        Nothing
        Nothing
        Nothing
        Nothing

getPurebredConfigDir :: IO FilePath
getPurebredConfigDir = do
  cfgdir <- lookupEnv "PUREBRED_CONFIG_DIR"
  defaultcfgdir <- getUserConfigDir "purebred"
  pure $ fromMaybe defaultcfgdir cfgdir

purebredCompiledName :: String
purebredCompiledName = "purebred-" ++ arch ++ "-" ++ os
