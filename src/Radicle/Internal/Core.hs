{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns    #-}

-- | The core radicle datatypes and functionality.
module Radicle.Internal.Core where

import           Protolude hiding (Constructor, TypeError, list, (<>))

import           Codec.Serialise (Serialise)
import           Control.Monad.Except
                 (ExceptT(..), MonadError, runExceptT, throwError)
import           Control.Monad.State
import           Data.Aeson (FromJSON(..), ToJSON(..))
import qualified Data.Aeson as A
import           Data.Copointed (Copointed(..))
import           Data.Data (Data)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.IntMap as IntMap
import           Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map as Map
import           Data.Scientific (Scientific, floatingOrInteger)
import           Data.Semigroup ((<>))
import qualified Data.Sequence as Seq
import           Generics.Eot
import qualified GHC.Exts as GhcExts
import qualified Text.Megaparsec.Error as Par

import           Radicle.Internal.Annotation (Annotated)
import qualified Radicle.Internal.Annotation as Ann
import           Radicle.Internal.Orphans ()


-- * Value

data LangError r = LangError [Ann.SrcPos] (LangErrorData r)
    deriving (Eq, Show, Read, Generic, Functor)

-- | An error throw during parsing or evaluating expressions in the language.
data LangErrorData r =
      UnknownIdentifier Ident
    | Impossible Text
    | TypeError Text
    -- | Takes the function name, expected number of args, and actual number of
    -- args
    | WrongNumberOfArgs Text Int Int
    | OtherError Text
    | ParseError (Par.ParseError Char Void)
    | ThrownError Ident r
    | Exit
    deriving (Eq, Show, Read, Generic, Functor)

throwErrorHere :: (MonadError (LangError Value) m, HasCallStack) => LangErrorData Value -> m a
throwErrorHere = withFrozenCallStack (throwError . LangError [Ann.thisPos])

toLangError :: (HasCallStack) => LangErrorData Value -> LangError Value
toLangError = LangError [Ann.thisPos]

-- | Remove callstack information.
noStack :: Either (LangError Value) a -> Either (LangErrorData Value) a
noStack (Left (LangError _ err)) = Left err
noStack (Right v)                = Right v

-- | Convert an error to a radicle value, and the label for it. Used for
-- catching exceptions.
errorDataToValue
    :: Monad m
    => LangErrorData Value
    -> Lang m (Ident, Value)
errorDataToValue e = case e of
    UnknownIdentifier i -> makeVal
        ( "unknown-identifier"
        , [("identifier", makeA i)]
        )
    -- "Now more than ever seems it rich to die"
    Impossible _ -> throwErrorHere e
    TypeError i -> makeVal
        ( "type-error"
        , [("info", String i)]
        )
    WrongNumberOfArgs i expected actual -> makeVal
        ( "wrong-number-of-args"
        , [ ("function", makeA $ Ident i)
          , ("expected", Number $ fromIntegral expected)
          , ("actual", Number $ fromIntegral actual)]
        )
    OtherError i -> makeVal
        ( "other-error"
        , [("info", String i)]
        )
    ParseError _ -> makeVal ("parse-error", [])
    ThrownError label val -> pure (label, val)
    Exit -> makeVal ("exit", [])
  where
    makeA = quote . Atom
    makeVal (t,v) = pure (Ident t, Dict $ Map.mapKeys (Keyword . Ident) . GhcExts.fromList $ v)

newtype Reference = Reference { getReference :: Int }
    deriving (Show, Read, Ord, Eq, Generic, Serialise)

-- | Create a new ref with the supplied initial value.
newRef :: Monad m => Value -> Lang m Value
newRef v = do
    b <- get
    let ix = bindingsNextRef b
    put $ b { bindingsNextRef = succ ix
            , bindingsRefs = IntMap.insert ix v $ bindingsRefs b
            }
    pure . Ref $ Reference ix

-- | Read the value of a reference.
readRef :: Monad m => Reference -> Lang m Value
readRef (Reference r) = do
    refs <- gets bindingsRefs
    case IntMap.lookup r refs of
        Nothing -> throwErrorHere $ Impossible "undefined reference"
        Just v  -> pure v

-- | An expression or value in the language.
data ValueF r =
    -- | A regular (hyperstatic) variable.
      AtomF Ident
    -- | Symbolic identifiers that evaluate to themselves.
    | KeywordF Ident
    | StringF Text
    | NumberF Scientific
    | BooleanF Bool
    | ListF [r]
    | VecF (Seq.Seq r)
    | PrimopF Ident
    -- | Map from *pure* Values -- annotations shouldn't change lookup semantics.
    | DictF (Map.Map Value r)
    | RefF Reference
    -- | Takes the arguments/parameters, a body, and possibly a closure.
    --
    -- The value of an application of a lambda is always the last value in the
    -- body. The only reason to have multiple values is for effects.
    | LambdaF [Ident] (NonEmpty r) (Env r)
    deriving (Eq, Ord, Read, Show, Generic, Functor)

{-# COMPLETE Atom, Keyword, String, Number, Boolean, List, Primop, Dict, Ref, Lambda #-}

type ValueConC t = (HasCallStack, Ann.Annotation t, Copointed t)

pattern Atom :: ValueConC t => Ident -> Annotated t ValueF
pattern Atom i <- (Ann.match -> AtomF i)
    where
    Atom = Ann.annotate . AtomF

pattern Keyword :: ValueConC t => Ident -> Annotated t ValueF
pattern Keyword i <- (Ann.match -> KeywordF i)
    where
    Keyword = Ann.annotate . KeywordF

pattern String :: ValueConC t => Text -> Annotated t ValueF
pattern String i <- (Ann.match -> StringF i)
    where
    String = Ann.annotate . StringF

pattern Number :: ValueConC t => Scientific -> Annotated t ValueF
pattern Number i <- (Ann.match -> NumberF i)
    where
    Number = Ann.annotate . NumberF

pattern Boolean :: ValueConC t => Bool -> Annotated t ValueF
pattern Boolean i <- (Ann.match -> BooleanF i)
    where
    Boolean = Ann.annotate . BooleanF

pattern List :: ValueConC t => [Annotated t ValueF] -> Annotated t ValueF
pattern List vs <- (Ann.match -> ListF vs)
    where
    List = Ann.annotate . ListF

pattern Vec :: ValueConC t => Seq.Seq (Annotated t ValueF) -> Annotated t ValueF
pattern Vec vs <- (Ann.match -> VecF vs)
    where
    Vec = Ann.annotate . VecF

pattern Primop :: ValueConC t => Ident -> Annotated t ValueF
pattern Primop i <- (Ann.match -> PrimopF i)
    where
    Primop = Ann.annotate . PrimopF

pattern Dict :: ValueConC t => Map.Map Value (Annotated t ValueF) -> Annotated t ValueF
pattern Dict vs <- (Ann.match -> DictF vs)
    where
    Dict = Ann.annotate . DictF

pattern Ref :: ValueConC t => Reference -> Annotated t ValueF
pattern Ref i <- (Ann.match -> RefF i)
    where
    Ref = Ann.annotate . RefF

pattern Lambda :: ValueConC t => [Ident] -> NonEmpty (Annotated t ValueF) -> Env (Annotated t ValueF) -> Annotated t ValueF
pattern Lambda vs exps env <- (Ann.match -> LambdaF vs exps env)
    where
    Lambda vs exps env = Ann.annotate $ LambdaF vs exps env


type UntaggedValue = Annotated Identity ValueF
type Value = Annotated Ann.WithPos ValueF

-- Remove polymorphism
asValue :: Value -> Value
asValue x = x

-- Should just be a prism
isAtom :: Value -> Maybe Ident
isAtom (Atom i) = pure i
isAtom _        = Nothing

-- should be a prism
isInt :: Value -> Maybe Integer
isInt (Number s) = either (const Nothing :: Double -> Maybe Integer) pure (floatingOrInteger s)
isInt _ = Nothing

instance A.FromJSON Value where
  parseJSON = \case
    A.Number n -> pure $ Number n
    A.String s -> pure $ String s
    A.Array ls -> List . toList <$> traverse parseJSON ls
    A.Bool b -> pure $ Boolean b
    A.Null -> pure $ Keyword (Ident "null")
    A.Object hm -> do
      let kvs = HashMap.toList hm
      vs <- traverse parseJSON (snd <$> kvs)
      pure . Dict . Map.fromList $ zip (String . fst <$> kvs) vs

-- | Convert a radicle `Value` into an 'aeson' value, if possible.
--
-- >>> import Data.Aeson (encode)
-- >>> encode $ maybeJson $ List [Number 3, String "hi"]
-- "[3,\"hi\"]"
--
-- >>> import Data.Aeson (encode)
-- >>> encode $ maybeJson $ Dict $ Map.fromList [(String "foo", String "bar")]
-- "{\"foo\":\"bar\"}"
--
-- This fails for lambdas, since lambdas capture an entire environment
-- (possibly recursively). It also fails for dictionaries with non-string key
-- non-string keys.
--
-- >>> import Data.Aeson (encode)
-- >>> encode $ maybeJson $ Dict $ Map.fromList [(Number 3, String "bar")]
-- "null"
maybeJson :: Value -> Maybe A.Value
maybeJson = \case
    Number n -> pure $ A.Number n
    String s -> pure $ A.String s
    Boolean b -> pure $ A.Bool b
    List ls -> toJSON <$> traverse maybeJson ls
    Dict m -> do
      let kvs = Map.toList m
      ks <- traverse isStr (fst <$> kvs)
      vs <- traverse maybeJson (snd <$> kvs)
      pure $ A.Object (HashMap.fromList (zip ks vs))
    _ -> Nothing
  where
    isStr (String s) = pure s
    isStr _          = Nothing

-- | An identifier in the language.
--
-- Not all `Text`s are valid identifiers, so use 'Ident' at your own risk.
-- `mkIdent` is the safe version.
newtype Ident = Ident { fromIdent :: Text }
    deriving (Eq, Show, Read, Ord, Generic, Data, Serialise)

pattern Identifier :: Text -> Ident
pattern Identifier t <- Ident t

-- | Convert a text to an identifier.
--
-- Unsafe! Only use this if you know the string at compile-time and know it's a
-- valid identifier. Otherwise, use 'mkIdent'.
unsafeToIdent :: Text -> Ident
unsafeToIdent = Ident

-- | The environment, which keeps all known bindings.
newtype Env s = Env { fromEnv :: Map Ident s }
    deriving (Eq, Semigroup, Monoid, Ord, Show, Read, Generic, Functor, Foldable, Traversable, Serialise)

instance GhcExts.IsList (Env s) where
    type Item (Env s) = (Ident, s)
    fromList = Env . Map.fromList
    toList = GhcExts.toList . fromEnv

-- | Primop mappings. The parameter specifies the monad the primops run in.
newtype Primops m = Primops { getPrimops :: Map Ident ([Value ] -> Lang m Value) }
  deriving (Semigroup)

-- | Bindings, either from the env or from the primops.
data Bindings prims = Bindings
    { bindingsEnv     :: Env Value
    , bindingsPrimops :: prims
    , bindingsRefs    :: IntMap Value
    , bindingsNextRef :: Int
    } deriving (Eq, Show, Functor, Generic)

-- | The environment in which expressions are evaluated.
newtype LangT r m a = LangT
    { fromLangT :: ExceptT (LangError Value) (StateT r m) a }
    deriving (Functor, Applicative, Monad, MonadError (LangError Value), MonadIO, MonadState r)

mapError :: (Functor m) => (LangError Value -> LangError Value) -> LangT r m a -> LangT r m a
mapError f = LangT . withExceptT f . fromLangT

logPos :: (Functor m) => Ann.SrcPos -> LangT r m a -> LangT r m a
logPos loc = mapError (\(LangError stack err) -> LangError (loc:stack) err)

-- | Log the source location associated with a value.
logValPos :: (Functor m) => Value -> LangT r m a -> LangT r m a
logValPos (Ann.Annotated (Ann.WithPos pos _)) = logPos pos

instance MonadTrans (LangT r) where lift = LangT . lift . lift

-- | A monad for language operations specialized to have as state the Bindings
-- with appropriate underlying monad.
type Lang m = LangT (Bindings (Primops m)) m

-- | Run a `Lang` computation with the provided bindings. Returns the result as
-- well as the updated bindings.
runLang
    :: Bindings (Primops m)
    -> Lang m a
    -> m (Either (LangError Value) a, Bindings (Primops m))
runLang e l = runStateT (runExceptT $ fromLangT l) e

-- | Like 'local' or 'withState'. Will run an action with a modified environment
-- and then restore the original bindings.
withBindings :: Monad m => (Bindings (Primops m) -> Bindings (Primops m)) -> Lang m a -> Lang m a
withBindings modifier action = do
    oldBnds <- get
    modify modifier
    res <- action
    put oldBnds
    pure res

-- | Like 'local' or 'withState'. Will run an action with a modified environment
-- and then restore the original environment. Other bindings (i.e. primops and
-- refs) are not affected.
withEnv :: Monad m => (Env Value -> Env Value) -> Lang m a -> Lang m a
withEnv modifier action = do
    oldEnv <- gets bindingsEnv
    modify $ \s -> s { bindingsEnv = modifier oldEnv }
    res <- action
    modify $ \s -> s { bindingsEnv = oldEnv }
    pure res

-- * Functions

addBinding :: Ident -> Value -> Bindings m -> Bindings m
addBinding i v b = b
    { bindingsEnv = Env . Map.insert i v . fromEnv $ bindingsEnv b }

-- | Lookup an atom in the environment
lookupAtom :: Monad m => Ident -> Lang m Value
lookupAtom i = get >>= \e -> case Map.lookup i . fromEnv $ bindingsEnv e of
    Nothing -> throwErrorHere $ UnknownIdentifier i
    Just v  -> pure v

-- | Lookup a primop.
lookupPrimop :: Monad m => Ident -> Lang m ([Value] -> Lang m Value)
lookupPrimop i = get >>= \e -> case Map.lookup i $ getPrimops $ bindingsPrimops e of
    Nothing -> throwErrorHere $ Impossible "Unknown primop"
    Just v  -> pure v

defineAtom :: Monad m => Ident -> Value -> Lang m ()
defineAtom i v = modify $ addBinding i v

-- * Eval

-- | The buck-passing eval. Uses whatever 'eval' is in scope.
eval :: Monad m => Value -> Lang m Value
eval val = do
    e <- lookupAtom (Ident "eval")
    st <- gets toRad
    logValPos e $ case e of
        Primop i -> do
            fn <- lookupPrimop i
            -- Primops get to decide whether and how their args are
            -- evaluated.
            res <- fn [quote val, quote st]
            updateEnvAndReturn res
        l@Lambda{} -> callFn l [val, st] >>= updateEnvAndReturn
        _ -> throwErrorHere $ TypeError "Trying to apply a non-function"
  where
    updateEnvAndReturn :: Monad m => Value -> Lang m Value
    updateEnvAndReturn v = case v of
        List [val', newSt] -> do
            prims <- gets bindingsPrimops
            newSt' <- either (throwErrorHere . OtherError) pure
                      (fromRad newSt :: Either Text (Bindings ()))
            put $ newSt' { bindingsPrimops = prims }
            pure val'
        _ -> throwErrorHere $ OtherError "eval: should return list with value and new env"


-- | The built-in, original, eval.
baseEval :: Monad m => Value -> Lang m Value
baseEval val = logValPos val $ case val of
    Atom i -> lookupAtom i
    List (f:vs) -> f $$ vs
    List xs -> throwErrorHere
        $ WrongNumberOfArgs ("application: " <> show xs)
                            2
                            (length xs)
    Vec xs -> Vec <$> traverse baseEval xs
    Dict mp -> do
        let evalBoth (a,b) = (,) <$> baseEval a <*> baseEval b
        Dict . Map.fromList <$> traverse evalBoth (Map.toList mp)
    autoquote -> pure autoquote

-- * From/ToRadicle

class FromRad a where
  fromRad :: Value -> Either Text a
  default fromRad :: (HasEot a, FromRadG (Eot a)) => Value -> Either Text a
  fromRad = fromRadG

instance FromRad Value where
  fromRad = pure
instance FromRad Scientific where
    fromRad x = case x of
        Number n -> pure n
        _        -> Left "Expecting number"
instance FromRad Integer where
    fromRad = \case
      Number s -> case floatingOrInteger s of
        Left (_ :: Double) -> Left "Expecting whole number"
        Right i            -> pure i
      _ -> Left "Expecting number"
instance FromRad Text where
    fromRad x = case x of
        String n -> pure n
        _        -> Left "Expecting string"
instance FromRad a => FromRad [a] where
    fromRad x = case x of
        List xs -> traverse fromRad xs
        Vec  xs -> traverse fromRad (toList xs)
        _       -> Left "Expecting list"
instance FromRad (Env Value) where
    fromRad x = case x of
        Dict d -> fmap (Env . Map.fromList)
                $ forM (Map.toList d) $ \(k, v) -> case k of
            Atom i -> pure (i, v)
            k'     -> Left $ "Expecting atom keys. Got: " <> show k'
        _ -> Left "Expecting dict"
instance FromRad (Bindings ()) where
    fromRad x = case x of
        Dict d -> do
            env' <- kwLookup "env" d ?? "Expecting 'env' key"
            refs' <- kwLookup "refs" d ?? "Expecting 'refs' key"
            refs <- makeRefs refs'
            env <- fromRad env'
            pure $ Bindings env () refs (length refs)
        _ -> throwError "Expecting dict"
      where
        makeRefs refs = case refs of
            List ls -> pure (IntMap.fromList $ zip [0..] ls)
            _       -> throwError $ "Expecting dict"


class ToRad a where
  toRad :: a -> Value
  default toRad :: (HasEot a, ToRadG (Eot a)) => a -> Value
  toRad = toRadG

instance ToRad Int where
    toRad = Number . fromIntegral
instance ToRad Integer where
    toRad = Number . fromIntegral
instance ToRad Scientific where
    toRad = Number
instance ToRad Text where
    toRad = String
instance ToRad a => ToRad [a] where
    toRad xs = List $ toRad <$> xs
instance ToRad a => ToRad (Map.Map Text a) where
    toRad xs = Dict $ Map.mapKeys String $ toRad <$> xs
instance ToRad (Env Value) where
    toRad x = Dict . Map.mapKeys Atom $ fromEnv x
instance ToRad (Bindings m) where
    toRad x = Dict $ Map.fromList
        [ (Keyword $ Ident "env", toRad $ bindingsEnv x)
        , (Keyword $ Ident "refs", List $ IntMap.elems (bindingsRefs x))
        ]

-- * Helpers

-- Loc is the source location of the application.
callFn :: Monad m => Value -> [Value] -> Lang m Value
callFn f vs = case f of
  Lambda bnds body closure ->
      if length bnds /= length vs
          then throwErrorHere $ WrongNumberOfArgs "lambda" (length bnds)
                                                           (length vs)
          else do
              let mappings = GhcExts.fromList (zip bnds vs)
                  modEnv = mappings <> closure
              NonEmpty.last <$> withEnv (const modEnv)
                                        (traverse baseEval body)
  Primop i -> throwErrorHere . TypeError
    $ "Trying to call a non-function: the primop '" <> show i
    <> "' cannot be used as a function."
  _ -> throwErrorHere . TypeError $ "Trying to call a non-function."

-- | Infix evaluation of application (of functions or primops)
infixr 1 $$
($$) :: Monad m => Value -> [Value] -> Lang m Value
mfn $$ vs = do
    mfn' <- baseEval mfn
    case mfn' of
        Primop i -> do
            fn <- lookupPrimop i
            -- Primops get to decide whether and how their args are
            -- evaluated.
            fn vs
        f@Lambda{} -> do
          vs' <- traverse baseEval vs
          callFn f vs'
        _ -> throwErrorHere $ TypeError "Trying to apply a non-function"

nil :: Value
nil = List []

quote :: Value -> Value
quote v = List [Primop (Ident "quote"), v]

list :: [Value] -> Value
list vs = List (Primop (Ident "list") : vs)

kwLookup :: Text -> Map Value Value -> Maybe Value
kwLookup key = Map.lookup (Keyword $ Ident key)

(??) :: MonadError e m => Maybe a -> e -> m a
a ?? n = n `note` a

hoistEither :: MonadError e m => Either e a -> m a
hoistEither = hoistEitherWith identity

hoistEitherWith :: MonadError e' m => (e -> e') -> Either e a -> m a
hoistEitherWith f (Left e)  = throwError (f e)
hoistEitherWith _ (Right x) = pure x

-- * Generic encoding/decoding of Radicle values.

toRadG :: forall a. (HasEot a, ToRadG (Eot a)) => a -> Value
toRadG x = toRadConss (constructors (datatype (Proxy :: Proxy a))) (toEot x)

class ToRadG a where
  toRadConss :: [Constructor] -> a -> Value

instance (ToRadFields a, ToRadG b) => ToRadG (Either a b) where
  toRadConss (Constructor name fieldMeta : _) (Left fields) =
    case fieldMeta of
      Selectors names ->
        radCons (toS name) . pure . Dict . Map.fromList $
          zip (Keyword . Ident . toS <$> names) (toRadFields fields)
      NoSelectors _ -> radCons (toS name) (toRadFields fields)
      NoFields -> radCons (toS name) []
  toRadConss (_ : r) (Right next) = toRadConss r next
  toRadConss [] _ = panic "impossible"

radCons :: Text -> [Value] -> Value
radCons name args = List ( Keyword (Ident name) : args )

instance ToRadG Void where
  toRadConss _ = absurd

class ToRadFields a where
  toRadFields :: a -> [Value]

instance (ToRad a, ToRadFields as) => ToRadFields (a, as) where
  toRadFields (x, xs) = toRad x : toRadFields xs

instance ToRadFields () where
  toRadFields () = []

-- Generic decoding of Radicle values to Haskell values

fromRadG :: forall a. (HasEot a, FromRadG (Eot a)) => Value -> Either Text a
fromRadG v = do
  (name, args) <- isRadCons v ?? gDecodeErr "expecting constructor"
  fromEot <$> fromRadConss (constructors (datatype (Proxy :: Proxy a))) name args

class FromRadG a where
  fromRadConss :: [Constructor] -> Text -> [Value] -> Either Text a

isRadCons :: Value -> Maybe (Text, [Value])
isRadCons (List (Keyword (Ident name) : args)) = pure (name, args)
isRadCons _                                    = Nothing

gDecodeErr :: Text -> Text
gDecodeErr e = "Couldn't generically decode radicle value: " <> e

instance (FromRadFields a, FromRadG b) => FromRadG (Either a b) where
  fromRadConss (Constructor name fieldMeta : r) name' args = do
    if toS name /= name'
      then Right <$> fromRadConss r name' args
      else Left <$> fromRadFields fieldMeta args
  fromRadConss [] _ _ = panic "impossible"

instance FromRadG Void where
  fromRadConss _ name _ = Left (gDecodeErr "unknown constructor '" <> name <> "'")

class FromRadFields a where
  fromRadFields :: Fields -> [Value] -> Either Text a

instance (FromRad a, FromRadFields as) => FromRadFields (a, as) where
  fromRadFields fields args = case fields of
    NoSelectors _ -> case args of
      v:vs -> do
        x <- fromRad v
        xs <- fromRadFields fields vs
        pure (x, xs)
      _ -> panic "impossible"
    Selectors (n:names) -> case args of
      [Dict d] -> do
        xv <- kwLookup (toS n) d ?? gDecodeErr ("missing field '" <> toS n <> "'")
        x <- fromRad xv
        xs <- fromRadFields (Selectors names) args
        pure (x, xs)
      _ -> Left . gDecodeErr $ "expecting a dict"
    _ -> panic "impossible"

instance FromRadFields () where
  fromRadFields _ _ = pure ()
