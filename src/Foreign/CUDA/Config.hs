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

module Foreign.CUDA.Config (

  cudaInstallPath,
  cudaIncludePath,
  cudaLibraryPath,
  cudaUserHooks,

) where

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
import qualified Distribution.InstalledPackageInfo                  as Installed
import qualified Distribution.Simple.PackageIndex                   as PackageIndex

#if MIN_VERSION_Cabal(1,25,0)
import Distribution.PackageDescription.PrettyPrint
import Distribution.Version
#endif
#if MIN_VERSION_Cabal(2,2,0)
import Distribution.PackageDescription.Parsec
#else
import Distribution.PackageDescription.Parse
#endif

import Control.Applicative
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


{--}
cudaUserHooks :: String -> UserHooks
cudaUserHooks name = simpleUserHooks
  { preBuild            = preBuildHook
  , preClean            = readHook cleanVerbosity
  , preCopy             = readHook copyVerbosity
  , preInst             = readHook installVerbosity
  , preHscolour         = readHook hscolourVerbosity
  , preHaddock          = readHook haddockVerbosity
  , preReg              = readHook regVerbosity
  , preUnreg            = readHook regVerbosity
  , postConf            = postConfHook
  , postBuild           = postBuildHook
  , hookedPreProcessors = ("chs", pp_c2hs) : filter (\x -> fst x /= "chs") preprocessors
  }
  where
    -- Our readHook implementation uses our getHookedBuildInfo. We can't
    -- rely on cabal's autoconfUserHooks since they don't handle user
    -- overwrites to buildinfo like we do.
    --
    readHook hookVerbosity args flags = do
        noExtraFlags args
        getHookedBuildInfo (fromFlag (hookVerbosity flags)) name

    preprocessors = hookedPreProcessors simpleUserHooks

    -- The hook just loads the HookedBuildInfo generated by postConfHook, unless
    -- there is user-provided info that overwrites it.
    --
    preBuildHook :: Args -> BuildFlags -> IO HookedBuildInfo
    preBuildHook _ flags = getHookedBuildInfo (fromFlag (buildVerbosity flags)) name

    -- The hook scans system in search for CUDA Toolkit. If the toolkit is not
    -- found, an error is raised. Otherwise the toolkit location is used to
    -- create a `X.buildinfo.generated` file with all the resulting flags.
    --
    postConfHook :: Args -> ConfigFlags -> PackageDescription -> LocalBuildInfo -> IO ()
    postConfHook args flags pkg_descr lbi = do
      let
          verbosity       = fromFlagOrDefault normal (configVerbosity flags)
          profile         = fromFlagOrDefault False  (configProfLib flags)
          currentPlatform = hostPlatform lbi
          compilerId'     = compilerId (compiler lbi)
      --
      noExtraFlags args
      -- generateAndStoreBuildInfo
      --     verbosity
      --     profile
      --     currentPlatform
      --     compilerId'
      --     (configExtraLibDirs flags)
      --     (configExtraIncludeDirs flags)
      --     generatedBuildInfoFilePath
      validateLinker verbosity currentPlatform $ withPrograms lbi
      --
      actualBuildInfoToUse <- getHookedBuildInfo verbosity name
      let pkg_descr' = updatePackageDescription actualBuildInfoToUse pkg_descr
      postConf simpleUserHooks args flags pkg_descr' lbi

    -- This hook fixes the embedded LC_RPATHs in the generated .dylib on OSX.
    postBuildHook :: Args -> BuildFlags -> PackageDescription -> LocalBuildInfo -> IO ()
    postBuildHook _ flags pkg_descr lbi = do
      return ()
      let
          verbosity           = fromFlag (buildVerbosity flags)
          platform            = hostPlatform lbi
          cid                 = compilerId (compiler lbi)
#if MIN_VERSION_Cabal(1,24,0)
          uid                 = localUnitId lbi
#else
          uid                 = head (componentLibraries (getComponentLocalBuildInfo lbi CLibName))
