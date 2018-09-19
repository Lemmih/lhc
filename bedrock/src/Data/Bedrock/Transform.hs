{-# LANGUAGE LambdaCase #-}
module Data.Bedrock.Transform where

import           Control.Monad.State
import           Data.Map            (Map)
import qualified Data.Map            as Map
import           Data.Set            (Set)
import qualified Data.Set            as Set

import           Data.Bedrock


data Env = Env
    { envModule    :: Module
    , envUnique    :: Int
    , envHelpers   :: [Function]
    , envFunctions :: Map Name Function }
type Gen a = State Env a

transformMaybe :: (a -> Gen a) -> Maybe a -> Gen (Maybe a)
transformMaybe _ Nothing  = return Nothing
transformMaybe f (Just a) = Just `fmap` f a

modifyModule :: (Module -> Module) -> Gen ()
modifyModule fn = modify $ \st -> st{envModule = fn (envModule st)}

pushHelper :: Function -> Gen ()
pushHelper fn = modify $ \st -> st{envHelpers = fn : envHelpers st}

pushFunction :: Function -> Gen ()
pushFunction fn = do
  helpers <- gets envHelpers
  modify $ \st -> st{envHelpers = []}
  modifyModule $ \m -> m{functions = functions m ++ fn:helpers}

pushNode :: NodeDefinition -> Gen ()
pushNode n = modifyModule $ \m -> m{ nodes = n : nodes m }

lookupAttributes :: Name -> Gen [Attribute]
lookupAttributes name = do
  m <- gets envFunctions
  case Map.lookup name m of
    -- XXX: Throw an exception?
    Nothing -> return []
    Just fn -> return $ fnAttributes fn

hasAttribute :: Name -> Attribute -> Gen Bool
hasAttribute name attr = do
  attrs <- lookupAttributes name
  return $ attr `elem` attrs

newUnique :: Gen Int
newUnique = do
  u <- gets envUnique
  modify $ \st -> st{envUnique = u+1}
  return u

newName :: String -> Gen Name
newName name = do
  u <- newUnique
  return Name
      { nameModule = []
      , nameIdentifier = name
      , nameUnique = u }

newVariable :: String -> Type -> Gen Variable
newVariable ident ty = do
  name <- newName ident
  return Variable
      { variableName = name
      , variableType = ty }

tagName :: String -> Name -> Gen Name
tagName tag name = do
  u <- newUnique
  return $ name{ nameIdentifier = nameIdentifier name ++ "." ++ tag
               , nameUnique = u}

tagVariable :: String -> Variable -> Gen Variable
tagVariable tag var = do
  nameTag <- tagName tag (variableName var)
  return var{ variableName = nameTag }



-- FIXME: This is O(n)
--lookupFunction :: Name -> Gen Function
--lookupFunction name = do
--    funcs <- gets envFunctions
--    case Map.lookup name funcs of
--        Just fn -> return fn
--        Nothing -> error $ "Missing function: " ++ show name

runGen :: Gen a -> Module -> Module
runGen gen initModule =
    envModule (execState gen m)
  where
    m = Env
        { envModule = initModule{functions = []}
        , envUnique = 0
        , envHelpers = []
        , envFunctions = Map.fromList
            [ (fnName fn, fn) | fn <- functions initModule]
        }

--usedNodes :: Expression -> Set NodeName
--usedNodes = flip usedNodes' Set.empty
--  where
--    usedNodes' expr =
--        case expr of
--            Case _scrut _defaultBranch alternatives ->
--                foldr (.) id
--                [ usedNodes' branch
--                | Alternative _pattern branch <- alternatives ]
--            Bind _ simple rest ->
--                usedNodes' rest



freeVariables :: Block -> Set Variable
freeVariables block = freeVariables' block Set.empty

freeVariables' :: Block -> Set Variable -> Set Variable
freeVariables' block =
  case block of
    Case scrut defaultBranch alternatives ->
      foldr (.) (Set.insert scrut)
      [ flip Set.difference (freeVariablesPattern pattern Set.empty) .
        freeVariables' branch
      | Alternative pattern branch <- alternatives ] .
      case defaultBranch of
        Nothing -> id
        Just branch -> freeVariables' branch
    Bind binds simple rest ->
      freeVariablesSimple simple .
      flip Set.difference (Set.fromList binds) .
      freeVariables' rest
    Recursive _binds rest -> freeVariables' rest
    Return args ->
      Set.union (Set.fromList args)
    Raise name ->
      Set.insert name
    Invoke cont args ->
      Set.union (Set.fromList (cont:args))
    TailCall _name args ->
      Set.union (Set.fromList args)
    Exit ->
      id
    Panic{} ->
      id

freeVariablesPattern :: Pattern -> Set Variable -> Set Variable
freeVariablesPattern pattern =
  case pattern of
    NodePat _ vars -> Set.union (Set.fromList vars)
    LitPat{}       -> id
    -- VarPat var     -> Set.insert var

freeVariablesParameter :: Parameter -> Set Variable -> Set Variable
freeVariablesParameter =
  \case
    PInt{}          -> id
    PString{}       -> id
    PName{}         -> id
    PNodeName{}     -> id
    PVariable var   -> Set.insert var
    PVariables vars -> Set.union (Set.fromList vars)

freeVariablesSimple :: Expression -> Set Variable -> Set Variable
freeVariablesSimple simple =
  case simple of
    Application _fn args ->
      Set.union (Set.fromList args)
    CCall _fn args ->
      Set.union (Set.fromList args)
    Catch _exh exhArgs _fn fnArgs ->
      Set.union (Set.fromList (exhArgs ++ fnArgs))
    InvokeReturn fn args ->
      Set.union (Set.fromList (fn:args))
    Builtin _ params ->
      \s -> foldr freeVariablesParameter s params
    Literal{} -> id
