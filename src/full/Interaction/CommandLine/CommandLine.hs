{-# OPTIONS -cpp -fglasgow-exts #-}

module Interaction.CommandLine.CommandLine where

import Prelude hiding (print, putStr, putStrLn)
import Utils.IO

import Control.Monad.Error
import Control.Monad.Reader
import Data.Char
import Data.Set as Set
import Data.Map as Map
import Data.List as List
import Data.Maybe

import Interaction.BasicOps
import Interaction.Monad

import qualified Syntax.Abstract as A
import Syntax.Internal
import Syntax.Parser
import Syntax.Position
import Syntax.Scope
import Syntax.Translation.ConcreteToAbstract

import Text.PrettyPrint

import TypeChecker
import TypeChecking.Conversion
import TypeChecking.Monad
import TypeChecking.Monad.Context
import TypeChecking.MetaVars
import TypeChecking.Reduce

import Utils.ReadLine
import Utils.Monad
import Utils.Fresh
import Utils.Monad.Undo

#include "../../undefined.h"

data ExitCode a = Continue | ContinueIn TCEnv | Return a

type Command a = (String, [String] -> IM (ExitCode a))

matchCommand :: String -> [Command a] -> Either [String] ([String] -> IM (ExitCode a))
matchCommand x cmds =
    case List.filter (isPrefixOf x . fst) cmds of
	[(_,m)]	-> Right m
	xs	-> Left $ List.map fst xs

interaction :: String -> [Command a] -> (String -> IM (ExitCode a)) -> IM a
interaction prompt cmds eval = loop
    where
	go (Return x)	    = return x
	go Continue	    = loop
	go (ContinueIn env) = local (const env) loop

	loop =
	    do	ms <- liftIO $ readline prompt
		case fmap words ms of
		    Nothing		  -> return $ error "** EOF **"
		    Just []		  -> loop
		    Just ((':':cmd):args) ->
			do  liftIO $ addHistory (fromJust ms)
			    case matchCommand cmd cmds of
				Right c	-> go =<< c args
				Left []	->
				    do	liftIO $ putStrLn $ "Unknown command '" ++ cmd ++ "'"
					loop
				Left xs	->
				    do	liftIO $ putStrLn $ "More than one command match: " ++ concat (intersperse ", " xs)
					loop
		    Just _ ->
			do  liftIO $ addHistory (fromJust ms)
			    go =<< eval (fromJust ms)
	    `catchError` \e ->
		do  liftIO $ print e
		    loop

-- | The interaction loop.
interactionLoop :: IM () -> IM ()
interactionLoop typeCheck =
    do	reload
	interaction "Main> " commands evalTerm
    where
	reload = (setUndo >> typeCheck) `catchError`
		    \e -> liftIO $ do print e
				      putStrLn "Failed."

	commands =
	    [ "quit"	|>  \_ -> return $ Return ()
	    , "help"	|>  \_ -> continueAfter $ liftIO $ putStr help
	    , "?"	|>  \_ -> continueAfter $ liftIO $ putStr help
	    , "reload"	|>  \_ -> do reload
				     ContinueIn <$> ask
	    , "constraints" |> \_ -> continueAfter showConstraints
            , "give" |> \args -> continueAfter $ giveMeta args
	    , "meta" |> \args -> continueAfter $ showMetas args
            , "undo" |> \_ -> continueAfter $ mkUndo
	    ]
	    where
		(|>) = (,)

continueAfter :: IM a -> IM (ExitCode b)
continueAfter m = m >> return Continue

showConstraints :: IM ()
showConstraints =
    do	cs <- Interaction.BasicOps.getConstraints
	liftIO $ putStrLn $ unlines cs

	

showMetas :: [String] -> IM ()
showMetas [m] =
    do	i  <- readM m
	s <- getMeta (InteractionId i)
	liftIO $ putStrLn $ s
showMetas [] = 
    do ms <- getMetas
       liftIO $ putStrLn $ unlines ms

showMetas _ = liftIO $ putStrLn $ ":meta [metaid]"



metaParseExpr ::  InteractionId -> String -> IM A.Expr
metaParseExpr ii s = 
    do	m <- lookupInteractionId ii
        i <- fresh
        scope <- getMetaScope <$> lookupMeta m
        --liftIO $ putStrLn $ show scope
	let ss = ScopeState { freshId = i }
	liftIO $ concreteToAbstract ss scope c
    where
	c = parse exprParser s

giveMeta :: [String] -> IM ()
giveMeta (is:es) = 
     do  i <- readM is
         let ii = InteractionId i 
         e <- metaParseExpr ii (concat es)
         give ii e
         return ()       

giveMeta _ = liftIO $ putStrLn "give takes a number of a meta and expression"


parseExpr :: String -> TCM A.Expr
parseExpr s =
    do	i <- fresh
	scope <- getScope
	let ss = ScopeState { freshId = i }
	liftIO $ concreteToAbstract ss scope c
    where
	c = parse exprParser s

evalTerm s =
    do	e <- parseExpr s
	t <- newTypeMeta_ 
	v <- checkExpr e t
	t' <- normalise t
	v' <- normalise v
	liftIO $ putStrLn $ show v' ++ " : " ++ show t'
	return Continue

-- | The logo that prints when agdaLight is started in interactive mode.
splashScreen :: String
splashScreen = unlines
    [ "                 _        ______"
    , "   ____         | |      |_ __ _|"
    , "  / __ \\        | |       | || |"
    , " | |__| |___  __| | ___   | || |"
    , " |  __  / _ \\/ _  |/ __\\  | || |   Agda 2 Interactive"
    , " | |  |/ /_\\ \\/_| / /_| \\ | || |"
    , " |_|  |\\___  /____\\_____/|______|  Type :? for help."
    , "        __/ /"
    , "        \\__/"
    ]

-- | The help message
help :: String
help = unlines
    [ "Command overview"
    , ":quit         Quit."
    , ":help or :?   Help (this message)."
    , ":reload       Reload input files."
    , "<exp> Infer type of expression <exp> and evaluate it."
    ]

