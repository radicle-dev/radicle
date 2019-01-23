module Radicle.Internal.ConcurrentMap
  ( empty
  , lookup
  , nonAtomicRead
  , insertNew
  , modifyExistingValue
  , CMap
  ) where

import           Protolude hiding (empty)

import qualified Data.Map.Strict as Map

-- | A Map which offers atomic operations on the values associated to
-- keys. Assumes that the values are independent of one another; does
-- not offer a consistent view over the values.
newtype CMap k v = CMap (MVar (Map k (MVar v)))

-- | Create a new empty 'CMap'.
empty :: IO (CMap k v)
empty = CMap <$> newMVar Map.empty

-- | Atomically lookup a value.
lookup :: Ord k => k -> CMap k v -> IO (Maybe v)
lookup k (CMap m_) = withMVar m_ $ \m -> do
   case Map.lookup k m of
     Nothing -> pure Nothing
     Just v_ -> pure <$> readMVar v_

-- | Non-atmoically read the contents of a 'CMap'.  Provides a
-- consistent shapshot of which keys were present at some
-- time. Howerver the values might be snapshotted at different times.
nonAtomicRead :: CMap k v -> IO (Map k v)
nonAtomicRead (CMap m_) = do
  m <- readMVar m_
  traverse readMVar m

-- | Atomically insert a key-value pair into a 'CMap' but only if the
-- key is not already a member.
insertNew :: Ord k => k -> v -> CMap k v -> IO (Maybe ())
insertNew k v (CMap m_) = modifyMVar m_ $ \m ->
  if Map.member k m
    then pure (m, Nothing)
    else do
      v_ <- newMVar v
      let m' = Map.insert k v_ m
      pure (m', Just ())

-- | Atomically modifies a value associated to a key but only if it
-- exists.
modifyExistingValue :: Ord k => k -> (v -> IO v) -> CMap k v -> IO (Maybe ())
modifyExistingValue k f (CMap m_) = do
  m <- readMVar m_
  case Map.lookup k m of
    Nothing -> pure Nothing
    Just v_ -> do
      modifyMVar_ v_ f
      pure (Just ())
