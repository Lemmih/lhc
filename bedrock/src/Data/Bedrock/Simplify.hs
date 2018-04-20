{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Data.Bedrock.Simplify ( simplify, mergeAllocsModule ) where

import           Control.Applicative  (Applicative, pure, (<$>), (<*>))
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Map             (Map)
import qualified Data.Map             as Map

import           Data.Bedrock
import           Data.Bedrock.Misc

data Env = Env
    { envRenaming  :: Map Variable Variable
    , envAddresses :: Map Variable (Variable, Int)
    , envConstant  :: Map Variable (NodeName, [Variable])
    , envStores    :: Map Variable (NodeName, [Variable])
    }
newtype M a = M { unM :: ReaderT Env (State AvailableNamespace) a }
    deriving
        ( Monad, MonadReader Env, Applicative, Functor
        , MonadState AvailableNamespace )

simplify :: Module -> Module
simplify m = runM (simplifyModule m)
  where
    runM action = evalState (runReaderT (unM action) env) st
    st = modNamespace m
    env = Env
        { envRenaming  = Map.empty
        , envAddresses = Map.empty
        , envConstant  = Map.empty
        , envStores    = Map.empty }

simplifyModule :: Module -> M Module
simplifyModule m = do
    fns <- mapM simplifyFunction (functions m)
    ns <- get
    return m{ functions = fns, modNamespace = ns }

simplifyFunction :: Function -> M Function
simplifyFunction fn = do
    body <- simplifyBlock (fnBody fn)
    return fn{fnBody = body}

simplifyBlock :: Block -> M Block
simplifyBlock block =
    case block of
        Bind vars (Application fn args) (Return rets) | vars == rets ->
            simplifyBlock $ TailCall fn args
        {-Case scrut _mbDefaultBranch
                [Alternative (NodePat node []) branch] -> do
            clone <- cloneVariable scrut
            bindVariable scrut clone $
                Bind [clone] (Unit (NodeArg node [])) <$>
                    simplifyBlock branch-}
        Bind [ptr] expr@(Store name vars) rest ->
            bindStore ptr name vars $
            Bind [ptr]
                <$> simplifyExpression expr
                <*> simplifyBlock rest
        Bind [node] expr@(MkNode name vars) rest ->
            bindConstant node name vars $
            Bind [node]
                <$> simplifyExpression expr
                <*> simplifyBlock rest
        Bind rets (Apply ptr arg) rest -> do
            mbConst <- lookupStore ptr
            case mbConst of
                Just (FunctionName fnName 1, args) ->
                    simplifyBlock $
                        Bind rets (Application fnName (args ++ [arg])) rest
                Just (FunctionName fnName n, args) ->
                    simplifyBlock $
                        Bind rets (Store (FunctionName fnName (n-1)) (args ++ [arg])) rest
                _Nothing ->
                    Bind rets
                        <$> (Apply <$> resolve ptr <*> resolve arg)
                        <*> simplifyBlock rest
        Bind [] TypeCast{} rest ->
            simplifyBlock rest
        Bind [] Literal{} rest ->
            simplifyBlock rest
        Bind [dst] (TypeCast src) rest | variableType dst == variableType src ->
              bindVariable dst src (simplifyBlock rest)
        Bind [dst] (Address src idx) rest -> do
          src' <- resolve src
          bindAddress dst src' idx $
            Bind [dst] <$> lookupIndexed src' idx Address <*> simplifyBlock rest
        Bind [] (Write dst idx src) rest -> do
          dst' <- resolve dst
          src' <- resolve src
          Bind [] <$> lookupIndexed dst' idx (\d i -> Write d i src') <*> simplifyBlock rest
        Bind binds simple rest ->
            Bind binds
                <$> simplifyExpression simple
                <*> simplifyBlock rest
        Case scrut Nothing alts ->
            Case
                <$> resolve scrut
                <*> pure Nothing
                <*> mapM simplifyAlternative alts
        Case scrut (Just defaultBranch) alts ->
            Case
                <$> resolve scrut
                <*> (Just <$> simplifyBlock defaultBranch)
                <*> mapM simplifyAlternative alts
        Return vars -> Return <$> mapM resolve vars
        TailCall fnName vars -> TailCall fnName <$> mapM resolve vars
        Exit -> pure Exit
        Panic msg -> pure $ Panic msg
        Invoke n cont vars -> Invoke n <$> resolve cont <*> mapM resolve vars
        _ -> return block

simplifyAlternative :: Alternative -> M Alternative
simplifyAlternative (Alternative pattern branch) =
    Alternative pattern <$> simplifyBlock branch


