import StackTest
import System.Directory (createDirectoryIfMissing,withCurrentDirectory, getCurrentDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import Data.List (filter)
import System.IO (hPutStrLn, withFile, IOMode(..))

main :: IO ()
main = do
    let
      gitInit = do
         runShell "git init ."
         runShell "git config user.name Test"
         runShell "git config user.email test@test.com"

    createDirectoryIfMissing True "tmpSubSubRepo"
    withCurrentDirectory "tmpSubSubRepo" $ do
      gitInit
      stack ["new", "pkg ", defaultResolverArg]
      runShell "git add pkg"
      runShell "git commit -m SubSubCommit"

    createDirectoryIfMissing True "tmpSubRepo"
    withCurrentDirectory "tmpSubRepo" $ do
      gitInit
      runShell "git submodule add ../tmpSubSubRepo sub"
      runShell "git commit -a -m SubCommit"

    createDirectoryIfMissing True "tmpRepo"
    withCurrentDirectory "tmpRepo" $ do
      gitInit
      runShell "git submodule add ../tmpSubRepo sub"
      runShell "git commit -a -m Commit"

    stack ["new", defaultResolverArg, "tmpPackage"]

    curDir <- getCurrentDirectory
    let tmpRepoDir = curDir </> "tmpRepo"
    gitHead <- runWithCwd tmpRepoDir "git" ["rev-parse", "HEAD"]
    let gitHeadCommit = stripNewline gitHead

    withCurrentDirectory "tmpPackage" $ do
      -- add git dependency on repo with recursive submodules
      writeToStackFile (tmpRepoDir, gitHeadCommit)
      -- Setup the package
      stack ["setup"]

    -- cleanup
    removeDirIgnore "tmpRepo"
    removeDirIgnore "tmpSubRepo"
    removeDirIgnore "tmpSubSubRepo"
    removeDirIgnore "tmpPackage"

writeToStackFile :: (String, String) -> IO ()
writeToStackFile (tmpRepoDir, gitCommit) = do
  curDir <- getCurrentDirectory
  let stackFile = curDir </> "stack.yaml"
  let line1 = "extra-deps:"
      line2 = "- git: " ++ tmpRepoDir
      line3 = "  commit: " ++ gitCommit
      line4 = "  subdir: sub/sub/pkg"
  withFile stackFile AppendMode (\handle -> do
                                   hPutStrLn handle line1
                                   hPutStrLn handle line2
                                   hPutStrLn handle line3
                                   hPutStrLn handle line4
                                )

newline :: Char
newline = '\n'

stripNewline :: String -> String
stripNewline str = filter (\x -> x /= newline) str
