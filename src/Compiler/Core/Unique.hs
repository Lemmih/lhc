module Compiler.Core.Unique
  ( unique ) where

import           Data.Map (Map)
import qualified Data.Map as Map
import           Control.Monad.Reader
import           Control.Monad.State

import           Compiler.Core
import           Data.Bedrock                (Name(..))


unique :: Module -> Module
unique m = evalState (runReaderT action env) 1
  where
    env = Map.empty
    action = do
      decls <- mapM uniqueDecl (coreDecls m)
      return m{coreDecls = decls}

type Env = Map Name Name
type M a = ReaderT Env (State Int) a

uniqueDecl :: Decl -> M Decl
uniqueDecl decl = do
  body <- uniqueExpr (declBody decl)
  return decl{declBody = body}

uniqueExpr :: Expr -> M Expr
uniqueExpr expr =
  case expr of
    Var var -> Var <$> uniqueVariable var
    Con name -> pure $ Con name
    UnboxedTuple args ->
      UnboxedTuple <$> mapM uniqueExpr args
    Lit lit -> pure $ Lit lit
    WithExternal out fn args st e ->
      bind out $ \out' ->
      WithExternal out' fn
        <$> mapM uniqueVariable args
        <*> uniqueVariable st
        <*> uniqueExpr e
    ExternalPure out fn args e ->
      bind out $ \out' ->
        ExternalPure out' fn
          <$> mapM uniqueVariable args
          <*> uniqueExpr e
    App a b -> App <$> uniqueExpr a <*> uniqueExpr b
    Lam vars e -> bindMany vars $ \vars' ->
      Lam vars' <$> uniqueExpr e

    Let (NonRec v e) body -> bind v $ \v' ->
      Let <$> (NonRec v' <$> uniqueExpr e)
          <*> uniqueExpr body
    Let{} ->
      error "Compiler.Core.Unique.uniqueExpr.Let: undefined"
    LetStrict{} ->
      error "Compiler.Core.Unique.uniqueExpr.LetStrict: undefined"
    Case e scrut mbDef alts -> do
      e' <- uniqueExpr e
      bind scrut $ \scrut' ->
        Case e' scrut'
            <$> uniqueMaybe uniqueExpr mbDef
            <*> mapM uniqueAlt alts
    Cast e ty ->
      Cast <$> uniqueExpr e <*> pure ty
    Id -> pure Id
    WithProof p e -> WithProof p <$> uniqueExpr e

uniqueAlt :: Alt -> M Alt
uniqueAlt (Alt pattern e) =
  case pattern of
    ConPat con vars -> bindMany vars $ \vars' ->
      Alt (ConPat con vars') <$> uniqueExpr e
    LitPat lit ->
      Alt (LitPat lit) <$> uniqueExpr e
    UnboxedPat vars -> bindMany vars $ \vars' ->
      Alt (UnboxedPat vars') <$> uniqueExpr e

uniqueVariable :: Variable -> M Variable
uniqueVariable var@(Variable name ty) = do
  env <- ask
  case Map.lookup name env of
    Nothing -> pure var
    Just name' -> pure $ Variable name' ty

bind :: Variable -> (Variable -> M a) -> M a
bind var action = do
  name' <- newName (varName var)
  let var' = var{varName = name'}
  local (Map.insert (varName var) name') (action var')

bindMany :: [Variable] -> ([Variable] -> M a) -> M a
bindMany vars action = do
  names <- mapM (newName.varName) vars
  let vars' = zipWith (\var name -> var{varName=name}) vars names
  local (Map.union (Map.fromList $ zip (map varName vars) names)) (action vars')

-- newVariable :: Variable -> M Variable
-- newVariable v = do
--   u <- get
--   put (u+1)
--   return v{varName = (varName v){nameUnique = u}}

newName :: Name -> M Name
newName n = do
  u <- get
  put (u+1)
  return n{nameUnique = u}

uniqueMaybe :: (a -> M a) -> Maybe a -> M (Maybe a)
uniqueMaybe _ Nothing   = pure Nothing
uniqueMaybe fn (Just v) = Just <$> fn v
