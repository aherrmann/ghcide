-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

module Development.IDE.Core.Preprocessor
  ( preprocessor
  ) where

import Development.IDE.GHC.CPP
import Development.IDE.GHC.Orphans()
import Development.IDE.GHC.Compat
import GHC
import GhcMonad
import StringBuffer as SB

import Data.List.Extra
import System.FilePath
import System.IO.Extra
import Data.Char
import DynFlags
import qualified HeaderInfo as Hdr
import Development.IDE.Types.Diagnostics
import Development.IDE.GHC.Error
import SysTools (Option (..), runUnlit)
import Control.Monad.Trans.Except
import qualified GHC.LanguageExtensions as LangExt
import Data.Maybe


-- | Given a file and some contents, apply any necessary preprocessors,
--   e.g. unlit/cpp. Return the resulting buffer and the DynFlags it implies.
preprocessor :: GhcMonad m => FilePath -> Maybe StringBuffer -> ExceptT [FileDiagnostic] m (StringBuffer, DynFlags)
preprocessor filename mbContents = do
    -- Perform unlit
    (isOnDisk, contents) <-
        if isLiterate filename then do
            dflags <- getDynFlags
            newcontent <- liftIO $ runLhs dflags filename mbContents
            return (False, newcontent)
        else do
            contents <- liftIO $ maybe (hGetStringBuffer filename) return mbContents
            let isOnDisk = isNothing mbContents
            return (isOnDisk, contents)

    -- Perform cpp
    dflags  <- ExceptT $ parsePragmasIntoDynFlags filename contents
    if not $ xopt LangExt.Cpp dflags then
        return (contents, dflags)
    else do
        contents <- liftIO $ runCpp dflags filename $ if isOnDisk then Nothing else Just contents
        dflags <- ExceptT $ parsePragmasIntoDynFlags filename contents
        return (contents, dflags)


isLiterate :: FilePath -> Bool
isLiterate x = takeExtension x `elem` [".lhs",".lhs-boot"]


-- | This reads the pragma information directly from the provided buffer.
parsePragmasIntoDynFlags
    :: GhcMonad m
    => FilePath
    -> SB.StringBuffer
    -> m (Either [FileDiagnostic] DynFlags)
parsePragmasIntoDynFlags fp contents = catchSrcErrors "pragmas" $ do
    dflags0  <- getSessionDynFlags
    let opts = Hdr.getOptions dflags0 contents fp
    (dflags, _, _) <- parseDynamicFilePragma dflags0 opts
    return dflags


-- | Run (unlit) literate haskell preprocessor on a file, or buffer if set
runLhs :: DynFlags -> FilePath -> Maybe SB.StringBuffer -> IO SB.StringBuffer
runLhs dflags filename contents = withTempDir $ \dir -> do
    let fout = dir </> takeFileName filename <.> "unlit"
    filesrc <- case contents of
        Nothing   -> return filename
        Just cnts -> do
            let fsrc = dir </> takeFileName filename <.> "literate"
            withBinaryFile fsrc WriteMode $ \h ->
                hPutStringBuffer h cnts
            return fsrc
    unlit filesrc fout
    SB.hGetStringBuffer fout
  where
    unlit filein fileout = SysTools.runUnlit dflags (args filein fileout)
    args filein fileout = [
                      SysTools.Option     "-h"
                    , SysTools.Option     (escape filename) -- name this file
                    , SysTools.FileOption "" filein       -- input file
                    , SysTools.FileOption "" fileout ]    -- output file
    -- taken from ghc's DriverPipeline.hs
    escape ('\\':cs) = '\\':'\\': escape cs
    escape ('\"':cs) = '\\':'\"': escape cs
    escape ('\'':cs) = '\\':'\'': escape cs
    escape (c:cs)    = c : escape cs
    escape []        = []


-- | Run CPP on a file
runCpp :: DynFlags -> FilePath -> Maybe SB.StringBuffer -> IO SB.StringBuffer
runCpp dflags filename contents = withTempDir $ \dir -> do
    let out = dir </> takeFileName filename <.> "out"
    case contents of
        Nothing -> do
            -- Happy case, file is not modified, so run CPP on it in-place
            -- which also makes things like relative #include files work
            -- and means location information is correct
            doCpp dflags True filename out
            liftIO $ SB.hGetStringBuffer out

        Just contents -> do
            -- Sad path, we have to create a version of the path in a temp dir
            -- __FILE__ macro is wrong, ignoring that for now (likely not a real issue)

            -- Relative includes aren't going to work, so we fix that by adding to the include path.
            dflags <- return $ addIncludePathsQuote (takeDirectory filename) dflags

            -- Location information is wrong, so we fix that by patching it afterwards.
            let inp = dir </> "___GHCIDE_MAGIC___"
            withBinaryFile inp WriteMode $ \h ->
                hPutStringBuffer h contents
            doCpp dflags True inp out

            -- Fix up the filename in lines like:
            -- # 1 "C:/Temp/extra-dir-914611385186/___GHCIDE_MAGIC___"
            let tweak x
                    | Just x <- stripPrefix "# " x
                    , "___GHCIDE_MAGIC___" `isInfixOf` x
                    , let num = takeWhile (not . isSpace) x
                    -- important to use /, and never \ for paths, even on Windows, since then C escapes them
                    -- and GHC gets all confused
                        = "# " <> num <> " \"" <> map (\x -> if isPathSeparator x then '/' else x) filename <> "\""
                    | otherwise = x
            stringToStringBuffer . unlines . map tweak . lines <$> readFileUTF8' out