#endif
#if MIN_VERSION_Cabal(2,3,0)
          sharedLib           = buildDir lbi </> mkSharedLibName platform cid uid
#else
          sharedLib           = buildDir lbi </> mkSharedLibName          cid uid
#endif
          Just extraLibDirs'  = extraLibDirs . libBuildInfo <$> library pkg_descr
      --
      updateLibraryRPATHs verbosity platform sharedLib extraLibDirs'


-- | Return the location of the include directory relative to the base CUDA
-- installation
--
cudaIncludePath :: Platform -> FilePath -> FilePath
cudaIncludePath _ installPath = installPath </> "include"

-- | Return the location of the libraries relative to the base CUDA installation.
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

-- | Try to locate CUDA installation by checking (in order):
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
-- Prints the long message below and returns Nothing if no valid path can
-- be found.
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


      -- escape_backslash :: FilePath -> FilePath
      -- escape_backslash path =
      --   let esc []        = []
      --       esc ('\\':fs) = '\\' : '\\' : esc fs
      --       esc (f:fs)    = f           : esc fs
      --   in
      --   case os of
      --     Windows -> esc path
      --     _       -> path


-- Generates build info with flags needed for CUDA toolkit to be properly
-- visible to underlying build tools. Extra options may be required for specific
-- CUDA libraries.
--
hookedBuildInfo
    :: Verbosity
    -> Bool
    -> FilePath
    -> Platform
    -> Version
    -> [FilePath]
    -> [FilePath]
    -> IO HookedBuildInfo
hookedBuildInfo verbosity profile installPath platform@(Platform arch os) ghcVersion extraLibDirs' extraIncludeDirs' = do
  let
      ccOptions'        = map ("-I"++) extraIncludeDirs'
      ldOptions'        = map ("-L" ++) extraLibDirs'
      ghcOptions        = map ("-optc"++) ccOptions'
                       ++ map ("-optl"++) ldOptions'
                       ++ if os /= Windows && not profile
                            then map ("-optl-Wl,-rpath,"++) extraLibDirs'
                            else []

#if MIN_VERSION_Cabal(3,0,0)
      options'          = if os /= Windows
                             then PerCompilerFlavor ghcOptions []
                             else PerCompilerFlavor []         []
#else
      options'          = [(GHC, ghcOptions) | os /= Windows]
