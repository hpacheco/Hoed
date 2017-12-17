{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-|
Module      : Debug.Hoed
Description : Lighweight algorithmic debugging based on observing intermediate values.
Copyright   : (c) 2000 Andy Gill, (c) 2010 University of Kansas, (c) 2013-2017 Maarten Faddegon
License     : BSD3
Maintainer  : hoed@maartenfaddegon.nl
Stability   : experimental
Portability : POSIX

Hoed is a tracer and debugger for the programming language Haskell.

Hoed is recommended over Hoed.Stk: in contrast to Hoed.Stk you can optimize your program and do not need to enable profiling when using Hoed.

To locate a defect with Hoed you annotate suspected functions and compile as usual. Then you run your program, information about the annotated functions is collected. Finally you connect to a debugging session using a webbrowser.

Let us consider the following program, a defective implementation of a parity function with a test property.

> import Test.QuickCheck
>
> isOdd :: Int -> Bool
> isOdd n = isEven (plusOne n)
>
> isEven :: Int -> Bool
> isEven n = mod2 n == 0
>
> plusOne :: Int -> Int
> plusOne n = n + 1
>
> mod2 :: Int -> Int
> mod2 n = div n 2
>
> prop_isOdd :: Int -> Bool
> prop_isOdd x = isOdd (2*x+1)
>
> main :: IO ()
> main = printO (prop_isOdd 1)
>
> main :: IO ()
> main = quickcheck prop_isOdd

Using the property-based test tool QuickCheck we find the counter example `1` for our property.

> ./MyProgram
> *** Failed! Falsifiable (after 1 test): 1

Hoed can help us determine which function is defective. We annotate the functions `isOdd`, `isEven`, `plusOne` and `mod2` as follows:

> import Debug.Hoed
>
> isOdd :: Int -> Bool
> isOdd = observe "isOdd" isOdd'
> isOdd' n = isEven (plusOne n)
>
> isEven :: Int -> Bool
> isEven = observe "isEven" isEven'
> isEven' n = mod2 n == 0
>
> plusOne :: Int -> Int
> plusOne = observe "plusOne" plusOne'
> plusOne' n = n + 1
>
> mod2 :: Int -> Int
> mod2 = observe "mod2" mod2'
> mod2' n = div n 2
>
> prop_isOdd :: Int -> Bool
> prop_isOdd x = isOdd (2*x+1)
>
> main :: IO ()
> main = printO (prop_isOdd 1)

After running the program a computation tree is constructed and displayed in a web browser.

> ./MyProgram
> False
> Listening on http://127.0.0.1:10000/

After running the program a computation tree is constructed and displayed in a
web browser. You can freely browse this tree to get a better understanding of
your program. If your program misbehaves, you can judge the computation
statements in the tree as 'right' or 'wrong' according to your intention. When
enough statements are judged the debugger tells you the location of the fault
in your code.

<<https://raw.githubusercontent.com/MaartenFaddegon/Hoed/master/screenshots/AlgorithmicDebugging.png>>

Read more about Hoed on its project homepage <https://wiki.haskell.org/Hoed>.

Papers on the theory behind Hoed can be obtained via <http://maartenfaddegon.nl/#pub>.

I am keen to hear about your experience with Hoed: where did you find it useful and where would you like to see improvement? You can send me an e-mail at hoed@maartenfaddegon.nl, or use the github issue tracker <https://github.com/MaartenFaddegon/hoed/issues>.
-}

