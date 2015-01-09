-- This file is part of the Haskell debugger Hoed.
--
-- Copyright (c) Maarten Faddegon, 2014

module Debug.Hoed.DemoGUI
where

import Prelude hiding(Right)
import Debug.Hoed.Render
import Data.Graph.Libgraph
import qualified Graphics.UI.Threepenny as UI
import Graphics.UI.Threepenny (startGUI,defaultConfig,tpPort,tpStatic
                              , Window, UI, (#), (#+), (#.), string, on
                              )
import System.Process(system)
import Data.IORef
import Data.List(intersperse)


--------------------------------------------------------------------------------

preorder :: CompGraph -> [Vertex]
preorder = getPreorder . getDfs

showStmtN :: [Vertex] -> UI.Element -> Int -> UI ()
showStmtN vs e i = do UI.element e # UI.set UI.text s; return ()
  where s = if i < length vs then showCompStmts (vs !! i)
                             else "Internal error: " ++ show i ++ " is out of range."

demoGUI :: [(String,String)] -> IORef CompGraph -> Window -> UI ()
demoGUI sliceDict treeRef window
  = do return window # UI.set UI.title "Hoed debugging session"
       UI.addStyleSheet window "debug.css"

       -- Get a list of vertices from the computation graph
       tree <- UI.liftIO $ readIORef treeRef
       let ns = filter (not . isRoot) (preorder tree)

        -- Keep track of the current vertex
       currentVertex <- UI.liftIO $ newIORef (0 :: Int)
       let getCurrentVertex = UI.liftIO $ do n <- readIORef currentVertex; return (ns !! n)
           setCurrentVertex n = UI.liftIO $ writeIORef currentVertex n

       -- Draw the computation graph
       img  <- UI.img 
       redraw img treeRef
       img' <- UI.center #+ [UI.element img]

       -- Show computation statement(s) of current vertex
       compStmt <- UI.pre
       let showStmt = showStmtN ns compStmt
       showStmt 0

       -- Menu to select which statement to show
       menu <- UI.select
       populateMenu menu treeRef
       listenToSelectionChange menu showStmt setCurrentVertex

       -- Buttons to judge the current statement
       right <- UI.button # UI.set UI.text "right"
       wrong <- UI.button # UI.set UI.text "wrong"
       onClick right menu img treeRef Right getCurrentVertex
       onClick wrong menu img treeRef Wrong getCurrentVertex

       -- Populate the main screen
       hr <- UI.hr
       UI.getBody window    #+ (map UI.element [menu, right, wrong, compStmt, hr,img'])
       return ()

populateMenu :: UI.Element -> IORef CompGraph -> UI ()
populateMenu menu treeRef = do
       g <- UI.liftIO $ readIORef treeRef
       let ns = filter (not . isRoot) (preorder g)
       let fs = faultyVertices g
       ops  <- mapM (\s->UI.option # UI.set UI.text s) $ map (summarizeVertex fs) ns
       -- UI.element menu # UI.set UI.children [ops] -- (map UI.element ops)
       (UI.element menu) # UI.set UI.children []
       UI.element menu #+ (map UI.element ops)
       return ()

onClick :: UI.Element -> UI.Element -> UI.Element -> IORef CompGraph -> Judgement -> IO Vertex 
           -> UI ()
onClick b menu img treeRef j getCurrentVertex = do
  on UI.click b $ \_ -> do
        n <- UI.liftIO getCurrentVertex
        updateTree img treeRef (\tree -> markNode tree n j)
        populateMenu menu treeRef

listenToSelectionChange :: UI.Element -> (Int -> UI ()) -> (Int -> IO ()) -> UI ()
listenToSelectionChange menu showStmt setN = do
  on UI.selectionChange menu $ \mi -> case mi of
        Just i  -> do UI.liftIO $ setN i
                      showStmt i
        Nothing -> return ()

-- MF TODO: We may need to reconsider how Vertex is defined,
-- and how we determine equality. I think it could happen that
-- two vertices with equal equation but different stacks/relations
-- are now both changed.
markNode :: CompGraph -> Vertex -> Judgement -> CompGraph
markNode g v s = mapGraph f g
  where f Root = Root
        f v'   = if v' === v then v{status=s} else v'

        (===) :: Vertex -> Vertex -> Bool
        v1 === v2 = (equations v1) == (equations v2)

data MaxStringLength = ShorterThan Int | Unlimited

shorten :: MaxStringLength -> String -> String
shorten Unlimited s = s
shorten (ShorterThan l) s
          | length s < l = s
          | l > 3        = take (l - 3) s ++ "..."
          | otherwise    = take l s

-- MF TODO: Maybe we should do something smart with witespace substitution here?
noNewlines :: String -> String
noNewlines = filter (/= '\n')

showCompStmts :: Vertex -> String
showCompStmts = commas . map show . equations

summarizeVertex :: [Vertex] -> Vertex -> String
summarizeVertex fs v = shorten (ShorterThan 27) (noNewlines $ showCompStmts v) ++ s
  where s = if v `elem` fs then " !!" else case status v of
              Unassessed     -> " ??"
              Wrong          -> " :("
              Right          -> " :)"

updateTree :: UI.Element -> IORef CompGraph -> (CompGraph -> CompGraph)
           -> UI ()
updateTree img treeRef f
  = do tree <- UI.liftIO $ readIORef treeRef
       UI.liftIO $ writeIORef treeRef (f tree)
       redraw img treeRef

redraw :: UI.Element -> IORef CompGraph -> UI ()
redraw img treeRef 
  = do tree <- UI.liftIO $ readIORef treeRef
       UI.liftIO $ writeFile "debugTree.dot" (shw tree)
       UI.liftIO $ system $ "dot -Tpng -Gsize=9,9 -Gdpi=100 debugTree.dot "
                          ++ "> wwwroot/debugTree.png"
       url <- UI.loadFile "image/png" "wwwroot/debugTree.png"
       UI.element img # UI.set UI.src url
       return ()

  where shw g = showWith g (summarizeVertex $ faultyVertices g) showArc
        showVertex :: [Vertex] -> Vertex -> String
        showVertex _ Root = "root"
        showVertex fs v = showStatus fs v ++ ":\n" ++ showCompStmts v
                          ++ "\nwith stack " ++ (show . equStack . head . equations $ v)

        showVertexSimple fs v = showStatus fs v ++ ":" ++ showCompStmtsSimple v
        showCompStmtsSimple = commas . (map equLabel) . equations

        showStatus fs v
          | v `elem` fs = "Faulty"
          | otherwise   = (show . status) v

        -- showVertex = show
        -- showVertex = (foldl (++) "") . (map show) . equations
        showArc _  = ""

commas :: [String] -> String
commas [e] = e
commas es  = foldl (\acc e-> acc ++ e ++ ", ") "{" (init es) 
                     ++ show (last es) ++ "}"

faultyVertices :: CompGraph -> [Vertex]
faultyVertices = findFaulty_dag getStatus
  where getStatus Root = Right
        getStatus v    = status v