#endif

      -- options for C2HS
      archFlag          = case arch of
                            I386   -> "-m32"
                            X86_64 -> "-m64"
                            _      -> ""
      emptyCase         = ["-DUSE_EMPTY_CASE" | versionBranch ghcVersion >= [7,8]]
      blocksExtension   = ["-U__BLOCKS__" | os == OSX ]
      c2hsOptions       = unwords $ map ("--cppopts="++) ("-E" : archFlag : emptyCase ++ blocksExtension)
      c2hsExtraOptions  = ("x-extra-c2hs-options", c2hsOptions)

      buildInfo'        = emptyBuildInfo
        { ccOptions       = ccOptions'
        , ldOptions       = ldOptions'
        , options         = options'
        , customFieldsBI  = [c2hsExtraOptions]
        }

  return (Just buildInfo', [])


-- Reads user-provided `X.buildinfo` if present, otherwise loads
-- `X.buildinfo.generated`
--
-- Outputs message informing about the other possibility. Calls die when neither
-- of the files is available (the generated one should be always present, as it
-- is created in the post-conf step)
--
getHookedBuildInfo
    :: Verbosity
    -> String
    -> IO HookedBuildInfo
getHookedBuildInfo verbosity name = do
  let
      customBuildInfoFilePath     = name                    <.> "buildInfo"
      generatedBuildInfoFilePath  = customBuildInfoFilePath <.> "generated"
  --
  doesCustomBuildInfoExists <- doesFileExist customBuildInfoFilePath
  if doesCustomBuildInfoExists
    then do
      notice verbosity $ printf "The user-provided buildinfo from file %s will be used. To use default settings, delete this file.\n" customBuildInfoFilePath
      readHookedBuildInfo verbosity customBuildInfoFilePath
    else do
      doesGeneratedBuildInfoExists <- doesFileExist generatedBuildInfoFilePath
      if doesGeneratedBuildInfoExists
        then do
          notice verbosity $ printf "Using build information from '%s'.\n" generatedBuildInfoFilePath
          notice verbosity $ printf "Provide a '%s' file to override this behaviour.\n" customBuildInfoFilePath
          readHookedBuildInfo verbosity generatedBuildInfoFilePath
        else
          die' verbosity $ printf "Unexpected failure. Neither the default %s nor custom %s exist.\n" generatedBuildInfoFilePath customBuildInfoFilePath


-- On Windows platform the binutils linker targeting x64 is bugged and
-- cannot properly link with import libraries generated by MS compiler
-- (like the CUDA ones). The programs would correctly compile and crash as
-- soon as the first FFI call is made.
--
-- Therefore we fail configure process if the linker is too old and provide
-- user with guidelines on how to fix the problem.
--
validateLinker
      :: Verbosity
      -> Platform
      -> ProgramDb
      -> IO ()
validateLinker verbosity platform db =
  when (platform == Platform X86_64 Windows) $ do
    maybeLdPath <- getRealLdPath verbosity db
    let warning msg = printf "%s. If generated executables crash when making calls to CUDA please see: %s" msg windowsHelpPage
    case maybeLdPath of
      Nothing     -> warn verbosity $ warning "Cannot find ld.exe to check if it is new enough"
      Just ldPath -> do
        debug verbosity $ "Checking if ld.exe at " ++ ldPath ++ " is new enough"
        maybeVersion <- getLdVersion verbosity ldPath
        case maybeVersion of
          Nothing        -> warn verbosity $ warning "Unknown ld.exe version"
          Just ldVersion -> do
            debug verbosity $ "Found ld.exe version: " ++ show ldVersion
            when (ldVersion < [2,25,1]) $ die' verbosity (windowsLinkerBugMsg ldPath)

-- Tries to obtain the version `ld`
--
getLdVersion :: Verbosity -> FilePath -> IO (Maybe [Int])
getLdVersion verbosity ldPath = do
  -- Version string format is like `GNU ld (GNU Binutils) 2.25.1`
  --                            or `GNU ld (GNU Binutils) 2.20.51.20100613`
  ldVersionString <- getProgramInvocationOutput normal (simpleProgramInvocation ldPath ["-v"])

  let versionText   = last $ words ldVersionString -- takes e. g. "2.25.1"
      versionParts  = splitOn (== '.') versionText
      versionParsed = parse versionParts
        where
          parse []
            = Just []
          parse (x:xs)
            | [(n,[])] <- reads x
            , Just ns  <- parse xs
            = Just (n:ns)
            | otherwise
            = Nothing

      -- Slightly modified version of `words` from base - it takes predicate saying on
      -- which characters split.
      --
      splitOn :: (Char -> Bool) -> String -> [String]
      splitOn p s =
        case dropWhile p s of
          [] -> []
          s' -> let (w, s'') = break p s'
                in  w : splitOn p s''

  when (isNothing versionParsed) $
    warn verbosity $ printf "cannot parse ld version string: `%s'" ldVersionString
  return versionParsed

-- On Windows GHC package comes with two copies of ld.exe.
--
--  1. ProgramDb knows about the first one: ghcpath\mingw\bin\ld.exe
--  2. This function returns the other one: ghcpath\mingw\x86_64-w64-mingw32\bin\ld.exe
--
-- The second one is the one that does actual linking and code generation.
-- See: https://github.com/tmcdonell/cuda/issues/31#issuecomment-149181376
--
-- The function is meant to be used only on 64-bit GHC distributions.
--
getRealLdPath :: Verbosity -> ProgramDb -> IO (Maybe FilePath)
getRealLdPath verbosity programDb =
  -- TODO: This should ideally work `programFindVersion ldProgram` but for some
  -- reason it does not. The issue should be investigated at some time.
  --
  case lookupProgram ghcProgram programDb of
    Nothing            -> return Nothing
    Just configuredGhc -> do
      let ghcPath        = locationPath $ programLocation configuredGhc
          presumedLdPath = (takeDirectory . takeDirectory) ghcPath </> "mingw" </> "x86_64-w64-mingw32" </> "bin" </> "ld.exe"
      --
      info verbosity $ "Presuming ld location" ++ presumedLdPath
      presumedLdExists <- doesFileExist presumedLdPath
      return $ if presumedLdExists
                  then Just presumedLdPath
                  else Nothing

windowsHelpPage :: String
windowsHelpPage = "https://github.com/tmcdonell/cuda/blob/master/WINDOWS.markdown"

windowsLinkerBugMsg :: FilePath -> String
windowsLinkerBugMsg ldPath = printf (unlines msg) windowsHelpPage ldPath
  where
    msg =
      [ "********************************************************************************"
      , ""
      , "The installed version of `ld.exe` has version < 2.25.1. This version has known bug on Windows x64 architecture, making it unable to correctly link programs using CUDA. The fix is available and MSys2 released fixed version of `ld.exe` as part of their binutils package (version 2.25.1)."
      , ""
      , "To fix this issue, replace the `ld.exe` in your GHC installation with the correct binary. See the following page for details:"
      , ""
      , "  %s"
      , ""
      , "The full path to the outdated `ld.exe` detected in your installation:"
      , ""
      , "> %s"
      , ""
      , "Please download a recent version of binutils `ld.exe`, from, e.g.:"
      , ""
      , "  http://repo.msys2.org/mingw/x86_64/mingw-w64-x86_64-binutils-2.25.1-1-any.pkg.tar.xz"
      , ""
      , "********************************************************************************"
      ]


-- It seems that the GHC and/or Cabal developers don't quite understand how
-- dynamic linking works on OSX. Even though we have specified
-- '-optl-Wl,-rpath,...' as part of the configuration, this (sometimes?)
-- gets filtered out somewhere, and the resulting .dylib that is generated
-- does not have this path embedded as an LC_RPATH. The result is that the
-- foreign library will not be found, resulting in a link-time error.
--
-- On *nix (and versions of OSX previous to El Capitan 10.11), we could use
-- [DY]LD_LIBRARY_PATH to specify where to resolve @rpath locations, but
-- that is no longer an option on OSX due to System Integrity Protection.
--
-- An alternate argument is that the CUDA installer should have updated the
-- install name (LC_ID_DYLIB) of its dynamic libraries to include the full
-- absolute path, rather than relying on @rpath in the first place, which
-- is what Apple's system libraries do, for example.
--
updateLibraryRPATHs :: Verbosity -> Platform -> FilePath -> [FilePath] -> IO ()
updateLibraryRPATHs verbosity (Platform _ os) sharedLib extraLibDirs' =
  when (os == OSX) $ do
    exists <- doesFileExist sharedLib
    unless exists $ die' verbosity $ printf "Unexpected failure: library does not exist: %s" sharedLib
    --
    mint   <- findProgram verbosity "install_name_tool"
    case mint of
      Nothing                -> notice verbosity $ "Could not locate 'install_name_tool' in order to update LC_RPATH entries. This is likely to cause problems later on."
      Just install_name_tool ->
        forM_ extraLibDirs' $ \libDir ->
          runProgramInvocation verbosity $ simpleProgramInvocation install_name_tool ["-add_rpath", libDir, sharedLib]


-- Replicate the default C2HS preprocessor hook here, and inject a value for
-- extra-c2hs-options, if it was present in the buildinfo file
--
class PPC2HS f where
  pp_c2hs :: f

#if !MIN_VERSION_Cabal(2,0,0)
instance PPC2HS (BuildInfo -> LocalBuildInfo -> PreProcessor) where
  pp_c2hs bi lbi =
    let clbi = getComponentLocalBuildInfo lbi CLibName
     in pp_c2hs bi lbi clbi
#endif

instance PPC2HS (BuildInfo -> LocalBuildInfo -> ComponentLocalBuildInfo -> PreProcessor) where
  pp_c2hs bi lbi clbi =
    PreProcessor
      { platformIndependent = False
      , runPreProcessor     = \(inBaseDir, inRelativeFile) (outBaseDir, outRelativeFile) verbosity -> do
          (c2hsProg, _, _) <- requireProgramVersion verbosity
                                c2hsProgram (orLaterVersion (mkVersion [0,15]))
                                (withPrograms lbi)
          (gccProg, _) <- requireProgram verbosity gccProgram (withPrograms lbi)

          runProgram verbosity c2hsProg $

              -- options from .buildinfo file
            maybe [] words (lookup "x-extra-c2hs-options" (customFieldsBI bi))

              -- Options from the current package:
            ++ [ "--cpp=" ++ programPath gccProg, "--cppopts=-E" ]
            ++ [ "--cppopts=" ++ opt | opt <- getCppOptions bi lbi ]
            ++ [ "--cppopts=-include" ++ (autogenComponentModulesDir lbi clbi </> cppHeaderName) ]
            ++ [ "--include=" ++ outBaseDir ]

              -- Options from dependent packages
           ++ [ "--cppopts=" ++ opt
              | pkg <- pkgs
              , opt <- [ "-I" ++ opt | opt <- Installed.includeDirs pkg ]
                    ++ [         opt | opt@('-':c:_) <- Installed.ccOptions pkg
                                                     -- c2hs uses the C ABI
                                                     -- We assume that there are only C sources
                                                     -- and C++ functions are exported via a C
                                                     -- interface and wrapped in a C source file.
                                                     -- Therefore we do not supply C++ flags
                                                     -- because there will not be C++ sources.
                                                     --
                                                     --
                                                     -- DO NOT add Installed.cxxOptions unless this changes!
                                     , c `elem` "DIU" ] ]
              --TODO: install .chi files for packages, so we can --include
              -- those dirs here, for the dependencies

               -- input and output files
            ++ [ "--output-dir=" ++ outBaseDir
               , "--output=" ++ outRelativeFile
               , inBaseDir </> inRelativeFile ]
      }
      where
        pkgs = PackageIndex.topologicalOrder (installedPkgs lbi)

getCppOptions :: BuildInfo -> LocalBuildInfo -> [String]
getCppOptions bi lbi
    = hcDefines (compiler lbi)
   ++ ["-I" ++ dir | dir <- includeDirs bi]
   ++ [opt | opt@('-':c:_) <- ccOptions bi, c `elem` "DIU"]

hcDefines :: Compiler -> [String]
hcDefines comp =
  case compilerFlavor comp of
    GHC  -> ["-D__GLASGOW_HASKELL__=" ++ versionInt version]
    JHC  -> ["-D__JHC__=" ++ versionInt version]
    NHC  -> ["-D__NHC__=" ++ versionInt version]
    Hugs -> ["-D__HUGS__"]
    _    -> []
  where version = compilerVersion comp

versionInt :: Version -> String
versionInt v =
  case versionBranch v of
    []      -> "1"
    [n]     -> show n
    n1:n2:_ -> printf "%d%02d" n1 n2

#if MIN_VERSION_Cabal(1,25,0)
versionBranch :: Version -> [Int]
versionBranch = versionNumbers
#endif

#if !MIN_VERSION_Cabal(2,0,0)
mkVersion :: [Int] -> Version
mkVersion xs = Version xs []

autogenComponentModulesDir :: LocalBuildInfo -> ComponentLocalBuildInfo -> String
autogenComponentModulesDir lbi clbi = componentBuildDir lbi clbi </> "autogen"

componentBuildDir :: LocalBuildInfo -> ComponentLocalBuildInfo -> String
componentBuildDir lbi clbi = buildDir lbi -- </> other stuff depending on the component name

die' :: Verbosity -> String -> IO a
die' _ = die
#endif

