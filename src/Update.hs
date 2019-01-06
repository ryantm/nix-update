{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Update
  ( updateAll
  ) where

import OurPrelude

import qualified Blacklist
import qualified Check
import Control.Exception (SomeException)
import Control.Exception.Lifted
import Data.IORef
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified File
import qualified GH
import qualified Git
import qualified Nix
import Outpaths
import Prelude hiding (FilePath, log)
import qualified Shell
import Shelly.Lifted
import qualified Time
import Utils
  ( Options(..)
  , UpdateEnv(..)
  , Version
  , branchName
  , parseUpdates
  , tRead
  )
import qualified Version

default (T.Text)

data MergeBaseOutpathsInfo = MergeBaseOutpathsInfo
  { lastUpdated :: UTCTime
  , mergeBaseOutpaths :: Set ResultLine
  }

log' :: (MonadIO m, MonadSh m) => FilePath -> Text -> m ()
log' logFile msg = do
  runDate <- Time.runDate
  appendfile logFile (runDate <> " " <> msg <> "\n")

updateAll :: Options -> Text -> IO ()
updateAll o updates = do
  Shell.ourShell o $ do
    let logFile = fromText (workingDir o) </> "ups.log"
    mkdir_p (fromText (workingDir o))
    touchfile logFile
    let log = log' logFile
    appendfile logFile "\n\n"
    log "New run of ups.sh"
    twoHoursAgo <- Time.twoHoursAgo
    mergeBaseOutpathSet <-
      liftIO $ newIORef (MergeBaseOutpathsInfo twoHoursAgo S.empty)
    updateLoop o log (parseUpdates updates) mergeBaseOutpathSet

updateLoop ::
     Options
  -> (Text -> Sh ())
  -> [Either Text (Text, Version, Version)]
  -> IORef MergeBaseOutpathsInfo
  -> Sh ()
updateLoop _ log [] _ = log "ups.sh finished"
updateLoop o log (Left e:moreUpdates) mergeBaseOutpathsContext = do
  log e
  updateLoop o log moreUpdates mergeBaseOutpathsContext
updateLoop o log (Right (pName, oldVer, newVer):moreUpdates) mergeBaseOutpathsContext = do
  log (pName <> " " <> oldVer <> " -> " <> newVer)
  let updateEnv = UpdateEnv pName oldVer newVer o
  updated <- updatePackage log updateEnv mergeBaseOutpathsContext
  case updated of
    Left failure -> do
      liftIO $ Git.cleanup (branchName updateEnv)
      log $ "FAIL " <> failure
      if ".0" `T.isSuffixOf` newVer
        then let Just newNewVersion = ".0" `T.stripSuffix` newVer
              in updateLoop
                   o
                   log
                   (Right (pName, oldVer, newNewVersion) : moreUpdates)
                   mergeBaseOutpathsContext
        else updateLoop o log moreUpdates mergeBaseOutpathsContext
    Right _ -> do
      log "SUCCESS"
      updateLoop o log moreUpdates mergeBaseOutpathsContext

updatePackage ::
     (Text -> Sh ())
  -> UpdateEnv
  -> IORef MergeBaseOutpathsInfo
  -> Sh (Either Text ())
updatePackage log updateEnv mergeBaseOutpathsContext =
  runExceptT $
  flip catches [Handler (\(ex :: SomeException) -> throwE (T.pack (show ex)))] $ do
    Blacklist.packageName (packageName updateEnv)
    Nix.assertNewerVersion updateEnv
    Git.fetchIfStale
    Git.checkAutoUpdateBranchDoesntExist (packageName updateEnv)
    Git.cleanAndResetTo "master"
    attrPath <- Nix.lookupAttrPath updateEnv
    Blacklist.attrPath attrPath
    Version.assertCompatibleWithPathPin updateEnv attrPath
    srcUrls <- Nix.getSrcUrls attrPath
    Blacklist.srcUrl srcUrls
    derivationFile <- Nix.getDerivationFile attrPath
    assertNotUpdatedOn updateEnv derivationFile "master"
    assertNotUpdatedOn updateEnv derivationFile "staging"
    assertNotUpdatedOn updateEnv derivationFile "staging-next"
    assertNotUpdatedOn updateEnv derivationFile "python-unstable"
    lift $ Git.checkoutAtMergeBase (branchName updateEnv)
    oneHourAgo <- Time.oneHourAgo
    mergeBaseOutpathsInfo <- liftIO $ readIORef mergeBaseOutpathsContext
    mergeBaseOutpathSet <-
      if lastUpdated mergeBaseOutpathsInfo < oneHourAgo
        then do
          mbos <- ExceptT currentOutpathSet
          now <- liftIO getCurrentTime
          liftIO $
            writeIORef mergeBaseOutpathsContext (MergeBaseOutpathsInfo now mbos)
          return mbos
        else return $ mergeBaseOutpaths mergeBaseOutpathsInfo
    derivationContents <- lift $ readfile derivationFile
    Nix.assertOneOrFewerFetcher derivationContents derivationFile
    Blacklist.content derivationContents
    oldHash <- Nix.getOldHash attrPath
    oldSrcUrl <- Nix.getSrcUrl attrPath
    lift $
      File.replace (oldVersion updateEnv) (newVersion updateEnv) derivationFile
    newSrcUrl <- Nix.getSrcUrl attrPath
    when (oldSrcUrl == newSrcUrl) $ throwE "Source url did not change."
    lift $ File.replace oldHash Nix.sha256Zero derivationFile
    newHash <-
      Nix.getHashFromBuild (attrPath <> ".src") <|>
      Nix.getHashFromBuild attrPath -- <|>
               -- lift (fixSrcUrl updateEnv derivationFile attrPath oldSrcUrl) <|>
               -- throwE "Could not get new hash."
    tryAssert ("Hashes equal; no update necessary") (oldHash /= newHash)
    lift $ File.replace Nix.sha256Zero newHash derivationFile
    editedOutpathSet <- ExceptT currentOutpathSet
    let opDiff = S.difference mergeBaseOutpathSet editedOutpathSet
    let numPRebuilds = numPackageRebuilds opDiff
    when
      (numPRebuilds > 10 &&
       "buildPythonPackage" `T.isInfixOf` derivationContents)
      (throwE $
       "Python package with too many package rebuilds " <>
       (T.pack . show) numPRebuilds <>
       "  > 10")
    Nix.build attrPath
    result <- Nix.resultLink
    publishPackage log updateEnv oldSrcUrl newSrcUrl attrPath result opDiff

publishPackage ::
     (Text -> Sh ())
  -> UpdateEnv
  -> Text
  -> Text
  -> Text
  -> FilePath
  -> Set ResultLine
  -> ExceptT Text Sh ()
publishPackage log updateEnv oldSrcUrl newSrcUrl attrPath result opDiff = do
  lift $ log ("cachix " <> (T.pack . show) result)
  lift $ Nix.cachix result
  resultCheckReport <-
    case Blacklist.checkResult (packageName updateEnv) of
      Right () -> lift $ sub (Check.result updateEnv result)
      Left msg -> pure msg
  d <- Nix.getDescription attrPath
  let metaDescription =
        "\n\nmeta.description for " <> attrPath <> " is: '" <> d <> "'."
  releaseUrlMessage <-
    (do msg <- GH.releaseUrl newSrcUrl
        return ("\n[Release on GitHub](" <> msg <> ")\n\n")) <|>
    return ""
  compareUrlMessage <-
    (do msg <- GH.compareUrl oldSrcUrl newSrcUrl
        return ("\n[Compare changes on GitHub](" <> msg <> ")\n\n")) <|>
    return "\n"
  maintainers <- Nix.getMaintainers attrPath
  let maintainersCc =
        if not (T.null maintainers)
          then "\n\ncc " <> maintainers <> " for testing."
          else ""
  let commitMsg = commitMessage updateEnv attrPath
  Shell.shellyET $ Git.commit commitMsg
  commitHash <- lift Git.headHash
  -- Try to push it three times
  Git.push updateEnv <|> Git.push updateEnv <|> Git.push updateEnv
  isBroken <- Nix.getIsBroken attrPath
  lift untilOfBorgFree
  let base =
        if numPackageRebuilds opDiff < 100
          then "master"
          else "staging"
  lift $
    GH.pr
      base
      (prMessage
         updateEnv
         isBroken
         metaDescription
         releaseUrlMessage
         compareUrlMessage
         resultCheckReport
         commitHash
         attrPath
         maintainersCc
         result
         (outpathReport opDiff))
  liftIO $ Git.cleanAndResetTo "master"

repologyUrl :: UpdateEnv -> Text
repologyUrl updateEnv =
  [interpolate|https://repology.org/metapackage/$pname/versions|]
  where
    pname = updateEnv & packageName & T.toLower

commitMessage :: UpdateEnv -> Text -> Text
commitMessage updateEnv attrPath =
  let oV = oldVersion updateEnv
      nV = newVersion updateEnv
      repologyLink = repologyUrl updateEnv
   in [interpolate|
       $attrPath: $oV -> $nV

       Semi-automatic update generated by
       https://github.com/ryantm/nixpkgs-update tools. This update was made
       based on information from
       $repologyLink
     |]

brokenWarning :: Bool -> Text
brokenWarning False = ""
brokenWarning True =
  "- WARNING: Package has meta.broken=true; Please manually test this package update and remove the broken attribute."

prMessage ::
     UpdateEnv
  -> Bool
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> FilePath
  -> Text
  -> Text
prMessage updateEnv isBroken metaDescription releaseUrlMessage compareUrlMessage resultCheckReport commitHash attrPath maintainersCc resultPath opReport =
  let brokenMsg = brokenWarning isBroken
      oV = oldVersion updateEnv
      nV = newVersion updateEnv
      repologyLink = repologyUrl updateEnv
      result = toTextIgnore resultPath
   in [interpolate|
       $attrPath: $oV -> $nV

       Semi-automatic update generated by https://github.com/ryantm/nixpkgs-update tools. This update was made based on information from $repologyLink.
       $brokenMsg
       $metaDescription
       $releaseUrlMessage
       $compareUrlMessage
       <details>
       <summary>
       Checks done (click to expand)
       </summary>

       - built on NixOS
       $resultCheckReport

       </details>
       <details>
       <summary>
       Rebuild report (if merged into master) (click to expand)
       </summary>

       $opReport

       </details>

       <details>
       <summary>
       Instructions to test this update (click to expand)
       </summary>

       Either download from Cachix:
       ```
       nix-store -r $result \
         --option binary-caches 'https://cache.nixos.org/ https://r-ryantm.cachix.org/' \
         --option trusted-public-keys '
         r-ryantm.cachix.org-1:gkUbLkouDAyvBdpBX0JOdIiD2/DP1ldF3Z3Y6Gqcc4c=
         cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
         '
       ```
       (r-ryantm's Cachix cache is only trusted for this store-path realization.)

       Or, build yourself:
       ```
       nix-build -A $attrPath https://github.com/r-ryantm/nixpkgs/archive/$commitHash.tar.gz
       ```

       After you've downloaded or built it, look at the files and if there are any, run the binaries:
       ```
       ls -la $result
       ls -la $result/bin
       ```


       </details>
       <br/>
       $maintainersCc
    |]

untilOfBorgFree :: Sh ()
untilOfBorgFree = do
  waiting :: Int <-
    tRead <$>
    Shell.canFail
      (cmd "curl" "-s" "https://events.nix.ci/stats.php" -|-
       cmd "jq" ".evaluator.messages.waiting")
  when (waiting > 2) $ do
    sleep 60
    untilOfBorgFree

assertNotUpdatedOn :: UpdateEnv -> FilePath -> Text -> ExceptT Text Sh ()
assertNotUpdatedOn updateEnv derivationFile branch = do
  Git.cleanAndResetTo branch
  derivationContents <- lift $ readfile derivationFile
  Nix.assertOldVersionOn updateEnv branch derivationContents
