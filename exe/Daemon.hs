{-# OPTIONS_GHC -fno-warn-orphans #-}

module Daemon where

import           Protolude hiding (fromStrict, option, poll)

import qualified Data.Aeson as A
import           Data.ByteString.Lazy (fromStrict)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Network.HTTP.Types.URI as URL
import           Network.Wai.Handler.Warp (run)
import qualified Data.Time.Clock.System as Time
import           Options.Applicative
import           Servant
import           System.Directory (doesFileExist)

import qualified Radicle.Internal.UUID as UUID
import           Server.Common

import           Radicle hiding (Env)
import           Radicle.Daemon.Ipfs
import qualified Radicle.Internal.CLI as Local


-- TODO(james): Check that the IPFS functions are doing all the
-- necessary pinning.

-- TODO(james): There is no polling yet.

-- * Types

-- TODO(james): Decide if there is a protocol prefix.
instance FromHttpApiData MachineId where
  parseUrlPiece = Right . MachineId . toS . URL.urlDecode False . toS
  parseQueryParam = parseUrlPiece

newtype Expression = Expression { expression :: JsonValue }
  deriving (Generic)

instance A.ToJSON Expression
instance A.FromJSON Expression

newtype Expressions = Expressions { expressions :: [JsonValue] }
  deriving (Generic)

instance A.FromJSON Expressions
instance A.ToJSON Expressions

newtype SendResult = SendResult
  { results :: [JsonValue]
  } deriving (A.ToJSON)

data Error
  = InvalidInput (LangError Value)
  | IpfsError Text
  | AckTimeout
  | DaemonError Text
  | MachineAlreadyCached
  | MachineNotCached
  deriving (Show)

type Follows = Map MachineId ReaderOrWriter

-- * APIs

type Query = "query" :> ReqBody '[JSON] Expression  :> Post '[JSON] Expression
type Send  = "send"  :> ReqBody '[JSON] Expressions :> Post '[JSON] SendResult
type New   = "new"   :> Post '[JSON] MachineId

type DaemonApi =
  "v0" :> "machines" :> ( Capture "machineId" MachineId :> ( Query :<|> Send ) :<|> New )

daemonApi :: Proxy DaemonApi
daemonApi = Proxy

-- * Main

data Opts = Opts
  { port       :: Int
  -- TODO(james): temporary, just for testing.
  , filePrefix :: Text
  }

opts :: Parser Opts
opts = Opts
    <$> option auto
        ( long "port"
       <> help "daemon port"
       <> metavar "PORT"
       <> showDefault
       <> value 8909
        )
    <*> strOption
        ( long "filePrefix"
       <> help "file prefix"
       <> metavar "PREFIX"
       <> showDefault
       <> value ""
        )

type FollowFileLock = MVar ()

data Env = Env
  { followFileLock :: FollowFileLock
  , followFile     :: FilePath
  , machines       :: IpfsMachines
  }

newtype Daemon a = Daemon { fromDaemon :: ExceptT Error (ReaderT Env IO) a }
  deriving (Functor, Applicative, Monad, MonadError Error, MonadIO, MonadReader Env)

runDaemon :: Env -> Daemon a -> IO (Either Error a)
runDaemon env (Daemon x) = runReaderT (runExceptT x) env

main :: IO ()
main = do
    opts' <- execParser allOpts
    followFileLock <- newMVar ()
    followFile <- Local.getRadicleFile (toS (filePrefix opts') <> "daemon-follows")
    machines <- Chains <$> newMVar Map.empty
    let env = Env{..}
    follows <- readFollowFileIO followFileLock followFile
    initRes <- runDaemon env $ traverse_ init (Map.toList follows)
    case initRes of
      Left err -> panic $ "Failed to initialise: " <> show err
      Right _ -> do
        let app = serve daemonApi (server env)
        logInfo "Start listening" [("port", show (port opts'))]
        run (port opts') app
  where
    allOpts = info (opts <**> helper)
        ( fullDesc
       <> progDesc "Run then radicle daemon"
       <> header "radicle-daemon"
        )
    init (id, Reader) = initAsReader id
    init (id, Writer) = initAsWriter id

type IpfsMachine = Chain MachineId MachineEntryIndex TopicSubscription
type IpfsMachines = Chains MachineId MachineEntryIndex TopicSubscription

server :: Env -> Server DaemonApi
server env = hoistServer daemonApi nt daemonServer
  where
    daemonServer :: ServerT DaemonApi Daemon
    daemonServer = machineEndpoints :<|> newMachine
    machineEndpoints id = query id :<|> send id

    nt :: Daemon a -> Handler a
    nt d = do
      x_ <- liftIO $ runDaemon env d
      case x_ of
        Left err -> throwError (toServantErr err)
        Right x  -> pure x

    toServantErr = \case
      InvalidInput err -> err400 { errBody = fromStrict $ encodeUtf8 (renderPrettyDef err) }
      IpfsError err -> err500 { errBody = toS err }
      DaemonError err -> err500 { errBody = toS err }
      AckTimeout -> err504 { errBody = "The writer for this IPFS machine does not appear to be online." }
      MachineAlreadyCached -> internalError
      MachineNotCached -> internalError

    internalError = err500 { errBody = "Internal daemon error" }

-- * Endpoints

-- | Create a new IPFS machine and initialise the daemon as as the
-- /writer/.
newMachine :: Daemon MachineId
newMachine = do
  id <- ipfs createMachine
  sub <- ipfs $ initSubscription id
  logInfo "Created new IPFS machine" [("id", getMachineId id)]
  m <- liftIO $ emptyMachine id Writer sub
  insertNewMachine m
  actAsWriter m
  writeFollowFile
  pure id

-- | Evaluate an expression.
query :: MachineId -> Expression -> Daemon Expression
query id (Expression (JsonValue v)) = do
  m <- checkMachineLoaded id
  case fst <$> runIdentity $ runLang (chainState m) $ eval v of
    Left err -> throwError (InvalidInput err)
    Right rv -> do
      logInfo "Query success:" [("result", renderCompactPretty rv)]
      pure (Expression (JsonValue rv))

-- | Write a new expression to an IPFS machine.
send :: MachineId -> Expressions -> Daemon SendResult
send id (Expressions expressions) = do
  mode_ <- machineMode
  case mode_ of
    Just (Writer, _) -> do
      let vs = jsonValue <$> expressions
      rs <- writeInputs id vs Nothing
      logInfo "Send as writer success" [("id", getMachineId id)]
      pure SendResult{ results = JsonValue <$> rs }
    Just (Reader, sub) -> requestInput sub
    Nothing -> do
      m <- initAsReader id
      requestInput (chainSubscription m)
  where
    requestInput sub = do
      nonce <- liftIO $ UUID.uuid
      let isResponse = \case
            New NewInputs{ nonce = Just nonce' } | nonce' == nonce -> True
            _ -> False
      -- TODO(james): decide what a good timeout is.
      asyncMsg <- liftIO $ async $ subscribeOne sub 4000 isResponse
      ipfs $ publish id (Req ReqInputs{..})
      msg_ <- liftIO $ wait asyncMsg
      case msg_ of
        Nothing -> throwError AckTimeout
        Just (New NewInputs{results}) -> do
          logInfo "Send as reader success" [("id", getMachineId id)]
          pure SendResult{..}
        _ -> throwError $ DaemonError "Didn't filter machine topic messages correctly."
    machineMode :: Daemon (Maybe (ReaderOrWriter, TopicSubscription))
    machineMode = fmap (liftA2 (,) chainMode chainSubscription) <$> lookupMachine id

-- * Helpers

withFollowFileLock :: FollowFileLock -> IO a -> IO a
withFollowFileLock lock = withMVar lock . const

readFollowFileIO :: FollowFileLock -> FilePath -> IO Follows
readFollowFileIO lock ff = withFollowFileLock lock $ do
  exists <- doesFileExist ff
  t <- if exists
    then readFile ff
    else let noFollows = toS (A.encode (Map.empty :: Follows))
         in writeFile ff noFollows $> noFollows
  case A.decode (toS t) of
    Nothing -> panic $ "Invalid daemon-follow file: could not decode " <> toS ff
    Just fs -> pure fs

writeFollowFile :: Daemon ()
writeFollowFile = do
  lock <- asks followFileLock
  Chains msVar <- asks machines
  ff <- asks followFile
  liftIO $ withFollowFileLock lock $ do
    ms <- takeMVar msVar
    let fs = Map.fromList $ second chainMode <$> Map.toList ms
    writeFile ff (toS $ A.encode fs)

lookupMachine :: MachineId -> Daemon (Maybe IpfsMachine)
lookupMachine id = do
  msVar <- asks machines
  ms <- liftIO $ readMVar (getChains msVar)
  pure (Map.lookup id ms)

-- | Given an 'MachineId', makes sure the machine is in the cache and
-- updated.
checkMachineLoaded :: MachineId -> Daemon IpfsMachine
checkMachineLoaded id = do
  m_ <- lookupMachine id
  case m_ of
    Nothing -> do
      -- In this case we have not seen the machine before so we act as
      -- a reader.
      m <- initAsReader id
      writeFollowFile
      pure m
    Just m -> case chainMode m of
      Writer -> pure m
      Reader -> refreshAsReader id

daemonHandler :: Env -> MachineId -> (Message -> Daemon ()) -> Message -> IO ()
daemonHandler env id h msg = do
  x_ <- runDaemon env (h msg)
  case x_ of
    Left err -> logDaemonError err
    Right _  -> pure ()
  where
    logDaemonError = \case
      InvalidInput e -> logErr "Invalid input" [mid, ("error", renderCompactPretty e)]
      DaemonError e -> logErr e [mid]
      IpfsError e -> logErr "There was an error using IPFS" [mid, ("error", e)]
      AckTimeout -> logErr "The writer appears to be offline" [mid]
      MachineAlreadyCached -> logErr "Tried to add already cached machine" [mid]
      MachineNotCached -> logErr "Machine was not found in cache" [mid]
    mid = ("id", getMachineId id)

-- Loads a machine fresh from IPFS.
loadMachine :: ReaderOrWriter -> MachineId -> Daemon IpfsMachine
loadMachine mode id = do
  (idx, is) <- ipfs $ machineInputsFrom id Nothing
  sub <- ipfs $ initSubscription id
  m <- liftIO $ emptyMachine id mode sub
  (m', _) <- addInputs is (pure idx) (const (pure ())) m
  insertNewMachine m'
  pure m'

-- Add inputs to a cached machine.
addInputs
  :: [Value]
  -- ^ Inputs to add.
  -> Daemon MachineEntryIndex
  -- ^ Determine the new index.
  -> ([Value] -> Daemon ())
  -- ^ Performed after the chain is cached.
  -> IpfsMachine
  -> Daemon (IpfsMachine, [Value])
  -- ^ Returns the updated machine and the results.
addInputs is getIdx after m =
  case advanceChain m is of
    Left err -> Daemon $ ExceptT $ pure $ Left $ InvalidInput err
    Right (rs, newState) -> do
      idx <- getIdx
      let news = Seq.fromList $ zip is rs
          m' = m { chainState = newState
                 , chainLastIndex = Just idx
                 , chainEvalPairs = chainEvalPairs m Seq.>< news
                 }
      after rs
      pure (m', rs)

ipfs :: ExceptT Text IO a -> Daemon a
ipfs = Daemon . mapExceptT (lift . fmap (first IpfsError))

-- Do some high-freq polling for a while.
bumpPolling :: IpfsMachine -> IO ()
bumpPolling _ = pure () -- TODO(james):

-- Insert a new machine into the cache. Errors if the machine is
-- already cached.
insertNewMachine :: IpfsMachine -> Daemon ()
insertNewMachine m = do
    msVar <- asks machines
    inserted <- liftIO $ modifyMVar (getChains msVar) $ \ms ->
      if Map.member id ms
      then pure (ms, False)
      else pure (Map.insert id m ms, True)
    if inserted then pure () else throwError MachineAlreadyCached
  where
    id = chainName m

-- Modify a machine that is already in the cache. Errors if the
-- machine isn't in the cache already.
modifyMachine :: MachineId -> (IpfsMachine -> Daemon (IpfsMachine, a)) -> Daemon a
modifyMachine id f = do
    env <- ask
    res <- liftIO $ modifyMVar (getChains (machines env)) $ \ms ->
      case Map.lookup id ms of
        Nothing -> pure (ms, Left MachineNotCached)
        Just m -> do
          x <- runDaemon env (f m)
          pure $ case x of
            Left err -> (ms, Left err)
            Right (m', y) -> (Map.insert id m' ms, Right y) 
    case res of
      Left err -> throwError err
      Right y-> pure y

emptyMachine :: MachineId -> ReaderOrWriter -> TopicSubscription -> IO IpfsMachine
emptyMachine id mode sub = do
  t <- Time.getSystemTime
  pure Chain{ chainName = id
            , chainState = pureEnv
            , chainEvalPairs = mempty
            , chainLastIndex = Nothing
            , chainMode = mode
            , chainSubscription = sub
            , chainLastUpdated = t
            , chainPolling = highFreq
            }

-- TODO(james): decide on a polling frequency
highFreq :: Polling
highFreq = HighFreq 10

-- ** Reader

-- Initialise the daemon service for this machine in /reader mode/.
initAsReader :: MachineId -> Daemon IpfsMachine
initAsReader id = do
    m <- loadMachine Reader id
    env <- ask
    _ <- liftIO $ addHandler (chainSubscription m) (daemonHandler env id onMsg)
    logInfo "Following as reader" [("id", getMachineId id)]
    liftIO $ bumpPolling m
    pure m
  where
    onMsg :: Message -> Daemon ()
    onMsg = \case
      New NewInputs{..} -> refreshAsReader id >> pure ()
      _ -> pure ()

-- Freshen up a cached machine.
refreshAsReader :: MachineId -> Daemon IpfsMachine
refreshAsReader id = do
  m <- modifyMachine id $ \m -> do
    (idx, is) <- ipfs $ machineInputsFrom (chainName m) (chainLastIndex m)
    (m', _) <- addInputs is (pure idx) (const (pure ())) m
    pure (m', m')
  liftIO $ bumpPolling m
  pure m

-- ** Writer

initAsWriter :: MachineId -> Daemon IpfsMachine
initAsWriter id = do
  m <- loadMachine Writer id
  actAsWriter m
  pure m

-- Subscribes the daemon to the machine's pubsub topic to listen for
-- input requests.
actAsWriter :: IpfsMachine -> Daemon ()
actAsWriter m = do
    env <- ask
    _ <- liftIO $ addHandler (chainSubscription m) (daemonHandler env (chainName m) onMsg)
    logInfo "Acting as writer" [("id", getMachineId id)]
  where
    id = chainName m
    onMsg = \case
      Req ReqInputs{..} -> writeInputs id (jsonValue <$> expressions) (Just nonce) >> pure ()
      _ -> pure ()

-- Write some inputs to a machine as the writer, sends out a
-- 'NewInput' message.
writeInputs :: MachineId -> [Value] -> Maybe Text -> Daemon [Value]
writeInputs id is nonce = modifyMachine id $ addInputs is write pub
  where
    write = ipfs $ writeIpfs id is
    pub rs = ipfs $ publish id (New NewInputs{results = JsonValue <$> rs, ..})

-- * Polling

poll :: Daemon ()
poll = do
    msVar <- asks machines
    ms <- liftIO $ readMVar (getChains msVar)
    t <- liftIO Time.getSystemTime
    traverse_ (pollMachine t) ms
  where
    pollMachine :: Time.SystemTime -> IpfsMachine -> Daemon ()
    pollMachine t Chain{chainMode = Reader, ..} = do
      let delta = timeDelta chainLastUpdated t
      let (shouldPoll, newPoll) =
            case chainPolling of              
              HighFreq more ->
                let more' = delta - more
                in if more' > 0
                   then (True, HighFreq more')
                   else (False, LowFreq)
              LowFreq -> (True, LowFreq)
      if shouldPoll
        then do _ <- refreshAsReader chainName
                modifyMachine chainName $ \m ->
                  pure (m { chainLastUpdated = t
                          , chainPolling = newPoll
                          }
                       , ()
                       )
        else pure ()
    pollMachine _ _ = pure ()
    timeDelta (Time.MkSystemTime s _) (Time.MkSystemTime s' _) = s' - s

initPolling :: Daemon ()
initPolling = do
  liftIO $ threadDelay 1000000
  poll
  initPolling