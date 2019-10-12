{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- Module      : Foreign.CUDA.Config
-- Copyright   : [2019] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : unknown
--

module Foreign.CUDA.Config where

import Distribution.PackageDescription
import Distribution.Simple
import Distribution.Simple.BuildPaths
import Distribution.Simple.Command
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.PreProcess                               hiding ( ppC2hs )
import Distribution.Simple.Program
import Distribution.Simple.Program.Db
import Distribution.Simple.Program.Find
import Distribution.Simple.Setup
import Distribution.Simple.Utils                                    hiding ( isInfixOf )
import Distribution.System
import Distribution.Verbosity

#if MIN_VERSION_Cabal(1,25,0)
import Distribution.PackageDescription.PrettyPrint
import Distribution.Version
#endif
#if MIN_VERSION_Cabal(2,2,0)
import Distribution.PackageDescription.Parsec
#else
import Distribution.PackageDescription.Parse
#endif

import Control.Exception
import Control.Monad
import Data.Function
import Data.List
import Data.Maybe
import System.Directory
import System.Environment
import System.FilePath
import System.IO.Error
import Text.Printf
import Prelude


-- The candidate locations to search for the CUDA installation.
--
cudaInstallPathCandidates
    :: Verbosity
    -> Platform
    -> [(IO (Maybe FilePath), String)]
cudaInstallPathCandidates verbosity (Platform _ os) =
  [ (lookupEnv "CUDA_PATH",       "environment variable CUDA_PATH")
  , (findInPath,                  "nvcc compiler executable in PATH")
  , (return defaultInstallPath,   printf "default install location (%s)" (show defaultInstallPath))
  , (lookupEnv "CUDA_PATH_V10_1", "environment variable CUDA_PATH_V10_1")
  , (lookupEnv "CUDA_PATH_V10_0", "environment variable CUDA_PATH_V10_0")
  , (lookupEnv "CUDA_PATH_V9_2",  "environment variable CUDA_PATH_V9_2")
  , (lookupEnv "CUDA_PATH_V9_1",  "environment variable CUDA_PATH_V9_1")
  , (lookupEnv "CUDA_PATH_V9_0",  "environment variable CUDA_PATH_V9_0")
  , (lookupEnv "CUDA_PATH_V8_0",  "environment variable CUDA_PATH_V8_0")
  , (lookupEnv "CUDA_PATH_V7_5",  "environment variable CUDA_PATH_V7_5")
  , (lookupEnv "CUDA_PATH_V7_0",  "environment variable CUDA_PATH_V7_0")
  , (lookupEnv "CUDA_PATH_V6_5",  "environment variable CUDA_PATH_V6_5")
  , (lookupEnv "CUDA_PATH_V6_0",  "environment variable CUDA_PATH_V6_0")
  ]
  where
    -- The obtained path is likely TOOLKIT/bin/nvcc. We want to extract the TOOLKIT part
    findInPath :: IO (Maybe FilePath)
    findInPath = fmap (takeDirectory . takeDirectory) <$> findProgram verbosity "nvcc"

    defaultInstallPath :: Maybe FilePath
    defaultInstallPath =
      case os of
        Windows -> Nothing
        _       -> Just "/usr/local/cuda"

-- Return the location of the include directory relative to the base CUDA
-- installation.
--
cudaIncludePath :: Platform -> FilePath -> FilePath
cudaIncludePath _ installPath = installPath </> "include"

-- Return the location of the libraries relative to the base CUDA installation.
--
cudaLibraryPath :: Platform -> FilePath -> FilePath
cudaLibraryPath (Platform arch os) installPath = installPath </> libpath
  where
    libpath =
      case (os, arch) of
        (Windows, I386)   -> "lib/Win32"
        (Windows, X86_64) -> "lib/x64"
        (OSX,     _)      -> "lib"    -- MacOS does not distinguish 32- vs. 64-bit paths
        (_,       X86_64) -> "lib64"  -- treat all others similarly
        _                 -> "lib"


-- Try to locate CUDA installation by checking (in order):
--
--  1. CUDA_PATH environment variable
--  2. Looking for `nvcc` in `PATH`
--  3. Checking /usr/local/cuda
--  4. CUDA_PATH_Vx_y environment variable, for recent CUDA toolkit versions x.y
--
-- We don't use 'findProgramOnSearchPath' with the concatenation of all
-- search locations because we also want to verify that the chosen location
-- is valid, and move on to the next if not.
--
-- Prints the long message below if now valid path can be found.
--
cudaInstallPath
    :: Verbosity
    -> Platform
    -> IO (Maybe FilePath)
cudaInstallPath verbosity platform = do
  result <- findFirstValidLocation verbosity platform (cudaInstallPathCandidates verbosity platform)
  case result of
    Just installPath -> notice verbosity $ printf "Found CUDA toolkit at: %s" installPath
    Nothing          -> notice verbosity $ cudaNotFoundMsg
  --
  return result


cudaNotFoundMsg :: String
cudaNotFoundMsg = unlines
  [ "********************************************************************************"
  , ""
  , "The configuration process failed to locate your CUDA installation. Ensure that you have installed both the developer driver and toolkit, available from:"
  , ""
  , "> http://developer.nvidia.com/cuda-downloads"
  , ""
  , "and make sure that `nvcc` is available in your PATH, or set the CUDA_PATH environment variable appropriately. Check the above output log and run the command directly to ensure it can be located."
  , ""
  , "If you have a non-standard installation, you can add additional search paths using --extra-include-dirs and --extra-lib-dirs. Note that 64-bit Linux flavours often require both `lib64` and `lib` library paths, in that order."
  , ""
  , "********************************************************************************"
  ]


-- Check and validate the possible toolkit locations, returning the first
-- one.
--
findFirstValidLocation
    :: Verbosity
    -> Platform
    -> [(IO (Maybe FilePath), String)]
    -> IO (Maybe FilePath)
findFirstValidLocation verbosity platform = go
  where
    go :: [(IO (Maybe FilePath), String)] -> IO (Maybe FilePath)
    go []     = return Nothing
    go (x:xs) = do
      let (location, desc) = x
      info verbosity $ printf "checking for %s" desc
      r <- location `catch` \(e :: IOError) -> do
              info verbosity $ printf "failed: %s" (show e)
              return Nothing
      case r of
        Just path -> validateLocation verbosity platform =<< canonicalizePath path
        Nothing   -> go xs


-- Checks whether given location looks like a valid CUDA toolkit directory
--
-- TODO: Ideally this should check for e.g. libcuda.so/cuda.lib and whether
-- it exports relevant symbols. This should be achievable with some `nm`
-- trickery
--
validateLocation
    :: Verbosity
    -> Platform
    -> FilePath
    -> IO (Maybe FilePath)
validateLocation verbosity platform path = do
  let cudaHeader = cudaIncludePath platform path </> "cuda.h"
  --
  exists <- doesFileExist cudaHeader
  if exists
     then do
       info verbosity $ printf "Path accepted: %s\n" path
       return (Just path)
     else do
       info verbosity $ printf "Path rejected: %s\nDoes not exist: %s\n" path cudaHeader
       return Nothing


findProgram
    :: Verbosity
    -> FilePath
    -> IO (Maybe FilePath)
findProgram verbosity prog =
  postFindProgram <$> findProgramOnSearchPath verbosity defaultProgramSearchPath prog

class PostFindProgram a where
  postFindProgram :: a -> Maybe FilePath

instance PostFindProgram (Maybe (FilePath, [FilePath])) where -- Cabal >= 1.24
  postFindProgram = fmap fst

instance PostFindProgram (Maybe FilePath) where -- Cabal < 1.24
  postFindProgram = id

