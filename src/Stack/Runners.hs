{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Utilities for running stack commands.
module Stack.Runners
    ( withGlobalConfigAndLock
    , withConfigAndLock
    , withMiniConfigAndLock
    , withBuildConfigAndLock
    , withDefaultBuildConfigAndLock
    , withCleanConfig
    , withBuildConfig
    , withDefaultBuildConfig
    , withBuildConfigExt
    , withBuildConfigDot
    , loadConfigWithOpts
    , loadCompilerVersion
    , withUserFileLock
    , munlockFile
    , withRunnerGlobal
    ) where

import           Stack.Prelude
import           Path
import           Path.IO
import           Stack.Build.Target(NeedTargets(..))
import           Stack.Config
import           Stack.Constants
import           Stack.DefaultColorWhen (defaultColorWhen)
import qualified Stack.Docker as Docker
import qualified Stack.Nix as Nix
import           Stack.Setup
import           Stack.Types.Config
import           Stack.Types.Runner
import           System.Environment (getEnvironment)
import           System.IO
import           System.FileLock
import           Stack.Dot

-- FIXME it seems wrong that we call lcLoadBuildConfig multiple times
loadCompilerVersion :: GlobalOpts
                    -> LoadConfig
                    -> IO WantedCompiler
loadCompilerVersion go lc =
    view wantedCompilerVersionL <$> lcLoadBuildConfig lc (globalCompiler go)

-- | Enforce mutual exclusion of every action running via this
-- function, on this path, on this users account.
--
-- A lock file is created inside the given directory.  Currently,
-- stack uses locks per-snapshot.  In the future, stack may refine
-- this to an even more fine-grain locking approach.
--
withUserFileLock :: MonadUnliftIO m
                 => GlobalOpts
                 -> Path Abs Dir
                 -> (Maybe FileLock -> m a)
                 -> m a
withUserFileLock go@GlobalOpts{} dir act = do
    env <- liftIO getEnvironment
    let toLock = lookup "STACK_LOCK" env == Just "true"
    if toLock
        then do
            let lockfile = relFileLockfile
            let pth = dir </> lockfile
            ensureDir dir
            -- Just in case of asynchronous exceptions, we need to be careful
            -- when using tryLockFile here:
            bracket (liftIO $ tryLockFile (toFilePath pth) Exclusive)
                    (maybe (return ()) (liftIO . unlockFile))
                    (\fstTry ->
                        case fstTry of
                          Just lk -> finally (act $ Just lk) (liftIO $ unlockFile lk)
                          Nothing ->
                            do let chatter = globalLogLevel go /= LevelOther "silent"
                               when chatter $
                                 liftIO $ hPutStrLn stderr $ "Failed to grab lock ("++show pth++
                                                     "); other stack instance running.  Waiting..."
                               bracket (liftIO $ lockFile (toFilePath pth) Exclusive)
                                       (liftIO . unlockFile)
                                       (\lk -> do
                                            when chatter $
                                              liftIO $ hPutStrLn stderr "Lock acquired, proceeding."
                                            act $ Just lk))
        else act Nothing

withConfigAndLock
    :: GlobalOpts
    -> RIO Config ()
    -> IO ()
withConfigAndLock go@GlobalOpts{..} inner = loadConfigWithOpts go $ \lc -> do
    withUserFileLock go (view stackRootL lc) $ \lk ->
        runRIO (lcConfig lc) $
            Docker.reexecWithOptionalContainer
                (lcProjectRoot lc)
                Nothing
                (runRIO (lcConfig lc) inner)
                Nothing
                (Just $ munlockFile lk)

-- | Loads global config, ignoring any configuration which would be
-- loaded due to $PWD.
withGlobalConfigAndLock
    :: GlobalOpts
    -> RIO Config ()
    -> IO ()
withGlobalConfigAndLock go@GlobalOpts{..} inner =
    withRunnerGlobal go $ \runner ->
    runRIO runner $ loadConfigMaybeProject
      globalConfigMonoid
      Nothing
      LCSNoProject $ \lc ->
        withUserFileLock go (view stackRootL lc) $ \_lk ->
          runRIO (lcConfig lc) inner

-- For now the non-locking version just unlocks immediately.
-- That is, there's still a serialization point.
withDefaultBuildConfig
    :: GlobalOpts
    -> RIO EnvConfig ()
    -> IO ()
withDefaultBuildConfig go inner =
    withBuildConfigAndLock go AllowNoTargets defaultBuildOptsCLI (\lk -> do munlockFile lk
                                                                            inner)

withBuildConfig
    :: GlobalOpts
    -> NeedTargets
    -> BuildOptsCLI
    -> RIO EnvConfig ()
    -> IO ()
withBuildConfig go needTargets boptsCLI inner =
    withBuildConfigAndLock go needTargets boptsCLI (\lk -> do munlockFile lk
                                                              inner)

withDefaultBuildConfigAndLock
    :: GlobalOpts
    -> (Maybe FileLock -> RIO EnvConfig ())
    -> IO ()
withDefaultBuildConfigAndLock go inner =
    withBuildConfigExt WithDocker go AllowNoTargets defaultBuildOptsCLI Nothing inner Nothing

withBuildConfigAndLock
    :: GlobalOpts
    -> NeedTargets
    -> BuildOptsCLI
    -> (Maybe FileLock -> RIO EnvConfig ())
    -> IO ()
withBuildConfigAndLock go needTargets boptsCLI inner =
    withBuildConfigExt WithDocker go needTargets boptsCLI Nothing inner Nothing

-- | A runner specially built for the "stack clean" use case. For some
-- reason (hysterical raisins?), all of the functions in this module
-- which say BuildConfig actually work on an EnvConfig, while the
-- clean command legitimately only needs a BuildConfig. At some point
-- in the future, we could consider renaming everything for more
-- consistency.
--
-- /NOTE/ This command always runs outside of the Docker environment,
-- since it does not need to run any commands to get information on
-- the project. This is a change as of #4480. For previous behavior,
-- see issue #2010.
withCleanConfig :: GlobalOpts -> RIO BuildConfig () -> IO ()
withCleanConfig go inner =
  loadConfigWithOpts go $ \lc ->
  withUserFileLock go (view stackRootL lc) $ \_lk0 -> do
    bconfig <- lcLoadBuildConfig lc $ globalCompiler go
    runRIO bconfig inner

withBuildConfigExt
    :: WithDocker
    -> GlobalOpts
    -> NeedTargets
    -> BuildOptsCLI
    -> Maybe (RIO Config ())
    -- ^ Action to perform before the build.  This will be run on the host
    -- OS even if Docker is enabled for builds.  The build config is not
    -- available in this action, since that would require build tools to be
    -- installed on the host OS.
    -> (Maybe FileLock -> RIO EnvConfig ())
    -- ^ Action that uses the build config.  If Docker is enabled for builds,
    -- this will be run in a Docker container.
    -> Maybe (RIO Config ())
    -- ^ Action to perform after the build.  This will be run on the host
    -- OS even if Docker is enabled for builds.  The build config is not
    -- available in this action, since that would require build tools to be
    -- installed on the host OS.
    -> IO ()
withBuildConfigExt skipDocker go@GlobalOpts{..} needTargets boptsCLI mbefore inner mafter = loadConfigWithOpts go $ \lc -> do
    withUserFileLock go (view stackRootL lc) $ \lk0 -> do
      -- A local bit of state for communication between callbacks:
      curLk <- newIORef lk0
      let inner' lk =
            -- Locking policy:  This is only used for build commands, which
            -- only need to lock the snapshot, not the global lock.  We
            -- trade in the lock here.
            do dir <- installationRootDeps
               -- Hand-over-hand locking:
               withUserFileLock go dir $ \lk2 -> do
                 liftIO $ writeIORef curLk lk2
                 liftIO $ munlockFile lk
                 logDebug "Starting to execute command inside EnvConfig"
                 inner lk2

      let inner'' lk = do
              bconfig <- lcLoadBuildConfig lc globalCompiler
              envConfig <- runRIO bconfig (setupEnv needTargets boptsCLI Nothing)
              runRIO envConfig (inner' lk)

      let getCompilerVersion = loadCompilerVersion go lc
      runRIO (lcConfig lc) $
        case skipDocker of
          SkipDocker -> do
            forM_ mbefore id
            Nix.reexecWithOptionalShell (lcProjectRoot lc) getCompilerVersion (inner'' lk0)
            forM_ mafter id
          WithDocker -> Docker.reexecWithOptionalContainer
                          (lcProjectRoot lc)
                          mbefore
                          (runRIO (lcConfig lc) $
                              Nix.reexecWithOptionalShell (lcProjectRoot lc) getCompilerVersion (inner'' lk0))
                          mafter
                          (Just $ liftIO $
                                do lk' <- readIORef curLk
                                   munlockFile lk')

-- | Load the configuration. Convenience function used
-- throughout this module.
loadConfigWithOpts
  :: GlobalOpts
  -> (LoadConfig -> IO a)
  -> IO a
loadConfigWithOpts go@GlobalOpts{..} inner = withRunnerGlobal go $ \runner -> do
    mstackYaml <- forM globalStackYaml resolveFile'
    runRIO runner $
      loadConfig globalConfigMonoid globalResolver mstackYaml $ \lc -> do
        -- If we have been relaunched in a Docker container, perform in-container initialization
        -- (switch UID, etc.).  We do this after first loading the configuration since it must
        -- happen ASAP but needs a configuration.
        forM_ globalDockerEntrypoint $ Docker.entrypoint (lcConfig lc)
        liftIO $ inner lc

withRunnerGlobal :: GlobalOpts -> (Runner -> IO a) -> IO a
withRunnerGlobal GlobalOpts{..} inner = do
    defColorWhen <- defaultColorWhen
    let globalColorWhen =
            fromFirst defColorWhen (configMonoidColorWhen globalConfigMonoid)
    withRunner
        globalLogLevel
        globalTimeInLog
        globalTerminal
        globalColorWhen
        globalStylesUpdate
        globalTermWidth
        (isJust globalReExecVersion)
        inner

withMiniConfigAndLock
    :: GlobalOpts
    -> RIO MiniConfig ()
    -> IO ()
withMiniConfigAndLock go@GlobalOpts{..} inner =
  withRunnerGlobal go $ \runner ->
  runRIO runner $
  loadConfigMaybeProject globalConfigMonoid globalResolver LCSNoProject $ \lc -> do
    let miniConfig = loadMiniConfig $ lcConfig lc
    runRIO miniConfig inner

-- | Unlock a lock file, if the value is Just
munlockFile :: MonadIO m => Maybe FileLock -> m ()
munlockFile Nothing = return ()
munlockFile (Just lk) = liftIO $ unlockFile lk

-- Plumbing for --test and --bench flags
withBuildConfigDot
    :: DotOpts
    -> GlobalOpts
    -> RIO EnvConfig ()
    -> IO ()
withBuildConfigDot opts go f = withBuildConfig go' NeedTargets boptsCLI f
  where
    boptsCLI = defaultBuildOptsCLI
        { boptsCLITargets = dotTargets opts
        , boptsCLIFlags = dotFlags opts
        }
    go' =
        (if dotTestTargets opts then set (globalOptsBuildOptsMonoidL.buildOptsMonoidTestsL) (Just True) else id) $
        (if dotBenchTargets opts then set (globalOptsBuildOptsMonoidL.buildOptsMonoidBenchmarksL) (Just True) else id)
        go
