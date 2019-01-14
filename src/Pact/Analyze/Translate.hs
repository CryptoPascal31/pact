{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MonadFailDesugaring        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}

module Pact.Analyze.Translate where

import qualified Algebra.Graph              as Alga
import           Control.Applicative        (Alternative (empty))
import           Control.Lens               (Lens', at, cons, makeLenses, snoc,
                                             to, use, view, zoom, (%=), (%~),
                                             (+~), (.=), (.~), (<>~),
                                             (?=), (^.), (^?))
import           Control.Monad              (join, replicateM, (>=>))
import           Control.Monad.Except       (Except, MonadError, throwError)
import           Control.Monad.Fail         (MonadFail (fail))
import           Control.Monad.Reader       (MonadReader (local),
                                             ReaderT (runReaderT))
import           Control.Monad.State.Strict (MonadState, StateT, evalStateT,
                                             modify', runStateT)
import           Data.Foldable              (foldl', for_)
import qualified Data.Map                   as Map
import           Data.Map.Strict            (Map)
import           Data.Maybe                 (fromMaybe, isNothing)
import           Data.Proxy                 (Proxy)
-- import qualified Data.Set                   as Set
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Thyme                 (parseTime)
import           Data.Traversable           (for)
import           Data.Type.Equality         ((:~:) (Refl))
import           GHC.Natural                (Natural)
import           GHC.TypeLits
import           System.Locale              (defaultTimeLocale)

import           Pact.Types.Lang            (Info, Literal (..), PrimType (..), Type (TyFun, TyPrim, TySchema, TyUser, TyVar))
import qualified Pact.Types.Lang            as Pact
import           Pact.Types.Persistence     (WriteType)
import           Pact.Types.Typecheck       (AST, Named (Named), Node, aId,
                                             aNode, aTy, tiName, _aTy)
import qualified Pact.Types.Typecheck       as Pact
import           Pact.Types.Util            (tShow)

import           Pact.Analyze.Feature       hiding (TyFun, TyVar, Var, col,
                                             list, obj, str, time)
import           Pact.Analyze.Patterns
import           Pact.Analyze.Types
import           Pact.Analyze.Util


-- * Translation types

data TranslateFailure = TranslateFailure
  { _translateFailureInfo :: !Info
  , _translateFailure     :: !TranslateFailureNoLoc
  } deriving Show

data TranslateFailureNoLoc
  = BranchesDifferentTypes EType EType
  | NonStringLitInBinding (AST Node)
  | EmptyBody
  | MalformedArithOp Text [AST Node]
  | MalformedLogicalOp Text [AST Node]
  | MalformedComparison Text [AST Node]
  | NotConvertibleToSchema (Pact.Type Pact.UserType)
  | TypeMismatch EType EType
  | UnexpectedNode (AST Node)
  | MissingConcreteType (Pact.Type Pact.UserType)
  | MonadFailure String
  | NonStaticColumns (AST Node)
  | BadNegationType (AST Node)
  | BadTimeType (AST Node)
  | NonConstKey (AST Node)
  | FailedVarLookup Text
  | NoPacts (AST Node)
  | NoKeys (AST Node)
  | NoReadMsg (AST Node)
  | DeprecatedList Node
  | SimpleTypeRequired
  | TypeError Node
  | FreeVarInvariantViolation Text
  | UnhandledType Node (Pact.Type Pact.UserType)
  deriving (Eq, Show)

describeTranslateFailureNoLoc :: TranslateFailureNoLoc -> Text
describeTranslateFailureNoLoc = \case
  BranchesDifferentTypes t1 t2 -> "two branches unexpectedly have different types: (" <> tShow t1 <> ") vs (" <> tShow t2 <> ")"
  NonStringLitInBinding ast -> "We only support analysis of binding forms (bind / with-read) binding string literals. Instead we found " <> tShow ast
  EmptyBody -> "can't translate an empty body"
  MalformedArithOp op args -> "Unsupported arithmetic op " <> op <> " with args " <> tShow args
  MalformedLogicalOp op args -> "Unsupported logical op " <> op <> " with args " <> tShow args
  MalformedComparison op args -> "Unsupported comparison op " <> op <> " with args " <> tShow args
  NotConvertibleToSchema ty -> "Expected a schema, but found " <> tShow ty
  TypeMismatch ty1 ty2 -> "Type mismatch: (" <> tShow ty1 <> ") vs (" <> tShow ty2 <> ")"
  -- Uncomment for debugging
  -- UnexpectedNode ast -> "Unexpected node in translation: " <> tShow ast
  UnexpectedNode _ast -> "Analysis doesn't support this construct yet"
  MissingConcreteType ty -> "The typechecker should always produce a concrete type, but we found " <> tShow ty
  MonadFailure str -> "Translation failure: " <> T.pack str
  NonStaticColumns col -> "When reading only certain columns we require all columns to be concrete in order to do analysis. We found " <> tShow col
  BadNegationType node -> "Invalid: negation of a non-integer / decimal: " <> tShow node
  BadTimeType node -> "Invalid: days / hours / minutes applied to non-integer / decimal: " <> tShow node
  NonConstKey k -> "Pact can currently only analyze constant keys in objects. Found " <> tShow k
  FailedVarLookup varName -> "Failed to look up a variable (" <> varName <> "). This likely means the variable wasn't properly bound."
  NoPacts _node -> "Analysis of pacts is not yet supported"
  NoKeys _node  -> "`keys` is not yet supported"
  NoReadMsg _ -> "`read-msg` is not yet supported"
  DeprecatedList node -> "Analysis doesn't support the deprecated `list` function -- please update to literal list syntax: " <> tShow node
  SimpleTypeRequired -> "Lists are currently limited to holding simply-typed objects"
  TypeError node -> "\"impossible\" post-typechecker type error in node: " <> tShow node
  FreeVarInvariantViolation msg -> msg
  UnhandledType node ty -> "Found a type we don't know how to translate yet: " <> tShow ty <> " at node: " <> tShow node

data TranslateEnv
  = TranslateEnv
    { _teInfo           :: Info
    , _teNodeVars       :: Map Node (Munged, VarId)
    , _teRecoverability :: Recoverability
    , _teScopesEntered  :: Natural

    -- How to generate the next tag and vertex ids. Usually this is via @genId@
    -- (see @mkTranslateEnv@) but in testing these return a constant @0@.
    , _teGenTagId       :: forall m. MonadState TagId  m => m TagId
    , _teGenVertex      :: forall m. MonadState Vertex m => m Vertex
    }

mkTranslateEnv :: Info -> [Arg] -> TranslateEnv
mkTranslateEnv info args
  = TranslateEnv info nodeVars mempty 0 (genId id) (genId id)
  where
    -- NOTE: like in Check's moduleFunChecks, this assumes that toplevel
    -- function arguments are the only variables for which we do not use munged
    -- names:
    nodeVars = foldl'
      (\m (Arg nm vid node _ety) ->
        Map.insert node (coerceUnmungedToMunged nm, vid) m)
      Map.empty
      args

    coerceUnmungedToMunged :: Unmunged -> Munged
    coerceUnmungedToMunged (Unmunged nm) = Munged nm

data TranslateState
  = TranslateState
    { _tsNextTagId     :: TagId
    , _tsNextVarId     :: VarId
    , _tsGraph         :: Alga.Graph Vertex
      -- ^ The execution graph we've built so far. This is expanded upon as we
      -- translate an entire function.
    , _tsPathHead      :: Vertex
      -- ^ The "latest" vertex/current path of the graph. This starts out as
      -- the single initial vertex. it splits into two if we hit a conditional,
      -- and rejoins afterwards.
    , _tsNextVertex    :: Vertex
    , _tsEdgeEvents    :: Map Edge [TraceEvent]
      -- ^ Events added to each new 'Edge' upon creating a new 'Vertex' which
      -- closes/completes the 'Edge'.
    , _tsPendingEvents :: SnocList TraceEvent
      -- ^ Events being accumulated until the creation of the next 'Vertex'.
    , _tsCurrentPath   :: Path
      -- ^ Path to be associated with the 'Edge' formed by the creation of the
      -- next 'Vertex'.
    , _tsPathEdges     :: Map Path [Edge]
      -- ^ Graph edges corresponding to a given execution "path".
      --
      -- 'TraceSubpathStart's are emitted once for each path: at the start of
      -- an execution trace, and at the beginning of either side of a
      -- conditional. After a conditional, we resume the path from before the
      -- conditional. Either side of a conditional will contain a minimum of
      -- two edges: splitting away from the other branch, and then rejoining
      -- back to the other branch at the join point. The following program:
      --
      --     (defun test ()
      --       (if true 1 2))
      --
      -- will result in the following diagram, with six total edges (where /,
      -- \, and - are edges):
      --        .
      --       / \
      --     ->   ->
      --       \./
      --
      -- The initial edge leading into the conditional, two for each branch,
      -- and a final edge after the two branches have rejoined one another. We
      -- must have two edges for each branch so that we can unambiguously talk
      -- about either branch in our graph representation, where we only one
      -- permit one edge in a given direction between two vertices.
      --
      -- Also note that in the presence of nested conditionals, these
      -- "branch-out" and "rejoin" edges will not be contiguous in the graph on
      -- the side of the outer conditional which contains the nested
      -- conditional:
      --       ......
      --     _/  .   \_
      --      \ / \ _/
      --        \./
      --
      -- We track all of the edges for each path so that we can determine the
      -- subset of edges on the graph that form the upper bound for the edges
      -- that are reached during a particular execution trace. We say "upper
      -- bound" here because some traces will not execute entirely to the end
      -- of the program due to the use of e.g. @enforce@ and @enforce-keyset@.
      --
      -- There's one more scenario where we start subpaths: for each of the
      -- "cases" of an @enforce-one@. Here's an example with three cases:
      --
      --     (enforce-one [case-1 case-2 case-3])
      --
      --     \____        <- case-1 runs, always
      --      \___ ._     <- case-2 runs if case-1 fails
      --       \__        <- case-3 runs if case-2 fails
      --
      -- The \ edges correspond to the execution of each case. The _ edges
      -- correspond to successful exit early due to the lack of a failure.
      -- These three "success" edges all join together at the same vertex.
    , _tsFoundVars :: [(VarId, Text, EType)]
    }

makeLenses ''TranslateFailure
makeLenses ''TranslateEnv
makeLenses ''TranslateState

instance HasVarId TranslateState where
  varId = tsNextVarId

class HasInfo e where
  envInfo :: Lens' e Info

instance HasInfo Info where
  envInfo = id

instance HasInfo TranslateEnv where
  envInfo = teInfo

newtype TranslateM a
  = TranslateM
    { unTranslateM :: ReaderT TranslateEnv
                        (StateT TranslateState
                          (Except TranslateFailure))
                        a
    }
  deriving (Functor, Applicative, Monad, MonadReader TranslateEnv,
    MonadState TranslateState, MonadError TranslateFailure)

instance MonadFail TranslateM where
  fail s = do
    info <- view envInfo
    throwError (TranslateFailure info (MonadFailure s))

-- * Translation

emit :: TraceEvent -> TranslateM ()
emit event = modify' $ tsPendingEvents %~ flip snoc event

-- | Call when entering a node to set the current context
withNodeContext :: Node -> TranslateM a -> TranslateM a
withNodeContext node = local (envInfo .~ nodeToInfo node)

-- | Call when entering an ast node to set the current context
withAstContext :: AST Node -> TranslateM a -> TranslateM a
withAstContext ast = local (envInfo .~ astToInfo ast)

withNestedRecoverability :: Recoverability -> TranslateM a -> TranslateM a
withNestedRecoverability r = local $ teRecoverability <>~ r

withNewScope
  :: ScopeType
  -> [Located Binding]
  -> TagId
  -> TranslateM ETerm
  -> TranslateM ETerm
withNewScope scopeType bindings retTid act = local (teScopesEntered +~ 1) $ do
  depth <- view teScopesEntered
  emit $ TracePushScope depth scopeType bindings
  res <- act
  let ty = existentialType res
  emit $ TracePopScope depth scopeType retTid ty
  pure res

genTagId :: TranslateM TagId
genTagId = TranslateM $ zoom tsNextTagId $ join $ view teGenTagId

nodeInfo :: Node -> Info
nodeInfo node = node ^. aId . Pact.tiInfo

startSubpath :: Path -> TranslateM ()
startSubpath p = do
  tsCurrentPath .= p
  emit $ TraceSubpathStart p

startNewSubpath :: TranslateM Path
startNewSubpath = do
  p <- Path <$> genTagId
  startSubpath p
  pure p

tagDbAccess
  :: (ESchema -> Located TagId -> TraceEvent)
  -> Node
  -> ESchema
  -> TranslateM TagId
tagDbAccess mkEvent node schema = do
  tid <- genTagId
  emit $ mkEvent schema (Located (nodeInfo node) tid)
  pure tid

tagRead :: Node -> ESchema -> TranslateM TagId
tagRead = tagDbAccess TraceRead

tagWrite :: WriteType -> Node -> ESchema -> TranslateM TagId
tagWrite = tagDbAccess . TraceWrite

tagAssert :: Node -> TranslateM TagId
tagAssert node = do
  tid <- genTagId
  recov <- view teRecoverability
  emit $ TraceAssert recov $ Located (nodeInfo node) tid
  pure tid

tagAuth :: Node -> TranslateM TagId
tagAuth node = do
  tid <- genTagId
  recov <- view teRecoverability
  emit $ TraceAuth recov $ Located (nodeInfo node) tid
  pure tid

withNodeVars :: Map Node (Munged, VarId) -> TranslateM a -> TranslateM a
withNodeVars nodeVars = local (teNodeVars %~ unionPreferring nodeVars)

-- Map.union is left-biased. The more explicit name makes this extra clear.
unionPreferring :: Ord k => Map k v -> Map k v -> Map k v
unionPreferring = Map.union

maybeTranslateUserType :: Pact.UserType -> Maybe QType
maybeTranslateUserType (Pact.Schema _ _ [] _) = Just $ EType $ SObject SNil'
maybeTranslateUserType (Pact.Schema a b (Pact.Arg name ty _:tys) c)
  = case maybeTranslateUserType (Pact.Schema a b tys c) of
    Just (EType (SObject tys')) -> case maybeTranslateType ty of
      Nothing -> Nothing
      Just (EType ty') -> withSing ty' $ withTypeable ty' $
        case someSymbolVal (T.unpack name) of
          SomeSymbol (_ :: Proxy sym) ->
            Just $ EType $ SObject $ SCons' (SSymbol @sym) ty' tys'
    _ -> Nothing

maybeTranslateUserType' :: Pact.UserType -> Maybe EType
maybeTranslateUserType' = maybeTranslateUserType >=> downcastQType

maybeTranslateType :: Pact.Type Pact.UserType -> Maybe EType
maybeTranslateType
  = maybeTranslateType' maybeTranslateUserType >=> downcastQType

-- A helper to translate types that doesn't know how to handle user types
-- itself
maybeTranslateType'
  :: (Monad f, Alternative f, Show a, Show (f QType))
  => (a -> f QType)
  -> Pact.Type a
  -> f QType
maybeTranslateType' f = \case
  TyUser a         -> f a

  -- TODO(joel): understand the difference between the TyUser and TySchema cases
  TySchema Pact.TyTable _ -> pure QTable
  TySchema _ ty'   -> maybeTranslateType' f ty'

  TyPrim Pact.TyBool    -> pure $ EType SBool
  TyPrim Pact.TyDecimal -> pure $ EType SDecimal
  TyPrim Pact.TyInteger -> pure $ EType SInteger
  TyPrim Pact.TyString  -> pure $ EType SStr
  TyPrim Pact.TyTime    -> pure $ EType STime
  TyPrim Pact.TyKeySet  -> pure $ EType SKeySet

  -- Pretend any and an unknown var are the same -- we can't analyze either of
  -- them.
  -- TODO(joel): revisit this assumption
  TyVar (Pact.SchemaVar (Pact.TypeVarName "table")) -> pure QTable
  TyVar _                                           -> pure $ EType SAny
  Pact.TyAny                                        -> pure $ EType SAny

  --
  -- TODO: handle these:
  --
  TyPrim TyValue   -> empty
  Pact.TyList a    -> do
    ty <- maybeTranslateType' f a
    case ty of
      EType ty' -> pure $ EType $ SList ty'
      _         -> empty
  TyFun _          -> empty

throwError'
  :: (MonadError TranslateFailure m, MonadReader r m, HasInfo r)
  => TranslateFailureNoLoc -> m a
throwError' err = do
  info <- view envInfo
  throwError $ TranslateFailure info err

-- | Generates a new 'Vertex', setting it as the head. Does *not* add this new
-- 'Vertex' to the graph.
issueVertex :: TranslateM Vertex
issueVertex = do
  v <- TranslateM $ zoom tsNextVertex $ join $ view teGenVertex
  tsPathHead .= v
  pure v

-- | Flushes-out events accumulated for the current edge of the execution path.
flushEvents :: TranslateM [TraceEvent]
flushEvents = do
  ConsList pathEvents <- use tsPendingEvents
  tsPendingEvents .= mempty
  pure pathEvents

addPathEdge :: Path -> Edge -> TranslateM ()
addPathEdge path e =
  tsPathEdges.at path %= pure . cons e . fromMaybe []

-- | Extends the previous path head to a new 'Vertex', flushing accumulated
-- events to 'tsEdgeEvents'.
extendPath :: TranslateM Vertex
extendPath = do
  path <- use tsCurrentPath
  v    <- use tsPathHead
  v'   <- issueVertex
  tsGraph %= Alga.overlay (Alga.edge v v')
  edgeTrace <- flushEvents
  let e = (v, v')
  tsEdgeEvents.at e ?= edgeTrace
  addPathEdge path e
  pure v'

-- | Extends multiple separate paths to a single join point. Assumes that each
-- 'Vertex' was created via 'extendPath' before invocation, and thus
-- 'tsPendingEvents' is currently empty.
joinPaths :: [(Vertex, Path)] -> TranslateM ()
joinPaths branches = do
  let vs = map fst branches
  v' <- issueVertex
  tsGraph %= Alga.overlay (Alga.vertices vs `Alga.connect` pure v')
  for_ branches $ \(v, path) -> do
    isNewPath <- use $ tsPathEdges.at path.to isNothing
    let rejoinEdge = (v, v')
    tsEdgeEvents.at rejoinEdge ?= [TraceSubpathStart path | isNewPath]
    addPathEdge path rejoinEdge

translateType
  :: (MonadError TranslateFailure m, MonadReader r m, HasInfo r)
  => Node -> m EType
translateType node = case _aTy node of
  (maybeTranslateType -> Just ety) -> pure ety
  ty                               -> throwError' $ UnhandledType node ty

translateArg
  :: ( MonadState s m
     , HasVarId s
     , MonadReader r m
     , HasInfo r
     , MonadError TranslateFailure m
     )
  => Named Node
  -> m Arg
translateArg (Named nm node _) = do
  vid <- genVarId
  ety <- translateType node
  pure (Arg (Unmunged nm) vid node ety)

translateBinding :: Named Node -> TranslateM (Located Binding)
translateBinding (Named unmunged' node _) = do
  vid <- genVarId
  let munged = node ^. aId.tiName.to Munged
      info = node ^. aId . Pact.tiInfo
  varType <- translateType node
  pure $ Located info $ Binding vid (Unmunged unmunged') munged varType

translateBody :: [AST Node] -> TranslateM ETerm
translateBody = \case
  []       -> do
    info <- view envInfo
    throwError $ TranslateFailure info EmptyBody
  [ast]    -> translateNode ast
  ast:asts -> do
    ast'                 <- translateNode ast
    Some ty asts' <- translateBody asts
    pure $ Some ty $ Sequence ast' asts'

translateLet :: ScopeType -> [(Named Node, AST Node)] -> [AST Node] -> TranslateM ETerm
translateLet scopeTy (unzip -> (bindingAs, rhsAs)) body = do
  bindingTs <- traverse translateBinding bindingAs
  rhsETs <- traverse translateNode rhsAs

  retTid <- genTagId

  let -- Wrap the 'Term' body of clauses in a 'Let' for each of the bindings
      wrapWithLets :: Term a -> Term a
      wrapWithLets tm = foldr
        (\(rhsET, Located _ (Binding vid _ (Munged munged) _)) body' ->
          Let munged vid retTid rhsET body')
        tm
        (zip rhsETs bindingTs)

      nodeVars :: Map Node (Munged, VarId)
      nodeVars = Map.fromList
        [ (node, (munged, vid))
        | ((Named _ node _), _located -> Binding vid _ munged _)
            <- zip bindingAs bindingTs
        ]

  fmap (mapExistential wrapWithLets) $
    withNewScope scopeTy bindingTs retTid $
      withNodeVars nodeVars $
        translateBody body

translateObjBinding
  :: [(Named Node, AST Node)]
  -> SingTy ('TyObject m)
  -> [AST Node]
  -> ETerm
  -> TranslateM ETerm
translateObjBinding pairs schema bodyA rhsT = do
  let bindingAs = fst $ unzip pairs
  bindingTs <- traverse translateBinding bindingAs
  cols <- for pairs $ \case
    (_, AST_StringLit colName) ->
      pure $ T.unpack colName
    (Named _ node _, x) ->
      withNodeContext node $ throwError' $ NonStringLitInBinding x

  retTid <- genTagId

  -- We create one synthetic binding for the object, which then only the column
  -- bindings use.
  objBindingId <- genVarId
  let objVar = CoreTerm $ Var objBindingId "binding"

  --
  -- TODO: we might want to only create a single Let here, with a binding for
  --       each column. at the moment we create a new Let for each binding. a
  --       single let would be slightly more elegant for generating assertions
  --       for tags during evaluation as well. with this current elaboration,
  --       we would generate @n@ extra/unnecessary assertions for @n@ columns
  --       (because we currently generate @n+1@ lets -- one synthetic binding
  --       for the object, and one for each column.
  --

  let wrapWithLets :: Term a -> Term a
      wrapWithLets innerBody = Let "binding" objBindingId retTid rhsT $
        -- NOTE: *left* fold for proper shadowing/overlapping name semantics:
        foldl'
          (\body ( colName
                 , Located _ (Binding vid _ (Munged varName) (EType ty))
                 ) ->
            let colTerm = StrLit @Term colName
                rhs = Some ty $ CoreTerm $ ObjAt schema colTerm objVar
            in Let varName vid retTid rhs body)
          innerBody
          (zip cols bindingTs)

      nodeVars :: Map Node (Munged, VarId)
      nodeVars = Map.fromList
        [ (node, (munged, vid))
        | ((Named _ node _), _located -> Binding vid _ munged _)
            <- zip bindingAs bindingTs
        ]

  fmap (mapExistential wrapWithLets) $
    withNewScope ObjectScope bindingTs retTid $
      withNodeVars nodeVars $
        translateBody bodyA

-- Note: there is a very similar @mkLiteralObject@ in @Analyze.Parse.Prop@.
-- These could probably be combined.
mkLiteralObject :: [(Text, ETerm)] -> TranslateM (Existential (Core Term))
mkLiteralObject [] = pure $
  let ty = SObject SNil'
  in Some ty (LiteralObject ty (Object SNil))
mkLiteralObject ((name, Some ty tm) : tms) = do
  Some (SObject objTy) (LiteralObject _ (Object obj)) <- mkLiteralObject tms
  case someSymbolVal (T.unpack name) of
    SomeSymbol (_proxy :: Proxy k) -> withTypeable ty $ withSing ty $ pure $
      let sym = SSymbol @k
          objTy' = SObject (SCons' sym ty objTy)
      in Some objTy' $
           LiteralObject objTy' $
             Object $ SCons sym (Column ty tm) obj

pattern EmptyList :: SingTy a -> Term ('TyList a)
pattern EmptyList ty = CoreTerm (LiteralList ty [])

translateNode :: AST Node -> TranslateM ETerm
translateNode astNode = withAstContext astNode $ case astNode of
  AST_Let bindings body ->
    translateLet LetScope bindings body

  AST_InlinedApp nm bindings body ->
    translateLet (FunctionScope nm) bindings body

  AST_Var node -> do
    mVar     <- view $ teNodeVars.at node
    EType ty <- translateType node
    (Munged varName, vid) <- case mVar of
      Just x  -> pure x
      Nothing -> do
        vid <- genVarId
        tsFoundVars %= cons (vid, "x", EType ty)
        pure (Munged "x", vid) -- TODO better name?
    pure $ Some ty $ CoreTerm $ Var vid varName

  -- Int
  AST_NegativeLit l -> case l of
    LInteger i -> pure $ Some SInteger $ inject @(Numerical Term) $
      IntUnaryArithOp Negate $ Lit' i
    LDecimal d -> pure $ Some SDecimal $ inject @(Numerical Term) $
      DecUnaryArithOp Negate $ Lit' $ fromPact decimalIso d
    _          -> throwError' $ BadNegationType astNode

  AST_Lit l -> case l of
    LInteger i -> pure $ Some SInteger $ Lit' i
    LBool b    -> pure $ Some SBool    $ Lit' b
    LString s  -> pure $ Some SStr     $ Lit' $ Str $ T.unpack s
    LDecimal d -> pure $ Some SDecimal $ Lit' $ fromPact decimalIso d
    LTime t    -> pure $ Some STime    $ Lit' $ fromPact timeIso t

  AST_NegativeVar node -> do
    Just (Munged name, vid) <- view $ teNodeVars.at node
    EType ty <- translateType node
    case ty of
      SInteger     -> pure $ Some SInteger $ inject $ IntUnaryArithOp Negate $
        CoreTerm $ Var vid name
      SDecimal -> pure $ Some SDecimal $ inject $ DecUnaryArithOp Negate $
        CoreTerm $ Var vid name
      _        -> throwError' $ BadNegationType astNode

  AST_Format formatStr vars -> do
    Some SStr formatStr' <- translateNode formatStr
    vars' <- for vars translateNode
    pure $ Some SStr $ Format formatStr' vars'

  AST_FormatTime formatStr time -> do
    Some SStr formatStr' <- translateNode formatStr
    Some STime time'     <- translateNode time
    pure $ Some SStr $ FormatTime formatStr' time'

  AST_ParseTime formatStr timeStr -> do
    Some SStr formatStr' <- translateNode formatStr
    Some SStr timeStr'   <- translateNode timeStr
    pure $ Some STime $ ParseTime (Just formatStr') timeStr'

  AST_Time timeStr -> do
    Some SStr timeStr' <- translateNode timeStr
    pure $ Some STime $ ParseTime Nothing timeStr'

  AST_Hash val -> do
    val' <- translateNode val
    pure $ Some SStr $ Hash val'

  AST_ReadKeyset nameA -> do
    Some SStr nameT <- translateNode nameA
    return $ Some SKeySet $ ReadKeySet nameT

  AST_ReadDecimal nameA -> do
    Some SStr nameT <- translateNode nameA
    return $ Some SDecimal $ ReadDecimal nameT

  AST_ReadInteger nameA -> do
    Some SStr nameT <- translateNode nameA
    return $ Some SInteger $ ReadInteger nameT

  AST_ReadMsg _ -> throwError' $ NoReadMsg astNode

  AST_Enforce _ cond -> do
    Some SBool condTerm <- translateNode cond
    tid <- tagAssert $ cond ^. aNode
    pure $ Some SBool $ Enforce (Just tid) condTerm

  AST_EnforceKeyset ksA
    | ksA ^? aNode.aTy == Just (TyPrim Pact.TyString)
    -> do
      Some SStr ksnT <- translateNode ksA
      tid <- tagAuth $ ksA ^. aNode
      return $ Some SBool $ Enforce Nothing $ NameAuthorized tid ksnT

  AST_EnforceKeyset ksA
    | ksA ^? aNode.aTy == Just (TyPrim Pact.TyKeySet)
    -> do
      Some SKeySet ksT <- translateNode ksA
      tid <- tagAuth $ ksA ^. aNode
      return $ Some SBool $ Enforce Nothing $ KsAuthorized tid ksT

  AST_EnforceOne node [] -> do
    -- we just emit an event equivalent to one for `(enforce false)` in this
    -- case:
    tid <- tagAssert node
    return $ Some SBool $ EnforceOne $ Left tid

  AST_EnforceOne _ casesA@(_:_) -> do
    let n = length casesA -- invariant: n > 0
        genPath = Path <$> genTagId
    preEnforcePath <- use tsCurrentPath
    -- Generate failure and success paths for each case. We generate and tag
    -- the final failure path, but don't include it in the graph.
    pathPairs <- replicateM n ((,) <$> genPath <*> genPath)

    let (failurePaths, successPaths) = unzip pathPairs
        -- we don't start a new path for the first case -- we *always* run it:
        newPaths :: [Maybe Path]
        newPaths = Nothing : fmap Just (take (pred n) failurePaths)

        recovs :: [Recoverability]
        recovs = (Recoverable <$> take (pred n) failurePaths)
              ++ [Unrecoverable]

    (terms, vertices) <- fmap unzip $
      for (zip3 casesA newPaths recovs) $ \(caseA, mNewPath, recov) -> do
        maybe (pure ()) startSubpath mNewPath
        Some SBool caseT <- withNestedRecoverability recov $
          translateNode caseA
        postVertex <- extendPath
        pure (caseT, postVertex)

    joinPaths $ zip vertices successPaths
    tsCurrentPath .= preEnforcePath
    return $ Some SBool $ EnforceOne $ Right $ zip pathPairs terms

  AST_Days days -> do
    Some daysTy days' <- translateNode days
    case daysTy of
      SInteger -> pure $ Some SInteger $ inject $ IntArithOp Mul (60 * 60 * 24) days'
      SDecimal -> pure $ Some SDecimal $ inject $ DecArithOp Mul (60 * 60 * 24) days'
      _        -> throwError' $ BadTimeType astNode

  AST_Hours hours -> do
    Some hoursTy hours' <- translateNode hours
    case hoursTy of
      SInteger -> pure $ Some SInteger $ inject $ IntArithOp Mul (60 * 60) hours'
      SDecimal -> pure $ Some SDecimal $ inject $ DecArithOp Mul (60 * 60) hours'
      _        -> throwError' $ BadTimeType astNode

  AST_Minutes minutes -> do
    Some minutesTy minutes' <- translateNode minutes
    case minutesTy of
      SInteger -> pure $ Some SInteger $ inject $ IntArithOp Mul 60 minutes'
      SDecimal -> pure $ Some SDecimal $ inject $ DecArithOp Mul 60 minutes'
      _        -> throwError' $ BadTimeType astNode

  AST_NFun _node "time" [AST_Lit (LString timeLit)]
    | Just timeLit'
      <- parseTime defaultTimeLocale Pact.simpleISO8601 (T.unpack timeLit)
    -> pure $ Some STime $ Lit' $ fromPact timeIso timeLit'

  AST_NFun_Basic SModulus [a, b] ->  do
    Some SInteger a' <- translateNode a
    Some SInteger b' <- translateNode b
    pure (Some SInteger (inject $ ModOp a' b'))

  AST_NFun_Basic fn@(toOp comparisonOpP -> Just op) args@[a, b] -> do
    aT <- translateNode a
    bT <- translateNode b
    case (aT, bT) of

      (Some (SList SAny) (EmptyList SAny), Some (SList ty) lst) -> do
        op' <- toOp eqNeqP fn ?? MalformedComparison fn args
        pure $ Some SBool $ CoreTerm $ ListEqNeq ty op' (EmptyList ty) lst

      (Some (SList ty) lst, Some (SList SAny) (EmptyList SAny)) -> do
        op' <- toOp eqNeqP fn ?? MalformedComparison fn args
        pure $ Some SBool $ CoreTerm $ ListEqNeq ty op' lst (EmptyList ty)

      (Some (SList ta) a', Some (SList tb) b') -> do
        Refl <- singEq ta tb ?? TypeMismatch (EType ta) (EType tb)
        op'  <- toOp eqNeqP fn ?? MalformedComparison fn args
        pure $ Some SBool $ inject $ ListEqNeq ta op' a' b'

      (Some ta@SObject{} a', Some tb@SObject{} b') -> do
        op'  <- toOp eqNeqP fn ?? MalformedComparison fn args
        pure $ Some SBool $ inject $ ObjectEqNeq ta tb op' a' b'

      (Some ta a', Some tb b') -> do
        Refl <- singEq ta tb ?? TypeMismatch (EType ta) (EType tb)
        pure $ Some SBool $ inject $ Comparison ta op a' b'

  AST_NFun_Basic fn@(toOp comparisonOpP -> Just _) args
    -> throwError' $ MalformedComparison fn args

  -- logical: not, and, or

  AST_NFun_Basic SLogicalNegation [a] -> do
    Some SBool a' <- translateNode a
    pure $ Some SBool $ inject $ Logical NotOp [a']

  AST_NFun_Basic fn args@[a, b]
    | fn == SLogicalConjunction || fn == SLogicalDisjunction -> do
      Some tyA a' <- translateNode a
      Some tyB b' <- translateNode b
      case (tyA, tyB) of
        (SBool, SBool) -> case fn of
          SLogicalConjunction -> pure $
            Some SBool $ inject $ Logical AndOp [a', b']
          SLogicalDisjunction -> pure $
            Some SBool $ inject $ Logical OrOp [a', b']
          _     -> error "impossible"
        _ -> throwError' $ MalformedLogicalOp fn args

  AST_NFun_Basic fn@(toOp logicalOpP -> Just _) args
    -> throwError' $ MalformedLogicalOp fn args

  -- arithmetic

  AST_NFun_Basic fn@(toOp roundingLikeOpP -> Just op) args@[a, b] -> do
      Some tyA a' <- translateNode a
      Some tyB b' <- translateNode b
      case (tyA, tyB, op) of
        (SDecimal, SInteger, Round)   -> pure $
          Some SDecimal $ inject $ RoundingLikeOp2 op a' b'
        (SDecimal, SInteger, Ceiling) -> pure $
          Some SDecimal $ inject $ RoundingLikeOp2 op a' b'
        (SDecimal, SInteger, Floor)   -> pure $
          Some SDecimal $ inject $ RoundingLikeOp2 op a' b'
        _ -> throwError' $ MalformedArithOp fn args

  AST_NFun_Basic fn@(toOp roundingLikeOpP -> Just op) args@[a] -> do
      Some ty a' <- translateNode a
      case ty of
        SDecimal -> pure $ Some SInteger $ inject $ RoundingLikeOp1 op a'
        _        -> throwError' $ MalformedArithOp fn args

  AST_NFun_Basic fn@(toOp unaryArithOpP -> Just op) args@[a] -> do
      Some ty a' <- translateNode a
      case ty of
        SInteger -> pure $ Some SInteger $ inject $ IntUnaryArithOp op a'
        SDecimal -> pure $ Some SDecimal $ inject $ DecUnaryArithOp op a'
        _        -> throwError' $ MalformedArithOp fn args

  --
  -- NOTE: We don't use a feature symbol here because + is overloaded across
  -- multiple (3) features.
  --
  AST_NFun node fn@"+" args@[a, b] -> do
    EType retTy <- translateType node
    aT          <- translateNode a
    bT          <- translateNode b
    case (aT, bT) of
      (Some ty1@SObject{} o1, Some ty2@SObject{} o2) -> do
        -- Feature 3: object merge
        pure $ Some retTy $ inject $ ObjMerge ty1 ty2 o1 o2
      (Some (SList tyA) a', Some (SList tyB) b') -> do
        Refl <- singEq tyA tyB ?? MalformedArithOp fn args
        -- Feature 4: list concatenation
        pure $ Some (SList tyA) $ inject $ ListConcat tyA a' b'
      (Some tyA a', Some tyB b') ->
        case (tyA, tyB) of
          -- Feature 1: string concatenation
          (SStr, SStr)         -> pure $ Some SStr $ inject $ StrConcat a' b'
          -- Feature 2: arithmetic addition
          (SInteger, SInteger) -> pure $ Some SInteger $ inject $ IntArithOp Add a' b'
          (SDecimal, SDecimal) -> pure $ Some SDecimal $ inject $ DecArithOp Add a' b'
          (SInteger, SDecimal) -> pure $ Some SDecimal $ inject $ IntDecArithOp Add a' b'
          (SDecimal, SInteger) -> pure $ Some SDecimal $ inject $ DecIntArithOp Add a' b'
          _ -> throwError' $ MalformedArithOp fn args

  AST_NFun_Basic fn@(toOp arithOpP -> Just op) args@[a, b] -> do
      Some tyA a' <- translateNode a
      Some tyB b' <- translateNode b
      case (tyA, tyB) of
        (SInteger, SInteger)         -> pure $
          Some SInteger $ inject $ IntArithOp op a' b'
        (SDecimal, SDecimal) -> pure $
          Some SDecimal $ inject $ DecArithOp op a' b'
        (SInteger, SDecimal)     -> pure $
          Some SDecimal $ inject $ IntDecArithOp op a' b'
        (SDecimal, SInteger)     -> pure $
          Some SDecimal $ inject $ DecIntArithOp op a' b'
        _ -> throwError' $ MalformedArithOp fn args

  AST_NFun_Basic fn@(toOp arithOpP -> Just _) args
    -> throwError' $ MalformedArithOp fn args

  AST_NFun _node "length" [a] -> do
    Some SStr a' <- translateNode a
    pure $ Some SInteger $ CoreTerm $ StrLength a'

  AST_NFun node (toOp writeTypeP -> Just writeType) [ShortTableName tn, row, obj] -> do
    Some SStr row'            <- translateNode row
    Some objTy@SObject{} obj' <- translateNode obj
    tid                              <- tagWrite writeType node $ ESchema objTy
    pure $ Some SStr $
      Write objTy writeType tid (TableName (T.unpack tn)) row' obj'

  AST_If _ cond tBranch fBranch -> do
    Some SBool cond' <- translateNode cond
    preTestPath      <- use tsCurrentPath
    postTest         <- extendPath
    truePath         <- startNewSubpath
    Some ta a        <- translateNode tBranch
    postTrue         <- extendPath
    tsPathHead .= postTest -- reset to before true branch
    falsePath <- startNewSubpath
    Some tb b <- translateNode fBranch
    postFalse <- extendPath
    joinPaths [(postTrue, truePath), (postFalse, falsePath)]
    tsCurrentPath .= preTestPath -- reset to before conditional
    Refl <- singEq ta tb ?? BranchesDifferentTypes (EType ta) (EType tb)
    pure $ Some ta $ IfThenElse ta cond' (truePath, a) (falsePath, b)

  AST_NFun _node "str-to-int" [s] -> do
    Some SStr s' <- translateNode s
    pure $ Some SInteger $ CoreTerm $ StrToInt s'

  AST_NFun _node "str-to-int" [b, s] -> do
    Some SInteger b' <- translateNode b
    Some SStr s'     <- translateNode s
    pure $ Some SInteger $ CoreTerm $ StrToIntBase b' s'

  AST_NFun _node "pact-version" [] -> pure $ Some SStr PactVersion

  AST_WithRead node table key bindings schemaNode body -> do
    EType objTy@SObject{} <- translateType schemaNode
    Some SStr key' <- translateNode key
    tid                   <- tagRead node $ ESchema objTy
    let readT = Some objTy $
          Read objTy tid (TableName (T.unpack table)) key'
    withNodeContext node $
      translateObjBinding bindings objTy body readT

  AST_Bind node objectA bindings schemaNode body -> do
    EType objTy@SObject{} <- translateType schemaNode
    objectT               <- translateNode objectA
    withNodeContext node $
      translateObjBinding bindings objTy body objectT

  AST_AddTime time seconds
    | seconds ^. aNode . aTy == TyPrim Pact.TyInteger ||
      seconds ^. aNode . aTy == TyPrim Pact.TyDecimal -> do
      Some STime time' <- translateNode time
      Some ty seconds' <- translateNode seconds

      case ty of
        SInteger ->
          pure $ Some STime $ CoreTerm $ IntAddTime time' seconds'
        SDecimal ->
          pure $ Some STime $ CoreTerm $ DecAddTime time' seconds'
        _ -> throwError' $ MonadFailure $
          "Unexpected type for seconds in add-time " ++ show ty

  AST_Read node table key -> do
    Some SStr key'        <- translateNode key
    EType objTy@SObject{} <- translateType node
    tid                   <- tagRead node $ ESchema objTy
    pure $ Some objTy $ Read objTy tid (TableName (T.unpack table)) key'

--   error "TODO"
--   -- Note: this won't match if the columns are not a list literal
--   AST_ReadCols node table key columns -> do
--     Some SStr key' <- translateNode key
--     (Schema fields) <- translateType node
--     columns' <- fmap Set.fromList $ for columns $ \case
--       AST_Lit (LString col) -> pure col
--       bad                   -> throwError' (NonStaticColumns bad)
--     let schema = Schema $
--           Map.filterWithKey (\k _ -> k `Set.member` columns') fields

--     tid <- tagRead node schema
--     pure $ Some (SObject schema) $
--       Read tid (TableName (T.unpack table)) schema key'

  AST_At node index obj -> do
    obj'     <- translateNode obj
    EType ty <- translateType node
    case obj' of
      Some (SObject schema) obj'' -> do
        Some SStr colName <- translateNode index
        pure $ Some ty $ CoreTerm $ ObjAt (SObject schema) colName obj''
      Some (SList listOfTy) list -> do
        Some SInteger index' <- translateNode index
        pure $ Some listOfTy $ CoreTerm $ ListAt listOfTy index' list
      _ -> throwError' $ TypeError node

  AST_Obj _node kvs -> do
    kvs' <- for kvs $ \(k, v) -> do
      k' <- case k of
        AST_Lit (LString t) -> pure t
        -- TODO: support non-const keys
        _                   -> throwError' $ NonConstKey k
      v' <- translateNode v
      pure (k', v')
    Some objTy litObj <- mkLiteralObject kvs'
    pure $ Some objTy $ CoreTerm litObj

  AST_NFun node "list" _ -> throwError' $ DeprecatedList node

  AST_List node elems -> do
    elems' <- traverse translateNode elems
    Some ty litList <- mkLiteralList elems' ?? TypeError node
    pure $ Some ty $ CoreTerm litList

  AST_Contains node val collection -> do
    Some needleTy needle <- translateNode val
    collection'             <- translateNode collection
    case collection' of
      Some SStr haystack -> case needleTy of
        SStr -> pure $ Some SBool $ CoreTerm $ StrContains needle haystack
        _    -> throwError' $ TypeError node
      Some (SList ty) haystack -> do
        Refl <- singEq needleTy ty ?? TypeError node
        pure $ Some SBool $ CoreTerm $ ListContains ty needle haystack
      Some (SObject schema) obj -> case needleTy of
        SStr -> pure $ Some SBool $ CoreTerm $ ObjContains (SObject schema) needle obj
        _    -> throwError' $ TypeError node
      Some _ _ -> throwError' $ TypeError node

  AST_Reverse _node list -> do
    Some ty'@(SList elemTy) list' <- translateNode list
    pure $ Some ty' $ CoreTerm $ ListReverse elemTy list'

  AST_Sort _node list -> do
    Some ty'@(SList elemTy) list' <- translateNode list
    pure $ Some ty' $ CoreTerm $ ListSort elemTy list'

  AST_Drop node numOrKeys list -> do
    elist <- translateNode list
    case elist of
      Some ty'@(SList elemTy) list' -> do
        Some SInteger num <- translateNode numOrKeys
        pure $ Some ty' $ CoreTerm $ ListDrop elemTy num list'
      Some ty'@SObject{} obj -> do
        Some (SList SStr) keys <- translateNode numOrKeys
        pure $ Some ty' $ CoreTerm $ ObjDrop keys obj
      _ -> throwError' $ TypeError node

  AST_Take node numOrKeys list -> do
    elist <- translateNode list
    case elist of
      Some ty'@(SList elemTy) list' -> do
        Some SInteger num <- translateNode numOrKeys
        pure $ Some ty' $ CoreTerm $ ListTake elemTy num list'
      Some ty'@SObject{} obj -> do
        Some (SList SStr) keys <- translateNode numOrKeys
        pure $ Some ty' $ CoreTerm $ ObjTake keys obj
      _ -> throwError' $ TypeError node

  AST_MakeList _node num a -> do
    Some SInteger num' <- translateNode num
    Some ty       a'   <- translateNode a
    pure $ Some (SList ty) $ CoreTerm $ MakeList ty num' a'

  AST_NFun _node SIdentity [a] -> do
    Some tya a' <- translateNode a
    pure $ Some tya $ CoreTerm $ Identity tya a'

  AST_NFun _node SConstantly [ a, b ] -> do
    Some tya a' <- translateNode a
    Some tyb b' <- translateNode b
    pure $ Some tya $ CoreTerm $ Constantly tyb a' b'

  AST_NFun _node SCompose [ f, g, a ] -> do
    Some tya a' <- translateNode a
    avarLst     <- use tsFoundVars
    tsFoundVars .= []

    Some tyb f'  <- translateNode f
    (avid, _, _) <- captureOneFreeVar

    Some tyc g'  <- translateNode g
    (bvid, _, _) <- captureOneFreeVar

    -- important: we captured a, so we need to leave it free (by restoring
    -- tsFoundVars)
    tsFoundVars .= avarLst

    pure $ Some tyc $ CoreTerm $
      Compose tya tyb tyc a' (Open avid "a" f') (Open bvid "b" g')

  AST_NFun node SMap [ fun, l ] -> do
    expectNoFreeVars
    Some bTy fun' <- translateNode fun
    (vid, varName, EType aType) <- captureOneFreeVar

    Some (SList listTy) l' <- translateNode l

    Refl <- singEq listTy aType ?? TypeError node
    pure $ Some (SList bTy) $ CoreTerm $
      ListMap aType bTy (Open vid varName fun') l'

  AST_NFun node SFilter [ fun, l ] -> do
    expectNoFreeVars
    Some SBool fun' <- translateNode fun
    (vid, varName, EType aType) <- captureOneFreeVar

    Some (SList listTy) l' <- translateNode l

    Refl <- singEq listTy aType ?? TypeError node
    pure $ Some (SList aType) $ CoreTerm $
      ListFilter aType (Open vid varName fun') l'

  AST_NFun node SFold [ fun, a, l ] -> do
    expectNoFreeVars
    Some funTy fun' <- translateNode fun

    -- Note: The order of these variables is important. `a` should be the first
    -- variable we encounter when traversing `fun` (and `b` the second) because
    -- `a` is the first argument and `b` is the second.
    --
    -- TODO(joel): this doesn't seem to follow
    --
    -- `a` encountered first, `b` will be consed on top of it, resulting in the
    -- variables coming out backwards.
    [ (vidb, varNameb, EType tyb), (vida, varNamea, EType tya) ]
      <- captureTwoFreeVars

    Some aTy' a'           <- translateNode a
    Some (SList listTy) l' <- translateNode l

    Refl <- singEq aTy' tya   ?? TypeError node
    Refl <- singEq aTy' funTy ?? TypeError node
    Refl <- singEq listTy tyb ?? TypeError node
    pure $ Some tya $ CoreTerm $
      ListFold tya tyb (Open vida varNamea (Open vidb varNameb fun')) a' l'

  AST_NFun _ name [ f, g, a ]
    | name == SAndQ || name == SOrQ -> do
    expectNoFreeVars
    Some SBool f' <- translateNode f
    (fvid, fvarName, _) <- captureOneFreeVar

    Some SBool g' <- translateNode g
    (gvid, gvarName, _) <- captureOneFreeVar

    Some aTy' a' <- translateNode a

    pure $ Some SBool $ CoreTerm $ (if name == "and?" then AndQ else OrQ)
      aTy' (Open fvid fvarName f') (Open gvid gvarName g') a'

  -- AST_NFun _ SWhere [ field, fun, obj ] -> do
  --   Some SStr field' <- translateNode field

--     expectNoFreeVars
--     Some SBool fun' <- translateNode fun
--     (vid, varName, EType freeTy) <- captureOneFreeVar

--     Some (SObject objTy) obj' <- translateNode obj

--     pure $ Some SBool $ CoreTerm $
--       Where objTy freeTy field' (Open vid varName fun') obj'

  AST_NFun _ STypeof [tm] -> do
    Some ty tm' <- translateNode tm
    pure $ Some SStr $ CoreTerm $ Typeof ty tm'

  AST_Step                -> throwError' $ NoPacts astNode
  AST_NFun _ "pact-id" [] -> throwError' $ NoPacts astNode
  AST_NFun _ "keys"   [_] -> throwError' $ NoKeys astNode

  _ -> throwError' $ UnexpectedNode astNode

captureOneFreeVar :: TranslateM (VarId, Text, EType)
captureOneFreeVar = do
  vs <- use tsFoundVars
  tsFoundVars .= []
  case vs of
    [v] -> pure v
    _   -> throwError' $ FreeVarInvariantViolation $
      "unexpected vars found: " <> tShow vs

captureTwoFreeVars :: TranslateM [(VarId, Text, EType)]
captureTwoFreeVars = do
  vs <- use tsFoundVars
  tsFoundVars .= []
  case vs of
    [_, _] -> pure vs
    _      -> throwError' $ FreeVarInvariantViolation $
      "unexpected vars found: " <> tShow vs

expectNoFreeVars :: TranslateM ()
expectNoFreeVars = do
  vars <- use tsFoundVars
  case vars of
    [] -> pure ()
    _  -> throwError' $ FreeVarInvariantViolation
      "invariant violation: free variable unexpectedly found"

mkExecutionGraph :: Vertex -> Path -> TranslateState -> ExecutionGraph
mkExecutionGraph vertex0 rootPath st = ExecutionGraph
    vertex0
    rootPath
    (_tsGraph st)
    (_tsEdgeEvents st)
    (_tsPathEdges st)

runTranslation
  :: Text
  -> Info
  -> [Named Node]
  -> [AST Node]
  -> Except TranslateFailure ([Arg], ETerm, ExecutionGraph)
runTranslation name info pactArgs body = do
    (args, translationVid) <- runArgsTranslation
    (tm, graph) <- runBodyTranslation args translationVid
    pure (args, tm, graph)

  where
    runArgsTranslation :: Except TranslateFailure ([Arg], VarId)
    runArgsTranslation = runStateT
      (runReaderT (traverse translateArg pactArgs) info)
      (VarId 1)

    argToBinding :: Arg -> Located Binding
    argToBinding (Arg unmunged vid node ety) =
      Located (node ^. aId . Pact.tiInfo) $
        Binding vid unmunged (node ^. aId.tiName.to Munged) ety

    runBodyTranslation
      :: [Arg] -> VarId -> Except TranslateFailure (ETerm, ExecutionGraph)
    runBodyTranslation args nextVarId =
      let vertex0    = 0
          nextVertex = succ vertex0
          path0      = Path 0
          nextTagId  = succ $ _pathTag path0
          graph0     = pure vertex0
          state0     = TranslateState nextTagId nextVarId graph0 vertex0 nextVertex Map.empty mempty path0 Map.empty []
          translation = do
            retTid    <- genTagId
            -- For our toplevel 'FunctionScope', we reuse variables we've
            -- already generated during argument translation:
            let bindingTs = fmap argToBinding args
            res <- withNewScope (FunctionScope name) bindingTs retTid $
              translateBody body
            _ <- extendPath -- form final edge for any remaining events
            pure res
      in fmap (fmap $ mkExecutionGraph vertex0 path0) $ flip runStateT state0 $
           runReaderT (unTranslateM translation) (mkTranslateEnv info args)

-- | Translate a node ignoring the execution graph. This is useful in cases
-- where we don't show an execution trace. Those two places (currently) are:
-- * Translating `defconst`s for use in properties. This is for use only in
-- properties, as opposed to in execution.
-- * Translating terms for property testing. Here we don't show a trace -- we
-- just test that pact and analysis come to the same result.
translateNodeNoGraph :: AST Node -> Except TranslateFailure ETerm
translateNodeNoGraph node =
  let vertex0    = 0
      nextVertex = succ vertex0
      path0      = Path 0
      nextTagId  = succ $ _pathTag path0
      graph0     = pure vertex0
      translateState     = TranslateState nextTagId 0 graph0 vertex0 nextVertex
        Map.empty mempty path0 Map.empty []

      translateEnv = TranslateEnv dummyInfo Map.empty mempty 0 (pure 0) (pure 0)

  in (`evalStateT` translateState) $
       (`runReaderT` translateEnv) $
         unTranslateM $ translateNode node

-- | Throw a translation failure when Nothing
(??)
  :: (MonadError TranslateFailure m, MonadReader r m, HasInfo r)
  => Maybe a -> TranslateFailureNoLoc -> m a
(Just a) ?? _   = pure a
Nothing  ?? err = throwError' err
infix 0 ??