{-# LANGUAGE CPP #-}

module Debug.Hoed
  ( -- * Basic annotations
    observe
  , runO
  , printO
  , testO

  -- * Property-assisted algorithmic debugging
  , runOwp
  , printOwp
  , testOwp
  , Propositions(..)
  , PropType(..)
  , Proposition(..)
  , mkProposition
  , ofType
  , withSignature
  , sizeHint
  , withTestGen
  , TestGen(..)
  , PropositionType(..)
  , Module(..)
  , Signature(..)
  , ParEq(..)
  , (===)
  , runOstore
  , conAp

  -- * Build your own debugger with Hoed
  , runO'
  , judge
  , unjudgedCharacterCount
  , CompTree
  , Vertex(..)
  , CompStmt(..)
  , Judge(..)
  , Verbosity(..)

  -- * API to test Hoed itself
  , logO
  , logOwp
  , traceOnly
  , UnevalHandler(..)

   -- * The Observable class
  , Observer(..)
  , Observable(..)
  , (<<)
  , thunk
  , nothunk
  , send
  , observeOpaque
  , observeBase
  , constrainBase
  , debugO
  , CDS
  , Generic
  ) where


import           Debug.Hoed.CompTree
import           Debug.Hoed.Console
import           Debug.Hoed.EventForest
import           Debug.Hoed.Observe
import           Debug.Hoed.Prop
import           Debug.Hoed.Render
import           Debug.Hoed.Serialize

import           Data.IORef
import           Prelude                hiding (Right)
import           System.Directory       (createDirectoryIfMissing)
import           System.IO
import           System.IO.Unsafe

import           GHC.Generics

import           Data.Graph.Libgraph



-- %************************************************************************
-- %*                                                                   *
-- \subsection{External start functions}
-- %*                                                                   *
-- %************************************************************************

-- Run the observe ridden code.


runOnce :: IO ()
runOnce = do
  f <- readIORef firstRun
  if f
    then writeIORef firstRun False
    else error "It is best not to run Hoed more that once (maybe you want to restart GHCI?)"

firstRun :: IORef Bool
{-# NOINLINE firstRun #-}
firstRun = unsafePerformIO $ newIORef True


-- | run some code and return the Trace
debugO :: IO a -> IO Trace
debugO program =
     do { runOnce
        ; initUniq
        ; startEventStream
        ; let errorMsg e = "[Escaping Exception in Code : " ++ show e ++ "]"
        ; ourCatchAllIO (do { _ <- program ; return () })
                        (hPutStrLn stderr . errorMsg)
        ; endEventStream
        }

-- | The main entry point; run some IO code, and debug inside it.
--   After the IO action is completed, an algorithmic debugging session is started at
--   @http://localhost:10000/@ to which you can connect with your webbrowser.
--
-- For example:
--
-- @
--   main = runO $ do print (triple 3)
--                    print (triple 2)
-- @

runO :: IO a -> IO ()
runO program = do
  (trace,_traceInfo,compTree,_frt) <- runO' Verbose program
  debugSession trace compTree []
  return ()


-- | Hoed internal function that stores a serialized version of the tree on disk (assisted debugging spawns new instances of Hoed).
runOstore :: String -> IO a -> IO ()
runOstore tag program = do
  (trace,_traceInfo,compTree,_frt) <- runO' Silent program
  storeTree (treeFilePath ++ tag) compTree
  storeTrace (traceFilePath ++ tag) trace

-- | Repeat and trace a failing testcase
testO :: Show a => (a->Bool) -> a -> IO ()
testO p x = runO $ putStrLn $ if p x then "Passed 1 test."
                                     else " *** Failed! Falsifiable: " ++ show x

-- | Use property based judging.

runOwp :: [Propositions] -> IO a -> IO ()
runOwp ps program = do
  (trace,_traceInfo,compTree,_frt) <- runO' Verbose program
  let compTree' = compTree
  debugSession trace compTree' ps
  return ()

-- | Repeat and trace a failing testcase
testOwp :: Show a => [Propositions] -> (a->Bool) -> a -> IO ()
testOwp ps p x = runOwp ps $ putStrLn $
  if p x then "Passed 1 test."
  else " *** Failed! Falsifiable: " ++ show x

-- | Short for @runO . print@.
printO :: (Show a) => a -> IO ()
printO expr = runO (print expr)


printOwp :: (Show a) => [Propositions] -> a -> IO ()
printOwp ps expr = runOwp ps (print expr)

-- | Only produces a trace. Useful for performance measurements.
traceOnly :: IO a -> IO ()
traceOnly program = do
  _ <- debugO program
  return ()


data Verbosity = Verbose | Silent

condPutStrLn :: Verbosity -> String -> IO ()
condPutStrLn Silent _    = return ()
condPutStrLn Verbose msg = hPutStrLn stderr msg

-- |Entry point giving you access to the internals of Hoed. Also see: runO.
runO' :: Verbosity -> IO a -> IO (Trace,TraceInfo,CompTree,EventForest)
runO' verbose program = do
  createDirectoryIfMissing True ".Hoed/"
  condPutStrLn verbose "=== program output ===\n"
  events <- debugO program
  condPutStrLn verbose"\n=== program terminated ==="
  condPutStrLn verbose"Please wait while the computation tree is constructed..."

  let cdss = eventsToCDS events
  let cdss1 = rmEntrySet cdss
  let cdss2 = simplifyCDSSet cdss1
  let eqs   = renderCompStmts cdss2

  let frt  = mkEventForest events
      ti   = traceInfo (reverse events)
      ds   = dependencies ti
      ct   = mkCompTree eqs ds

  writeFile ".Hoed/Events"     (unlines . map show . reverse $ events)
#if defined(DEBUG)
  writeFile ".Hoed/Cdss"       (unlines . map show $ cdss2)
  writeFile ".Hoed/Eqs"        (unlines . map show $ eqs)
  writeFile ".Hoed/compTree"   (unlines . map show $ eqs)
#endif
#if defined(TRANSCRIPT)
  writeFile ".Hoed/Transcript" (getTranscript events ti)
#endif

  condPutStrLn verbose "\n=== Statistics ===\n"
  let e  = length events
      n  = length eqs
      b  = fromIntegral (length . arcs $ ct ) / fromIntegral ((length . vertices $ ct) - (length . leafs $ ct))
  condPutStrLn verbose $ show e ++ " events"
  condPutStrLn verbose $ show n ++ " computation statements"
  condPutStrLn verbose $ show ((length . vertices $ ct) - 1) ++ " nodes + 1 virtual root node in the computation tree"
  condPutStrLn verbose $ show (length . arcs $ ct) ++ " edges in computation tree"
  condPutStrLn verbose $ "computation tree has a branch factor of " ++ show b ++ " (i.e the average number of children of non-leaf nodes)"

  condPutStrLn verbose "\n=== Debug Session ===\n"
  return (events, ti, ct, frt)

-- | Trace and write computation tree to file. Useful for regression testing.
logO :: FilePath -> IO a -> IO ()
logO filePath program = {- SCC "logO" -} do
  (_,_,compTree,_) <- runO' Verbose program
  writeFile filePath (showGraph compTree)
  return ()

  where showGraph g        = showWith g showVertex showArc
        showVertex RootVertex = ("\".\"","shape=none")
        showVertex v       = ("\"" ++ (escape . showCompStmt) v ++ "\"", "")
        showArc _          = ""
        showCompStmt       = show . vertexStmt

-- | As logO, but with property-based judging.
logOwp :: UnevalHandler -> FilePath -> [Propositions] -> IO a -> IO ()
logOwp handler filePath properties program = do
  (trace,_traceInfo,compTree,_frt) <- runO' Verbose program
  hPutStrLn stderr "\n=== Evaluating assigned properties ===\n"
  compTree' <- judgeAll handler unjudgedCharacterCount trace properties compTree
  writeFile filePath (showGraph compTree')
  return ()

  where showGraph g        = showWith g showVertex showArc
        showVertex RootVertex = ("root","")
        showVertex v       = ("\"" ++ (escape . showCompStmt) v ++ "\"", "")
        showArc _          = ""
        showCompStmt s     = (show . vertexJmt) s ++ ": " ++ (show . vertexStmt) s

