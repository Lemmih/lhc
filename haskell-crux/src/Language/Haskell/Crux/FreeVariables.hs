module Language.Haskell.Crux.FreeVariables where

import           Language.Haskell.Crux

import           Data.Set              (Set)
import qualified Data.Set              as Set

-- data Decl = Decl TcType Name Expr
freeVariablesDecl :: Declaration -> Set Name
freeVariablesDecl decl =
  Set.delete (declName decl) (freeVariablesExpr (declBody decl))

freeVariablesExpr :: Expr -> Set Name
freeVariablesExpr expr =
  case expr of
    Var var -> Set.singleton (varName var)
    Con{} -> Set.empty
    UnboxedTuple args -> Set.unions (map freeVariablesExpr args)
    Lit{} -> Set.empty
    WithExternal outV retS _name args _st e ->
      Set.unions (map freeVariablesExpr args) `Set.union`
      Set.delete (varName retS) (Set.delete (varName outV) (freeVariablesExpr e))
    -- WithExternal outV _name args _st e ->
    --   Set.fromList (map varName args) `Set.union`
    --   Set.delete (varName outV) (freeVariablesExpr e)
    ExternalPure outV _name args e ->
      Set.unions (map freeVariablesExpr args) `Set.union`
      Set.delete (varName outV) (freeVariablesExpr e)
    -- ExternalPure outV _name args e ->
    --   Set.fromList (map varName args) `Set.union`
    --   Set.delete (varName outV) (freeVariablesExpr e)
    App a b -> freeVariablesExpr a `Set.union` freeVariablesExpr b
    Lam binds e ->
      freeVariablesExpr e Set.\\
      Set.fromList (map varName binds)
    Let (NonRec var e) scope -> Set.delete (varName var) $
      freeVariablesExpr e `Set.union` freeVariablesExpr scope
    Let (Rec binds) scope ->
      Set.unions (map freeVariablesExpr (scope : map snd binds)) Set.\\
      Set.fromList (map (varName.fst) binds)
    LetStrict var e scope -> Set.delete (varName var) $
      freeVariablesExpr e `Set.union` freeVariablesExpr scope
    Case scrut scrutVar mbDefault alts -> Set.delete (varName scrutVar) $
      freeVariablesExpr scrut `Set.union`
      maybe Set.empty freeVariablesExpr mbDefault `Set.union`
      Set.unions (map freeVariablesAlt alts)
    Convert e _ty -> freeVariablesExpr e
    Cast -> Set.empty

freeVariablesAlt :: Alt -> Set Name
freeVariablesAlt (Alt pattern e) =
  case pattern of
    LitPat{} -> freeVariablesExpr e
    UnboxedPat vars ->
      freeVariablesExpr e Set.\\ Set.fromList (map varName vars)
    ConPat _con vars ->
      freeVariablesExpr e Set.\\ Set.fromList (map varName vars)
