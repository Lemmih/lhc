{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
module Compiler.HaskellToCore
    ( convert
    ) where

import           Control.Monad.Reader
import           Control.Monad.RWS          (RWS, execRWS)
import           Control.Monad.State
import           Control.Monad.Writer       (MonadWriter (..))
import           Data.List                  (transpose)
import           Data.Map                   (Map)
import qualified Data.Map                   as Map
import           Data.Maybe
import qualified Language.Haskell.Exts      as HS

import           Compiler.Core
import           Data.Bedrock               (AvailableNamespace (..),
                                             CType (..), Foreign (..),
                                             Name (..))
import           Data.Bedrock.Misc
import           Language.Haskell.Scope     (Entity (..), NameInfo (..),
                                             QualifiedName (..))
import qualified Language.Haskell.Scope     as Scope
import           Language.Haskell.TypeCheck (Qualified (..), TcEnv (..),
                                             TcVar (..), Typed)
import qualified Language.Haskell.TypeCheck as TC

data Scope = Scope
    { scopeVariables    :: Map Entity Name
    , scopeNodes        :: Map QualifiedName Name
    , scopeConstructors :: Map Entity Name -- XXX: Merge with scopeNodes?
    , scopeTcEnv        :: TcEnv
    , scopeArity        :: Map Entity Int
    }
instance Monoid Scope where
    mempty = Scope
        { scopeVariables    = Map.empty
        , scopeNodes        = Map.empty
        , scopeConstructors = Map.empty
        , scopeTcEnv        = TcEnv
            { -- Globals such as Nothing, Just, etc
              tcEnvValues    = Map.empty
            }
        , scopeArity         = Map.empty
        }
    mappend a b = Scope
        { scopeVariables    = w scopeVariables
        , scopeNodes        = w scopeNodes
        , scopeConstructors = w scopeConstructors
        , scopeTcEnv        = scopeTcEnv a
        , scopeArity        = w scopeArity }
        where w f = mappend (f a) (f b)

data Env = Env
    { envScope        :: Scope
    , envForeigns     :: [Foreign]
    , envNodes        :: [NodeDefinition]
    , envNewTypes     :: [NewType]
    , envDecls        :: [Decl]
    , envConstructors :: Map Name Name
    }

instance Monoid Env where
    mempty = Env
        { envScope    = mempty
        , envForeigns = mempty
        , envNodes    = mempty
        , envNewTypes = mempty
        , envDecls    = mempty
        , envConstructors = mempty
        }
    mappend a b = Env
        { envScope    = w envScope
        , envForeigns = w envForeigns
        , envNodes    = w envNodes
        , envNewTypes = w envNewTypes
        , envDecls    = w envDecls
        , envConstructors = w envConstructors
        }
        where w f = mappend (f a) (f b)

newtype M a = M { unM :: RWS Scope Env AvailableNamespace a }
    deriving
        ( Monad, Functor, Applicative
        , MonadReader Scope, MonadState AvailableNamespace
        , MonadWriter Env )

runM :: TcEnv -> M a -> (AvailableNamespace, Env)
runM tcEnv m = (ns', env)
  where
    (ns', env) = execRWS (unM m) ((envScope env){ scopeTcEnv = tcEnv }) ns
    ns = AvailableNamespace 0 0 0 0

pushForeign :: Foreign -> M ()
pushForeign f = tell mempty{ envForeigns = [f] }

pushDecl :: Decl -> M ()
pushDecl decl = tell mempty{ envDecls = [decl] }

pushNode :: NodeDefinition -> M ()
pushNode def = tell mempty{ envNodes = [def] }

pushNewType :: NewType -> M ()
pushNewType def = tell mempty{ envNewTypes = [def] }

newUnique :: M Int
newUnique = do
    ns <- get
    let (idNum, ns') = newGlobalID ns
    put ns'
    return idNum

newName :: String -> M Name
newName ident = do
    u <- newUnique
    return $ Name [] ident u

nameInfo :: HS.Annotated ast => ast Typed -> Scope.NameInfo
nameInfo ast =
  case HS.ann ast of
    TC.Coerced info _src _proof -> info
    TC.Scoped info _src         -> info

nameFromEntity :: Entity -> Name
nameFromEntity entity =
  case entityName entity of
    QualifiedName m ident -> Name [m] ident 0

bindName :: HS.Name Typed -> M Name
bindName hsName =
  case nameInfo hsName of
    Scope.Resolved entity -> do
      let name = nameFromEntity entity
      tell $ mempty{envScope = mempty
          { scopeVariables = Map.singleton entity name } }
      return name
    Scope.Binding entity -> do
      let name = nameFromEntity entity
      tell $ mempty{envScope = mempty
          { scopeVariables = Map.singleton entity name } }
      return name
    -- Scope.Binding _ -> error "bindName: Binding"
    Scope.None -> error "bindName: None"
    Scope.ScopeError err -> error $ "bindName: ScopeError " ++ show err

bindVariable :: HS.Name Typed -> M Variable
bindVariable hsName = do
    name <- bindName hsName
    ty <- lookupType hsName
    return $ Variable name ty

lookupType :: HS.Name Typed -> M TC.Type
lookupType hsName = do
    case nameInfo hsName of
        Resolved entity -> do
            tcEnv <- asks scopeTcEnv
            case Map.lookup entity (tcEnvValues tcEnv) of
                Nothing -> error "Missing type info"
                Just ty -> return ty
        Scope.Binding entity -> do
            tcEnv <- asks scopeTcEnv
            case Map.lookup entity (tcEnvValues tcEnv) of
                Nothing -> error "Missing type info"
                Just ty -> return ty
        _ -> error "Urk"

bindConstructor :: HS.Name Typed -> Int -> M Name
bindConstructor dataCon arity =
    case nameInfo dataCon of
        Scope.Binding entity -> do
            let qname@(QualifiedName m ident) = entityName entity
            let n = Name [m] ident 0
            tell $ mempty{envScope = mempty
                { scopeNodes = Map.singleton qname n
                , scopeVariables = Map.singleton entity n
                , scopeArity = Map.singleton entity arity } }
            return n
        Scope.Resolved _ -> error "bindConstructor: Resolved"
        Scope.None -> error "bindConstructor: None"
        Scope.ScopeError err -> error $ "bindConstructor: ScopeError " ++ show err

resolveName :: HS.Name Typed -> M Name
resolveName hsName =
    case nameInfo hsName of
        Scope.Resolved entity -> do
            let QualifiedName m ident = entityName entity
            let name = Name [m] ident 0
            return name
        -- Resolved gname -> do
        --     asks $ Map.findWithDefault scopeError gname . scopeVariables
        --Scope.Global gname ->
        --    asks $ Map.findWithDefault scopeError gname . scopeConstructors
        _ -> scopeError
  where
    scopeError = error $ "resolveName: Not in scope: " ++
                    getNameIdentifier hsName

-- resolveQualifiedName :: QualifiedName -> M Name
-- resolveQualifiedName qname =
--     asks $ Map.findWithDefault scopeError qname . scopeNodes
--   where
--     scopeError = error $ "resolveGlobalName: Not in scope: " ++ show qname

resolveQName :: HS.QName Typed -> M Variable
resolveQName qname =
    case qname of
        HS.Qual _ _ name          -> do
          n <- resolveName name
          ty <- lookupType name
          return $ Variable n ty
        HS.UnQual _ name          -> do
          n <- resolveName name
          ty <- lookupType name
          return $ Variable n ty
        HS.Special _ HS.UnitCon{} -> return unitCon
        HS.Special _ HS.Cons{}    -> return consCon
        -- HS.Special _ HS.ListCon{} -> return nilCon
        _ -> error $ "HaskellToCore.resolveQName: " ++ show qname

-- XXX: Ugly, ugly code.
-- resolveQGlobalName :: HS.QName Origin -> M Name
-- resolveQGlobalName qname =
--     case qname of
--         HS.Qual _ _ name          -> worker name
--         HS.UnQual _ name          -> worker name
--         HS.Special _ HS.UnitCon{} -> return unitCon
--         HS.Special _ HS.Cons{}    -> return consCon
--         HS.Special _ HS.ListCon{} -> return nilCon
--         _ -> error "HaskellToCore.resolveQName"
--   where
--     worker name =
--         let Origin (Resolved (GlobalName _ qname)) _ = HS.ann name
--         in resolveQualifiedName qname

-- findCoercion :: HS.SrcSpanInfo -> M Coercion
-- findCoercion src = do
--     tiEnv <- asks scopeTcEnv
--     return $ Map.findWithDefault CoerceId src (tcEnvCoercions tiEnv)

-- requireCoercion :: HS.SrcSpanInfo -> M Coercion
-- requireCoercion src = do
--     tiEnv <- asks scopeTcEnv
--     return $ Map.findWithDefault err src (tcEnvCoercions tiEnv)
--   where
--     err = error $ "Coercion required at: " ++ show src

--resolveConstructor :: HS.QName Scoped -> M Name
--resolveConstructor con = do
--    name <- resolveQName con
--    asks

convert :: TcEnv -> HS.Module Typed -> Module
convert tcEnv (HS.Module _ _ _ _ decls) = Module
    { coreForeigns  = envForeigns env
    , coreDecls     = envDecls env
    , coreNodes     = envNodes env
    , coreNewTypes  = envNewTypes env
    , coreNamespace = ns }
  where
    (ns, env) = runM tcEnv $ do
        mapM_ convertDecl decls
convert _ _ = error "HaskellToCore.convert"

-- Return function name.
matchInfo :: [HS.Match Typed] -> HS.Name Typed
matchInfo [] =
    error "Compiler.HaskellToCore.matchInfo"
matchInfo (HS.Match _ name pats _ _:_) = name
matchInfo (HS.InfixMatch _ _ name pats rhs _:_) = name

{-
Sometimes we have introduce new arguments:
fn (Just val) = ...
=>
fn arg = case arg of Just val -> ...

In the above case we cannot find a good name but in many cases we can do
better. Consider:
fn x@(Just val) = ...
=>
fn x = case x of Just val -> ...

fn [] = ...
fn lst = ...
=>
fn lst = case lst of [] -> ...; _ -> ...

matchArgNames uses heuristics to figure out which user variable names can be
reused.
-}
matchArgNames :: [HS.Match Typed] -> [Maybe (HS.Name Typed)]
matchArgNames = map collapse . transpose . map worker
  where
    collapse = listToMaybe . catMaybes
    worker (HS.Match _ _ pats _ _)          = map fromPat pats
    worker (HS.InfixMatch _ pat _ pats _ _) = map fromPat (pat:pats)
    fromPat (HS.PVar _ name)     = Just name
    fromPat (HS.PAsPat _ name _) = Just name
    fromPat (HS.PParen _ pat)    = fromPat pat
    fromPat _                    = Nothing

convertDecl :: HS.Decl Typed -> M ()
convertDecl decl =
    mapM_ pushDecl =<< convertDecl' decl

convertDecl' :: HS.Decl Typed -> M [Decl]
convertDecl' decl =
  case decl of
    HS.FunBind tyDecl matches -> do
      let mbProof =
            case tyDecl of
              TC.Coerced _ _ proof -> WithProof proof
              TC.Scoped{}          -> id
      let name = matchInfo matches
          fnArgNames = matchArgNames matches
          -- arity = length fnArgNames
      -- let Origin _ src = HS.ann name
      -- coercion <- findCoercion src
      ty <- lookupType name
      let argTys = splitTy ty -- (applyCoercion coercion ty)
      argNames <- forM fnArgNames $
        \case
          Nothing -> newName "arg"
          Just name -> bindName name
      let args = zipWith Variable argNames argTys
      decl <- Decl
          <$> pure ty
          <*> bindName name
          <*> (mbProof . Lam args
                  <$> convertMatches args matches)
      return [decl]
    HS.PatBind _ (HS.PVar _ name) rhs _binds -> do
        decl <- Decl
            <$> lookupType name
            <*> bindName name
            <*> convertRhs rhs
        return [decl]
    HS.ForImp _ _conv _safety mbExternal name ty -> do
        let external = fromMaybe (getNameIdentifier name) mbExternal
        foreignTy <- lookupType name
        decl <- Decl
            <$> lookupType name
            <*> bindName name
            <*> convertExternal external foreignTy

        unless (isPrimitive external) $ do
            let (argTypes, _isIO, retType) = ffiTypes foreignTy
            pushForeign Foreign
                { foreignName = external
                , foreignReturn = toCType retType
                , foreignArguments = map toCType argTypes }

        return [decl]

    HS.DataDecl _ HS.DataType{} _ctx _dhead qualCons _deriving -> do
        mapM_ (convertQualCon False) qualCons
        return []
    HS.DataDecl _ HS.NewType{} _ctx _dhead qualCons _deriving -> do
        mapM_ (convertQualCon True) qualCons
        return []
    HS.TypeSig{} -> return []
    _ -> error $ "Compiler.HaskellToCore.convertDecl: " ++ show decl

isPrimitive :: String -> Bool
isPrimitive "realworld#" = True
isPrimitive "cast"       = True
isPrimitive _            = False

convertMatches :: [Variable] -> [HS.Match Typed] -> M Expr
convertMatches args [] = error "Compiler.HaskellToCore.convertMatches"
convertMatches args [HS.InfixMatch _ pat _ pats rhs mbBinds] =
    convertAltPats (zip args (pat:pats)) Nothing =<< convertRhs rhs
convertMatches args [HS.Match _ _ pats rhs mbBinds] =
    convertAltPats (zip args pats) Nothing =<< convertRhs rhs
convertMatches args (HS.Match _ _ pats rhs mbBinds:xs)
    | all isSimplePat pats = do
        rest <- convertMatches args xs
        convertAltPats (zip args pats) (Just rest) =<<
                convertRhs rhs
    | otherwise = do
        rest <- convertMatches args xs
        restBranch <- Variable <$> newName "branch" <*> exprType rest
        e <- convertAltPats (zip args pats) (Just $ Var restBranch) =<<
                convertRhs rhs
        return $ Let (NonRec restBranch rest) e
convertMatches args _ = error "Urk"

convertAltPats :: [(Variable, HS.Pat Typed)] -> Maybe Expr -> Expr -> M Expr
convertAltPats conds failBranch successBranch =
    case conds of
        [] -> pure successBranch
        ((scrut,pat) : more)
            | isSimplePat pat ->
                convertAltPat scrut failBranch pat =<<
                    convertAltPats more failBranch successBranch
            | otherwise -> do
                rest <- convertAltPats more failBranch successBranch
                restBranch <- Variable <$> newName "branch" <*> exprType rest
                e <- convertAltPat scrut failBranch pat (Var restBranch)
                return $ Let (NonRec restBranch rest) e


-- XXX: Don't use Bool for isNewtype
convertQualCon :: Bool -> HS.QualConDecl Typed -> M ()
convertQualCon isNewtype (HS.QualConDecl _ _tyvars _ctx con) =
    convertConDecl isNewtype con

-- XXX: Don't use Bool for isNewtype
convertConDecl :: Bool -> HS.ConDecl Typed -> M ()
convertConDecl isNewtype con =
    case con of
        HS.ConDecl _ name tys -> do

            u <- newUnique
            -- let mkCon = Name [] ("mk" ++ getNameIdentifier name) u

            conName <- bindConstructor name (length tys)

            argNames <- replicateM (length tys) (newName "arg")
            ty <- lookupType name
            let con = Variable conName ty
            -- let args = zipWith Variable argNames (splitTy ty)
            -- pushDecl $ Decl ty mkCon (Lam args $ Con conName args)

            -- pushNode $ NodeDefinition conName (init $ splitTy ty)
            if isNewtype
                then pushNewType $ IsNewType con
                else pushNode $ NodeDefinition conName (init $ splitTy ty)
        --HS.RecDecl _ name fieldDecls -> do
        _ -> error "convertCon"

-- XXX: Temporary measure. 2014-07-11
splitTy :: TC.Type -> [TC.Type]
splitTy (TC.TyForall _ (_ :=> ty)) = splitTy ty
splitTy (TC.TyFun a b)             = a : splitTy b
splitTy ty                         = [ty]

-- applyCoercion :: Coercion -> TcType -> TcType
-- applyCoercion (CoerceAbs new) (TcForall old (ctx :=> ty)) =
--     TcForall new (map predicate ctx :=> worker ty)
--   where
--     env = zip old new
--     predicate (IsIn cls ty) = IsIn cls (worker ty)
--     worker ty =
--       case ty of
--         TcForall{} ->
--           error "Compiler.HaskellToCore.applyCoercion: RankNTypes not supported"
--         TcFun a b -> TcFun (worker a) (worker b)
--         TcApp a b -> TcApp (worker a) (worker b)
--         TcRef v ->
--           case lookup v env of
--             Nothing -> TcRef v
--             Just new -> TcRef new
--         TcCon{} -> ty
--         TcMetaVar{} -> ty
--         TcUnboxedTuple tys -> TcUnboxedTuple (map worker tys)
--         TcTuple tys -> TcTuple (map worker tys)
--         TcList ty -> TcList (worker ty)
--         TcUndefined -> TcUndefined
-- applyCoercion _ ty = ty

toCType :: TC.Type -> CType
toCType ty =
    case ty of
        TC.TyApp (TC.TyCon qname) ty'
            | qname == QualifiedName "LHC.Prim" "Addr" ->
                CPointer (toCType ty')
        TC.TyCon qname
            | qname == QualifiedName "LHC.Prim" "I8" ->
                I8
            | qname == QualifiedName "LHC.Prim" "I32" ->
                I32
            | qname == QualifiedName "LHC.Prim" "Int32" ->
                I32
            | qname == QualifiedName "LHC.Prim" "I64" ->
                I64
            | qname == QualifiedName "LHC.Prim" "Unit" ->
                CVoid
        TC.TyApp (TC.TyCon qname) ty'
            | qname == QualifiedName "LHC.Prim" "IO" ->
                toCType ty'
        TC.TyCon qname
            | qname == QualifiedName "LHC.Prim" "RealWorld#" ->
                I64
        _ -> error $ "toCType: " ++ show ty

-- convertBangType :: HS.BangType Origin -> M Type
-- convertBangType bty =
--     case bty of
--         HS.UnBangedTy _ ty -> convertType ty
--         HS.BangedTy _ ty -> convertType ty
--         _ -> error "convertBangType"


-- cfun :: Addr I8 -> IO ()
-- \ptr -> IO (\s -> WithExternal cfun Void [ptr,s]) (IOUnit boxed s))
-- cfun :: Addr I8 -> IO CInt
-- \ptr -> IO (\s -> WithExternal cfun CInt [ptr,s]) (IOUnit boxed s))
-- cfun :: CInt -> CInt
-- \cint -> WithExternal cfun [cint] boxed
convertExternal :: String -> TC.Type -> M Expr
convertExternal "realworld#" _ty = return (Lit LitVoid)
convertExternal "cast" ty = do
    arg <- Variable <$> newName "arg" <*> pure argType
    return $ Lam [arg] $ Cast (Var arg) retType
  where
    ([argType], _isIO, retType) = ffiTypes ty
convertExternal cName ty
    | isIO = do
        args <- forM argTypes $ \t -> Variable <$> newName "arg" <*> pure t
        primOut <- Variable <$> newName "primOut" <*> pure i32
        s <- Variable
                <$> newName "s"
                <*> pure realWorld
        s' <- Variable
                <$> newName "s'"
                <*> pure realWorld
        -- boxed <- Variable <$> newName "boxed" <*> pure retType

        return $
            Lam args $
            let action = Lam [s] $
                    WithExternal primOut s' cName (map Var args) (Var s) $
                    UnboxedTuple [Var s', App (Con int32Con) (Var primOut)]
            in action -- (App (WithCoercion (CoerceAp [retType]) (Con ioCon)) action)
    | otherwise = do -- not isIO
        args <- forM argTypes $ \t -> Variable <$> newName "arg" <*> pure t
        primOut <- Variable <$> newName "primOut" <*> pure retType
        return $
            Lam args $
            ExternalPure primOut cName (map Var args) $
            Var primOut
  where
    (argTypes, isIO, retType) = ffiTypes ty
-- convertExternal cName ty
--     | isIO      = do
--         out <- newName "out"
--         boxed <- newName "boxed"
--         let outV = Variable out retType
--             boxedV = Variable boxed retType
--         io <- resolveQualifiedName $ QualifiedName "LHC.Prim" "IO"
--         unit <- resolveQualifiedName $ QualifiedName "LHC.Prim" "IOUnit"
--         cint <- resolveQualifiedName $ QualifiedName "LHC.Prim" "Int32"
--         pure $ Lam args $ App (Lam [tmp] (App (Con io) (Var tmp)))
--                 (Lam [s]
--             (WithExternal outV cName args s
--                 (Let (NonRec boxedV $ App (Con cint) (Var outV)) $
--                     App (App (Con unit) (Var boxedV)) (Var s))))
--     -- | otherwise = pure $ Lam args (ExternalPure cName retType args)
--   where
--     tmp = Variable (Name [] "tmp" 0) TcUndefined
--     s = Variable (Name [] "s" 0) TcUndefined -- NodePtr
--     (argTypes, isIO, retType) = ffiTypes ty
--     args =
--         [ Variable (Name [] "arg" 0) t -- (Primitive t)
--         | t <- argTypes ]

--packCType :: CType -> Expr -> M Expr
--packCType

ffiTypes :: TC.Type -> ([TC.Type], Bool, TC.Type)
ffiTypes = worker []
  where
    worker acc ty =
        case ty of
            TC.TyFun t ty' -> worker (t : acc) ty'
            TC.TyApp (TC.TyCon qname) sub
                | qname == QualifiedName "LHC.Prim" "IO"
                    -> (reverse acc, True, sub)
            _ -> (reverse acc, False, ty)
            --_ -> error "ffiArguments"

convertRhs :: HS.Rhs Typed -> M Expr
convertRhs rhs =
    case rhs of
        HS.UnGuardedRhs _ expr -> convertExp expr
        _                      -> error "convertRhs"

convertStmts :: [HS.Stmt Typed] -> M Expr
convertStmts [] = error "convertStmts: Empty list"
convertStmts [end] =
    case end of
        -- HS.Generator _ pat expr
        HS.Qualifier _ expr -> convertExp expr
        _                   -> error $ "convertStmts: " ++ show end
convertStmts (x:xs) =
    case x of
        HS.Generator _ (HS.PVar _ name) expr -> do
            var <- bindVariable name
            expr' <- convertExp expr
            rest <- convertStmts xs
            -- coercion <- findCoercion src
            return $ {-WithCoercion coercion-} primBindIO `App` expr' `App` Lam [var] rest
        HS.Qualifier _ expr -> do
            expr' <- convertExp expr
            rest <- convertStmts xs
            -- coercion <- findCoercion src
            return $ {-WithCoercion coercion-} primThenIO `App` expr' `App` rest
        _ -> error "Urk: statement"

primThenIO :: Expr
primThenIO = Var (Variable name ty)
  where
    name = Name ["LHC.Prim"] "thenIO" 0
    ty = TC.TyForall [aRef, bRef] ([] :=> (ioA `TC.TyFun` ioB `TC.TyFun` ioB))
    aRef = TcVar "a" []
    bRef = TcVar "b" []
    ioA = io `TC.TyApp` TC.TyRef aRef
    ioB = io `TC.TyApp` TC.TyRef bRef

primBindIO :: Expr
primBindIO = Var (Variable name ty)
  where
    name = Name ["LHC.Prim"] "bindIO" 0
    ty = TC.TyForall [aRef, bRef] ([] :=> (ioA `TC.TyFun` ioAB `TC.TyFun` ioB))
    aRef = TcVar "a" []
    bRef = TcVar "b" []
    ioA = io `TC.TyApp` TC.TyRef aRef
    ioB = io `TC.TyApp` TC.TyRef bRef
    ioAB = TC.TyRef aRef `TC.TyFun` ioB

unpackString :: Expr
unpackString = Var (Variable name ty)
  where
    name = Name ["LHC.Prim"] "unpackString#" 0
    ty = TC.TyApp addr i8 `TC.TyFun` TC.TyList char
    addr = TC.TyCon (QualifiedName "LHC.Prim" "Addr")
    i8 = TC.TyCon (QualifiedName "LHC.Prim" "I8")
    char = TC.TyCon (QualifiedName "LHC.Prim" "Char")


findProof :: HS.QName Typed -> Expr -> Expr
findProof name =
    case tyDecl of
      TC.Coerced _ _ proof -> WithProof proof
      TC.Scoped{}          -> id
  where
    tyDecl =
      case name of
        HS.UnQual _ qname -> HS.ann qname
        _                 -> HS.ann name

convertExp :: HS.Exp Typed -> M Expr
convertExp expr =
    case expr of
        HS.Var _ name -> do
          var <- resolveQName name
          return $ findProof name (Var var)
        HS.Con _ name -> do
          var <- resolveQName name
          return $ findProof name (Con var)
        HS.App _ a b ->
            App
                <$> convertExp a
                <*> convertExp b
        HS.InfixApp _ a (HS.QConOp _ con) b -> do
            ae <- convertExp a
            be <- convertExp b
            var <- resolveQName con
            pure $ App (App (findProof con (Con var)) ae) be
        HS.InfixApp _ a (HS.QVarOp _ name) b -> do
            ae <- convertExp a
            be <- convertExp b
            var <- resolveQName name
            pure $ App (App (findProof name (Var var)) ae) be
        HS.Paren _ sub -> convertExp sub
        HS.Lambda _ pats sub ->
            Lam
                <$> sequence [ bindVariable name
                        | HS.PVar _ name <- pats ]
                <*> convertExp sub
        HS.Case _ scrut alts -> do
            scrut' <- convertExp scrut
            scrutVar <- Variable <$> newName "scrut" <*> exprType scrut'
            def <- convertAlts scrutVar alts
            return $ Case scrut' scrutVar (Just def) []
        HS.Lit _ (HS.Char _ c _) ->
            pure $ Con charCon `App` Lit (LitChar c)
        HS.Lit _ (HS.Int _ i _) ->
            pure $ Con intCon `App` (Var i64toi32 `App` Lit (LitInt i))
        HS.Lit _ lit -> pure $ convertLiteralToExpr lit
        HS.Tuple  _ HS.Unboxed exprs -> do
            args <- mapM convertExp exprs
            return $ UnboxedTuple args
        HS.Let _ (HS.BDecls _ binds) expr -> do
            decls <- mapM convertDecl' binds
            Let (Rec [ (Variable name ty, body)
                     | Decl ty name body <- concat decls ])
                <$> convertExp expr
        HS.List _ [] ->
            -- coercion <- requireCoercion src
            return {- $ WithCoercion coercion-} (Con nilCon)
        HS.Do _ stmts ->
            convertStmts stmts
        _ -> error $ "H->C convertExp: " ++ show expr

convertAlts :: Variable -> [HS.Alt Typed] -> M Expr
convertAlts scrut [] = pure $ Case (Var scrut) scrut Nothing []
convertAlts scrut [HS.Alt _ pat rhs Nothing] =
    convertAltPat scrut Nothing pat =<< convertRhs rhs
convertAlts scrut (HS.Alt _ pat rhs Nothing:alts) = do
    rest <- convertAlts scrut alts
    restBranch <- Variable <$> newName "branch" <*> exprType rest
    if isSimplePat pat
        then
            convertAltPat scrut (Just rest) pat =<< convertRhs rhs
        else do
            e <- convertAltPat scrut (Just $ Var restBranch) pat =<< convertRhs rhs
            return $ Let (NonRec restBranch rest) e
convertAlts _ _ = error "Urk: alt"

isSimplePat :: HS.Pat Typed -> Bool
isSimplePat pat =
    case pat of
        HS.PApp _ name pats     -> all isPVar pats
        HS.PInfixApp _ a name b -> all isPVar [a,b]
        HS.PVar{}               -> True
        HS.PLit{}               -> True
        HS.PParen _ pat'        -> isSimplePat pat'
        HS.PList _ pats         -> all isPVar pats
        _                       -> False
  where
    isPVar HS.PVar{} = True
    isPVar _         = False

convertAltPat :: Variable -> Maybe Expr -> HS.Pat Typed -> Expr -> M Expr
convertAltPat scrut failBranch pat successBranch =
    case pat of
        HS.PApp _ name pats -> do
            args <- sequence [ Variable <$> bindName var <*> lookupType var
                             | HS.PVar _ var <- pats ]
            alt <- Alt <$> (ConPat <$> resolveQName name <*> pure args)
                <*> pure successBranch
            return $ Case (Var scrut) scrut failBranch [alt]
        HS.PInfixApp src a con b -> convertAltPat scrut failBranch (HS.PApp src con [a,b]) successBranch
        HS.PTuple _ HS.Unboxed pats -> do
            args <- sequence [ Variable <$> bindName var <*> lookupType var
                             | HS.PVar _ var <- pats ]
            alt <- Alt (UnboxedPat args)
                <$> pure successBranch
            return $ Case (Var scrut) scrut failBranch [alt]
        HS.PWildCard _ ->
            return successBranch
        HS.PVar _ var -> do
            var' <- Variable <$> bindName var <*> lookupType var
            -- XXX: Very hacky. We cannot compare on types yet.
            if varName var' == varName scrut
              then return successBranch
              else return $ Let (NonRec var' (Var scrut)) successBranch
        -- 0 -> ...
        -- I# i -> case i of
        --            0# -> ...
        HS.PLit _ _sign (HS.Int _ int _) -> do
            intVar <- Variable <$> newName "i" <*> pure i32
            intVar64 <- Variable <$> newName "i64" <*> pure i64
            let alt = Alt (ConPat intCon [intVar]) $
                      Case (Var i32toi64 `App` Var intVar) intVar64 failBranch
                      [Alt (LitPat (LitInt int)) successBranch]
            return $ Case (Var scrut) scrut Nothing [alt]
        HS.PLit _ _sign lit -> do
            alt <- Alt (LitPat $ convertLiteral lit)
                <$> pure successBranch
            return $ Case (Var scrut) scrut failBranch [alt]
        HS.PParen _ pat' ->
            convertAltPat scrut failBranch pat' successBranch
        HS.PList _ [] -> do
            let alt = Alt (ConPat nilCon []) successBranch
            return $ Case (Var scrut) scrut failBranch [alt]
        _ -> error $ "Compiler.HaskellToCore.convertAltPat: " ++ show pat

_convertAlt :: HS.Alt Typed -> M Alt
_convertAlt alt =
    case alt of
        HS.Alt _ (HS.PApp _ name pats) rhs Nothing -> do
            args <- sequence [ Variable <$> bindName var <*> lookupType var
                             | HS.PVar _ var <- pats ]
            Alt <$> (ConPat <$> resolveQName name <*> pure args)
                <*> convertRhs rhs
        HS.Alt _ (HS.PTuple _ HS.Unboxed pats) rhs Nothing -> do
            args <- sequence [ Variable <$> bindName var <*> lookupType var
                             | HS.PVar _ var <- pats ]
            Alt (UnboxedPat args)
                <$> convertRhs rhs
        HS.Alt _ (HS.PLit _ _sign lit) rhs Nothing ->
            Alt (LitPat $ convertLiteral lit)
                <$> convertRhs rhs
        -- HS.Alt _ (HS.PVar _ var) rhs Nothing ->
        --     Alt <$> (VarPat <$> (Variable <$> bindName var <*> lookupType var))
        --         <*> convertRhs rhs
        _ -> error $ "convertAlt: " ++ show alt

convertLiteralToExpr :: HS.Literal Typed -> Expr
convertLiteralToExpr lit =
    case lit of
        HS.PrimString _ str _ -> Lit $ LitString str
        HS.PrimInt _ int _    -> Lit $ LitInt int
        HS.PrimChar _ char _  -> Lit $ LitChar char
        HS.String _ str _     -> App unpackString (Lit $ LitString str)
        _                     -> error $ "convertLiteral: " ++ show lit

convertLiteral :: HS.Literal Typed -> Literal
convertLiteral lit =
    case lit of
        HS.PrimString _ str _ -> LitString str
        HS.PrimInt _ int _    -> LitInt int
        HS.PrimChar _ char _  -> LitChar char
        _                     -> error $ "convertLiteral: " ++ show lit

_toEntity :: HS.QName Typed -> Entity
_toEntity qname =
    case nameInfo qname of
        Resolved entity -> entity
        _               -> error $ "toGlobalName: " ++ show qname

exprType :: Expr -> M TC.Type
exprType expr =
    case expr of
        Var v -> return (varType v)
        App a b -> do
            aType <- exprType a
            case aType of
                TC.TyFun _ ret                       -> return ret
                TC.TyForall _ (_ :=> TC.TyFun _ ret) -> return ret
                _                                    -> return TC.TyUndefined
        -- WithCoercion _ e -> exprType e
        Let _ e -> exprType e
        LetStrict _ _ e -> exprType e
        Case _ _ (Just e) _ -> exprType e
        Case _ _ Nothing (Alt _ e:_) -> exprType e
        _ -> return TC.TyUndefined




getNameIdentifier :: HS.Name l -> String
getNameIdentifier (HS.Ident _ ident)   = ident
getNameIdentifier (HS.Symbol _ symbol) = symbol





-- LHC.Prim builtins
i32, i64, realWorld, io, int32, charTy, intTy :: TC.Type
i32 = TC.TyCon $ QualifiedName "LHC.Prim" "I32"
i64 = TC.TyCon $ QualifiedName "LHC.Prim" "I64"
realWorld = TC.TyCon $ QualifiedName "LHC.Prim" "RealWorld#"
io = TC.TyCon $ QualifiedName "LHC.Prim" "IO"
int32 = TC.TyCon $ QualifiedName "LHC.Prim" "Int32"
charTy = TC.TyCon $ QualifiedName "LHC.Prim" "Char"
intTy = TC.TyCon $ QualifiedName "LHC.Prim" "Int"

-- data Int = I# I32
intCon :: Variable
intCon = Variable (Name ["LHC.Prim"] "I#" 0)
  (i32 `TC.TyFun` intTy)

-- data Char = C# I32
charCon :: Variable
charCon = Variable (Name ["LHC.Prim"] "C#" 0)
  (i32 `TC.TyFun` charTy)

-- data List a = Nil | Cons a (List a)
nilCon :: Variable
nilCon = Variable (Name ["LHC.Prim"] "Nil" 0)
    (TC.TyForall [a] ([] :=> TC.TyList (TC.TyRef a)))
  where
    a = TcVar "a" []

-- data List a = Nil | Cons a (List a)
consCon :: Variable
consCon = Variable (Name ["LHC.Prim"] "Cons" 0)
    (TC.TyForall [a] ([] :=> (TC.TyRef a `TC.TyFun` TC.TyList (TC.TyRef a) `TC.TyFun` TC.TyList (TC.TyRef a))))
  where
    a = TcVar "a" []

-- data Unit = Unit
unitCon :: Variable
unitCon = Variable (Name ["LHC.Prim"] "Unit" 0)
  (TC.TyTuple [])

-- newtype IO a = IO (RealWorld# -> (# RealWorld#, a #))
_ioCon :: Variable
_ioCon = Variable (Name ["LHC.Prim"] "IO" 0)
    $ TC.TyForall [a] ([] :=> ((realWorld `TC.TyFun` TC.TyUnboxedTuple [realWorld, TC.TyRef a]) `TC.TyFun` TC.TyApp io (TC.TyRef a)))
  where
    a = TcVar "a" []
  -- (RealWorld# -> (# RealWorld#, retType #)) -> IO retType

int32Con, i32toi64, i64toi32 :: Variable
-- data Int32 = Int32 I32
int32Con = Variable (Name ["LHC.Prim"] "Int32" 0)
  (i32 `TC.TyFun` int32)

i32toi64 = Variable (Name ["LHC.Prim"] "i32toi64" 0) (TC.TyFun i32 i64)
i64toi32 = Variable (Name ["LHC.Prim"] "i64toi32" 0) (TC.TyFun i64 i32)
