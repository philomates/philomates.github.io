-- State type constructor with the runState record syntax for state extraction
newtype State s a = State {
      runState :: s -> (a, s)
    }

instance Monad (State s) where
  {-return :: a -> State s a-}
  return a = State $ \s -> (a, s)

  {-(>>=) :: State s a -> (a -> State s b) -> State s b-}
  m >>= k = State $ \s -> let (a, s') = runState m s
                           in runState (k a) s'

-- State access & modification helper methods
get :: State s s
get = State $ \s -> (s, s)

put :: s -> State s ()
put s = State $ \_ -> ((), s)

-- Sexpr Example
-- for simplicity we'll use a string instead of an ADT
type Sexpr = String

-- Add unique symbol to Sexpr using naive threading of program state
transformStmt :: Sexpr -> Int -> (Sexpr, Int)
transformStmt expr counter = (newExpr, newCounter)
  where newExpr = "(define " ++ uniqVarName ++ " " ++ expr ++ ")"
        newCounter = counter + 1
        uniqVarName = "tmpVar" ++ (show counter)

-- Sexpr using State Monad
-- create a type for the state we want to pass around
type SexprState = State Int

-- wrap an Sexpr in the State monad
sexprWithState :: SexprState Sexpr
sexprWithState = return "(foo bar)"

-- wrap Sexpr in parenthesis
wrapSexpr :: Sexpr -> SexprState Sexpr
wrapSexpr exp = return $ "(" ++ exp ++ ")"

-- wrap Sexpr in qux
addQux :: Sexpr -> SexprState Sexpr
addQux exp = return $ "(qux " ++ exp ++ ")"

runStateExample :: IO ()
runStateExample = do
  putStrLn "runState example:"
  putStrLn $ show $
    runState (sexprWithState
         >>= (\exp -> wrapSexpr exp
         >>= (\exp2 -> addQux exp2))) 0

modifyState :: IO ()
modifyState = do
  putStrLn "Modify state example:"
  putStrLn
    $ show
    $ runState (sexprWithState
           >>= wrapSexpr
           >>= (\exp' -> get
           >>= (\counter -> (put (counter+1))
           >>  (return exp')
           >>= addQux))) 0

-- redo transformStmt using State monad
transformStmt' :: Sexpr -> SexprState Sexpr
transformStmt' expr =
  -- grab the current program state
  get
  -- increment the counter by 1 and store it
  >>= (\counter -> (put (counter+1))
  -- do the sexpr transformation
  >> (return $ "(define tmpVar" ++ (show counter) ++ " " ++ expr ++ ")"))

transformExample :: IO ()
transformExample = do
  putStrLn "transformStmt' example:"
  putStrLn $ show $
    runState (sexprWithState
         >>= (\exp -> transformStmt' exp
         >>= (\exp2 -> transformStmt' exp2))) 0

-- transformExample using do blocks
transformExampleDoNotation :: IO ()
transformExampleDoNotation = do
  let result = runState (doTransform "(foo bar)") 0
  putStrLn $ show result
  where
    -- package up the sexpr transformations into a do-style function
    doTransform :: Sexpr -> SexprState Sexpr
    doTransform expr = do
      stmt1 <- transformStmt' expr
      transformStmt' stmt1

main = do
  runStateExample
  putStrLn ""
  modifyState
  putStrLn ""
  transformExample