simplifyExpression :: Expression -> M Expression
simplifyExpression expr =
    case expr of
        Application fn vars -> Application fn <$> mapM resolve vars
        Eval var -> do
            mbNode <- lookupStore var
            case mbNode of
                Nothing -> Eval <$> resolve var
                -- FIXME: We should update the heap object with
                --        an indirection to the newly created object.
                Just (FunctionName fnName 0, args) ->
                    simplifyExpression $
                    Application fnName args
                Just (nodeName, args) ->
                    simplifyExpression $ TypeCast var
        Apply a b -> Apply <$> resolve a <*> resolve b
        MkNode name vars -> MkNode name <$> mapM resolve vars
        TypeCast var -> TypeCast <$> resolve var
        CCall fn vars -> CCall fn <$> mapM resolve vars
        Store node vars -> Store node <$> mapM resolve vars
        Write v1 idx v2 -> Write <$> resolve v1 <*> pure idx <*> resolve v2
        Address v idx -> Address <$> resolve v <*> pure idx

        _ -> pure expr







-- Note: This optimisation is only valid after the CPS transformation.
mergeAllocsModule :: Module -> Module
mergeAllocsModule m =
    m{ functions = [ fn{ fnBody = mergeAllocs (fnBody fn) }
                   | fn <- functions m] }

mergeAllocs :: Block -> Block
mergeAllocs block0 = applyAlloc 0 n block'
  where
    applyAlloc slob allocs block =
        case slob `compare` allocs of
            -- XXX: No need to decrement the heap pointer since allocs only
            --      make sure there's available space but don't actually
            --      increment the pointer.
            GT -> block -- Bind [] (BumpHeapPtr (negate (slob-allocs))) block
            EQ -> block
            LT -> Bind [] (Alloc (allocs-slob)) block
    (n, block') = worker 0 block0
    worker n block =
        case block of
            -- Hoist allocs out of case alternatives iff:
            --  1. There are allocs before the Case statement, or
            --  2. There are allocs in all of the Case branches.
            -- Otherwise treat the branches on their own.
            Case scrut defaultBranch alts ->
                let hoist = n > 0 || all (>0) branches
                    slob = blockAlloc - n
                    maxBranchAlloc = maximum (0:branches)
                    branches = maybe id (:) (fmap fst def) (map fst alts')
                    def = fmap (worker 0) defaultBranch
                    alts' = [ (branchAlloc, Alternative pattern branch'')
                            | Alternative pattern branch <- alts
                            , let (branchAlloc, branch') = worker 0 branch
                            , let branch'' = applyAlloc slob branchAlloc branch' ]
                    blockAlloc
                        | hoist = n + maxBranchAlloc
                        | otherwise = n
                in (blockAlloc, Case scrut (fmap snd def) (map snd alts'))
            Bind [] (Alloc size) rest ->
                worker (n+size) rest
            Bind binds expr rest ->
                let (n', rest') = worker n rest
                in (n', Bind binds expr rest')
            _ -> (n, block)




--------------------------------------------------------
-- Utils

_cloneVariable :: Variable -> M Variable
_cloneVariable var = do
    ns <- get
    let (idNum, ns') = newIDByType ns (variableType var)
        name = (variableName var){ nameUnique = idNum }
    put ns'
    return var{ variableName = name }

resolve :: Variable -> M Variable
resolve var = do
    m <- asks envRenaming
    return $ Map.findWithDefault var var m

bindVariable :: Variable -> Variable -> M a -> M a
bindVariable old new fn = do
    new' <- resolve new
    local
        (\env -> env{
            envRenaming = Map.insert old new' (envRenaming env),
            envStores = case Map.lookup old (envStores env) of
              Nothing   -> envStores env
              Just node -> Map.insert new' node (envStores env),
            envConstant = case Map.lookup old (envConstant env) of
                Nothing   -> envConstant env
                Just node -> Map.insert new' node (envConstant env)
          })
        fn

_lookupConstant :: Variable -> M (Maybe (NodeName, [Variable]))
_lookupConstant var = do
    var' <- resolve var
    m <- asks envConstant
    return $ Map.lookup var' m

bindConstant :: Variable -> NodeName -> [Variable] -> M a -> M a
bindConstant var node vars = local $ \env ->
    env{ envConstant = Map.insert var (node, vars) (envConstant env) }

bindAddress :: Variable -> Variable -> Int  -> M a -> M a
bindAddress dst src idx = local $ \env ->
  env{ envAddresses = Map.insert dst (src,idx) (envAddresses env) }

lookupIndexed :: Variable -> Int -> (Variable -> Int -> Expression) -> M Expression
lookupIndexed src idx fn = do
  addrs <- asks envAddresses
  case Map.lookup src addrs of
    Just (orig, prevIdx) -> fn <$> resolve orig <*> pure (prevIdx+idx)
    Nothing              -> fn <$> resolve src <*> pure idx

lookupStore :: Variable -> M (Maybe (NodeName, [Variable]))
lookupStore var = do
    var' <- resolve var
    m <- asks envStores
    return $ Map.lookup var' m

bindStore :: Variable -> NodeName -> [Variable] -> M a -> M a
bindStore var node vars = local $ \env ->
    env{ envStores = Map.insert var (node, vars) (envStores env) }
