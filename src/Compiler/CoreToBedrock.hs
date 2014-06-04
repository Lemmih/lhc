{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Compiler.CoreToBedrock where


import           Compiler.Core                   as Core
import qualified Compiler.HaskellToCore          as Haskell
import           Data.Bedrock                    as Bedrock
import           Data.Bedrock.Misc
import           Data.Bedrock.PrettyPrint
import qualified Language.Haskell.Exts.Annotated as HS
import           Language.Haskell.Scope          (resolve)

import           Control.Applicative
import           Control.Monad.Reader
import           Control.Monad.Writer
import           Control.Monad.RWS
import           Data.Map                        (Map)
import qualified Data.Map                        as Map

import Data.Bedrock.Compile

--test :: IO ()
--test = do
--    HS.ParseOk m <- HS.parseFile "BedrockIO.hs"
--    let (errs, m') = resolve m
--    mapM_ print errs
--    let core = Haskell.convert m'
--    let bedrock = convert core
--    print (ppModule bedrock)
    --compileWithOpts True True "FromHaskell.rock" bedrock

convert :: Core.Module -> Bedrock.Module
convert m = Bedrock.Module
  { modForeigns  = coreForeigns m
  , nodes        = coreNodes m
  , entryPoint   = Name [] "entryPoint" 33
  , functions    = fns
  , modNamespace = ns }
  where
    (fns, ns) = runM (convertModule m) (coreNamespace m)

convertModule :: Core.Module -> M ()
convertModule m = setArities arities $ do
    mapM_ convertDecl (coreDecls m)
  where
    arities =
        [ (fn, arity)
        | Core.Decl fn expr <- coreDecls m
        , let arity = case expr of Lam vars _ -> length vars; _ -> 0 ]

data Env = Env
    { envScope :: [Variable]
    , envArity :: Map Name Int
    , envRoot  :: Name
    , envLocation :: [String]
    }
newtype M a = M { unM :: RWS Env [Function] AvailableNamespace a }
    deriving
        ( Monad, MonadWriter [Function], MonadReader Env
        , MonadState AvailableNamespace
        , Applicative, Functor )
runM ::  M a -> AvailableNamespace -> ([Function], AvailableNamespace)
runM action ns = (fns, ns') 
  where
    (ns',fns) = execRWS (unM action) env ns
    env = Env
        { envScope    = []
        , envArity    = Map.empty
        , envRoot     = error "envRoot"
        , envLocation = []
        }

setArity :: Name -> Int -> M a -> M a
setArity fn arity = local $ \env -> env
    { envArity = Map.insert fn arity (envArity env) }

setArities :: [(Name, Int)] -> M a -> M a
setArities arities = local $ \env -> env
    { envArity = Map.union (Map.fromList arities) (envArity env) }

lookupArity :: Name -> M (Maybe Int)
lookupArity fn = asks $ Map.lookup fn . envArity

newName :: [String] -> String -> M Name
newName orig ident = do
    ns <- get
    let (idNum, ns') = newGlobalID ns
    put ns'
    return $ Name orig ident idNum

newVariable :: [String] -> String -> Type -> M Variable
newVariable orig ident ty = do
    name <- newName orig ident
    return $ Variable name ty

pushFunction :: Either String Name -> Bedrock.Block -> M Name
pushFunction origin body = do
    scope <- asks envScope
    Name orig ident _ <- asks envRoot
    name <- case origin of
                Left tag -> newName (orig++[ident]) tag
                Right n -> return n
    let fn = Function
            { fnName = name
            , fnAttributes = []
            , fnArguments = scope
            , fnResults = [Node]
            , fnBody = body }
    tell [fn]
    return name

convertDecl :: Core.Decl -> M ()
convertDecl (Core.Decl name (Lam vars expr)) = do
    body <- local (\env -> env{envRoot = name}) $
            bind vars $ convertExpr False expr (\val -> pure $ Return [val])
    let fn = Function
            { fnName = name
            , fnAttributes = []
            , fnArguments = vars
            , fnResults = [Node]
            , fnBody = body
            }
    tell [fn]
convertDecl (Core.Decl name expr) = do
    body <- local (\env -> env{envRoot = name}) $
            convertExpr False expr (\val -> pure $ Return [val])
    let fn = Function
            { fnName = name
            , fnAttributes = []
            , fnArguments = []
            , fnResults = [Node]
            , fnBody = body
            }
    tell [fn]

--convertExpr :: Core.Expr -> (Variable -> M Bedrock.Block) -> M Bedrock.Block
--convertExpr expr rest =
--    convertExprLazy expr $ \val -> do
--    let tmp = Variable (Name [] "strict" 0) Node
--        attrs = MemAttributes False Nothing
--    Bind [tmp] (Eval val)
--        <$> rest tmp

bind :: [Variable] -> M a -> M a
bind vs = local $ \env -> env{ envScope = envScope env ++ vs }

setOrigin :: M a -> M a
setOrigin = local $ \env ->
    let Name orig ident _ = envRoot env
    in env { envLocation = orig ++ [ident] }

convertExpr :: Bool -> Core.Expr -> (Variable -> M Bedrock.Block) -> M Bedrock.Block
convertExpr lazy expr rest =
    case expr of
        --CaseUnboxed scrut binds branch | not lazy ->
        --    convertExpr False scrut $ \vars ->
        Con name args | lazy -> do
            tmp <- newVariable [] "con" NodePtr
            Bind [tmp] (Store (ConstructorName name) args)
                <$> rest tmp
        Con name args | not lazy -> do
            tmp <- newVariable [] "con" Node
            Bind [tmp] (MkNode (ConstructorName name) args)
                <$> rest tmp
        Var v | lazy -> do
            let fn = variableName v
            mbArity <- lookupArity fn
            case mbArity of
                Nothing -> rest v
                Just arity -> do
                    tmp <- newVariable [] "thunk" NodePtr
                    Bind [tmp] (Store (FunctionName fn arity) [])
                        <$> rest tmp
        Var v | not lazy -> do
            let fn = variableName v
            mbArity <- lookupArity fn
            case mbArity of
                Nothing -> do
                    tmp <- deriveVariable v "eval" Node
                    Bind [tmp] (Eval v)
                        <$> rest tmp
                Just arity -> do
                    tmp <- newVariable [] "thunk" Node
                    Bind [tmp] (MkNode (FunctionName fn arity) [])
                        <$> rest tmp
        Core.Lit (Core.LitString str) -> do
            tmp <- newVariable [] "lit" (Primitive (CPointer I8))
            Bind [tmp] (Bedrock.Literal (LiteralString str))
                <$> rest tmp
        Core.Lit (Core.LitInt int) -> do
            tmp <- newVariable [] "int" (Primitive I64)
            Bind [tmp] (Bedrock.Literal (LiteralInt int))
                <$> rest tmp
        App a b | lazy -> do
            body <- --setOrigin $
                convertExpr False a $ \aVal ->
                convertExpr True b $ \bVal ->  do
                ret <- deriveVariable aVal "apply" Node
                Bind [ret] (Apply aVal bVal)
                    <$> pure (Return [ret])
            scope <- asks envScope
            node <- pushFunction (Left "ap") body
            tmp <- newVariable [] "ap" NodePtr
            Bind [tmp] (Store (FunctionName node 0) scope)
                <$> rest tmp
        App a b | not lazy ->
            convertExpr False a $ \aVal -> -- node
            convertExpr True b $ \bVal -> do -- nodeptr
            ret <- deriveVariable aVal "apply" Node
            Bind [ret] (Apply aVal bVal)
                    <$> rest ret
        Lam v sub | lazy -> do
            scope <- asks envScope
            body <- bind v $ convertExpr False sub (\val -> pure $ Return [val])
            node <- bind v $ pushFunction (Left "lambda") body
            tmp <- newVariable [] "tmp" NodePtr
            Bind [tmp] (Store (FunctionName node (length v)) scope)
                <$> rest tmp
        --Lam v sub | not lazy -> do
        --    scope <- asks envScope
        --    body <- bind v $ convertExpr True sub (\val -> pure $ Return [val])
        --    node <- bind v $ pushFunction (Left "lam") body
        --    let tmp = Variable (Name [] "tmp" 0) Node
        --    Bind [tmp] (MkNode (FunctionName node (length v)) scope)
        --        <$> rest tmp
        Core.Case scrut alts | not lazy ->
            convertExpr False scrut $ \val ->
            Bedrock.Case val Nothing <$>
            mapM convertAlt alts
        --External external CVoid args st | not lazy -> do 
        --    let tmp = Variable (Name [] "tmp" 0) NodePtr
        --        ret = Variable (Name [] "ret" 0) Node
        --        unit = ConstructorName (Name ["Main"] "IOUnit" 0)
        --        tuple = ConstructorName (Name ["Internal"] "()" 0)
        --    (Bind [] (CCall external args) .
        --     Bind [tmp] (Store tuple []) .
        --     Bind [ret] (MkNode unit [tmp, st]))
        --        <$> rest ret
        WithExternal binder external retType args st scoped | not lazy -> do 
            Bind [binder] (CCall external args)
                <$> convertExpr False scoped rest 




        _ | lazy -> error $ "convertExpr: " ++ show (lazy, expr)
        _ | not lazy ->
            convertExpr True expr $ \val -> do
            tmp <- deriveVariable val "eval" Node
            Bind [tmp] (Eval val)
                <$> rest tmp

deriveVariable :: Variable -> String -> Type -> M Variable
deriveVariable (Variable (Name orig ident _) _) tag ty = do
    path <- asks envLocation
    name <- newName (path ++ orig ++ [ident]) tag
    return $ Variable name ty

convertAlt :: Alt -> M Bedrock.Alternative
convertAlt (Alt pattern branch) =
    case pattern of
        ConPat name args ->
            Alternative (NodePat (ConstructorName name) args)
                <$> convertExpr False branch (pure . Return . return)
        Core.LitPat{} -> error "convertAlt"
