{-# LANGUAGE RankNTypes, ScopedTypeVariables, GADTs #-}
module Network.RPC.Curryer.Client where
import Network.RPC.Curryer.Server
import Network.Socket as Socket (Socket, PortNumber, SockAddr(..), close, Family(..), SocketType(..), tupleToHostAddress, tupleToHostAddress6)
import Streamly.Internal.Network.Socket (SockSpec(..))
import qualified Streamly.Internal.Network.Socket as SINS
import qualified Network.RPC.Curryer.StreamlyTLS as STLS
import Codec.Winery
import Control.Concurrent.Async
import qualified Data.UUID.V4 as UUIDBase
import qualified StmContainers.Map as STMMap
import Control.Concurrent.MVar
import GHC.Conc
import Data.Time.Clock
import System.Timeout
import Control.Monad
import Network.TLS
import Data.X509.CertificateStore
import Debug.Trace

type SyncMap = STMMap.Map UUID (MVar (Either ConnectionError BinaryMessage), UTCTime)

-- | Represents a remote connection to server.
data Connection = Connection { _conn_sockContext :: SocketContext,
                               _conn_asyncThread :: Async (),
                               _conn_syncmap :: SyncMap
                             }

-- | Function handlers run on the client, triggered by the server- useful for asynchronous callbacks.
data ClientAsyncRequestHandler where
  ClientAsyncRequestHandler :: forall a. Serialise a => (a -> IO ()) -> ClientAsyncRequestHandler

type ClientAsyncRequestHandlers = [ClientAsyncRequestHandler]

-- | Connect to a remote server over IPv4. Wraps `connect`.
connectIPv4 ::
  ClientAsyncRequestHandlers ->
  ConnectionConfig ->
  HostAddressTuple ->
  PortNumber ->
  IO Connection
connectIPv4 asyncHandlers config hostaddr portnum =
  connect asyncHandlers config sockSpec sockAddr
  where
    sockSpec = SINS.SockSpec { sockFamily = AF_INET,
                               sockType = Stream,
                               sockProto = 0,
                               sockOpts = [] }
    sockAddr = SockAddrInet portnum (tupleToHostAddress hostaddr)

-- | Connect to a remote server over IPv6. Wraps `connect`.
connectIPv6 ::
  ClientAsyncRequestHandlers ->
  ConnectionConfig ->
  HostAddressTuple6 ->
  PortNumber ->
  IO Connection
connectIPv6 asyncHandlers config hostaddr portnum =
  connect asyncHandlers config sockSpec sockAddr  
  where
    sockSpec = SINS.SockSpec { sockFamily = AF_INET6,
                               sockType = Stream,
                               sockProto = 0,
                               sockOpts = [] }
    sockAddr = SockAddrInet6 portnum 0 (tupleToHostAddress6 hostaddr) 0

connectUnixDomain ::
  ClientAsyncRequestHandlers ->
  FilePath ->
  IO Connection
connectUnixDomain asyncHandlers socketPath =
  connect asyncHandlers UnencryptedConnectionConfig sockSpec sockAddr
  where
    sockSpec = SINS.SockSpec { sockFamily = AF_UNIX,
                               sockType = Stream,
                               sockProto = 0,
                               sockOpts = [] }
    sockAddr = SockAddrUnix socketPath

-- | Connects to a remote server with specific async callbacks registered.
connect :: 
  ClientAsyncRequestHandlers ->
  ConnectionConfig ->
  SINS.SockSpec ->
  SockAddr ->
  IO Connection
connect asyncHandlers config sockSpec sockAddr = do
  sock <- SINS.connect sockSpec sockAddr
  syncmap <- STMMap.newIO
  sockCtx <- setupClientSocket config sock  
  asyncThread <- async (clientAsync sockCtx syncmap asyncHandlers)

  print "client connect"
  pure (Connection {
           _conn_sockContext = sockCtx,
           _conn_asyncThread = asyncThread,
           _conn_syncmap = syncmap
           })

-- | Close the connection and release all connection resources.
close :: Connection -> IO ()
close conn = do
  withLock (lockingSocket (_conn_sockContext conn)) $ \sock ->
    Socket.close sock
  cancel (_conn_asyncThread conn)

-- | async thread for handling client-side incoming messages- dispatch to proper waiting thread or asynchronous notifications handler
clientAsync ::
  SocketContext ->
  SyncMap ->
  ClientAsyncRequestHandlers ->
  IO ()
clientAsync sockCtx syncmap asyncHandlers = do
  drainSocketMessages sockCtx (clientEnvelopeHandler asyncHandlers (lockingSocket sockCtx) syncmap)

consumeResponse :: UUID -> STMMap.Map UUID (MVar a, b) -> a -> IO ()
consumeResponse msgId syncMap val = do
  match <- atomically $ do
    val' <- STMMap.lookup msgId syncMap
    STMMap.delete msgId syncMap
    pure val'
  case match of
    Nothing -> pure () -- drop message
    Just (mVar, _) -> putMVar mVar val

-- | handles envelope responses from server- timeout from ths server is ignored, but perhaps that's proper for trusted servers- the server expects the client to process all async requests
clientEnvelopeHandler ::
  ClientAsyncRequestHandlers
  -> Locking Socket
  -> SyncMap
  -> Envelope
  -> IO ()
clientEnvelopeHandler handlers _ _ envelope@(Envelope _ (RequestMessage _) _ _) = do
  --should this run off on another green thread?
  let firstMatcher Nothing (ClientAsyncRequestHandler (dispatchf :: a -> IO ())) = do
        case openEnvelope envelope of
          Nothing -> pure Nothing
          Just decoded -> do
            dispatchf decoded
            pure (Just ())
      firstMatcher acc _ = pure acc
  foldM_ firstMatcher Nothing handlers
clientEnvelopeHandler _ _ syncMap (Envelope _ ResponseMessage msgId binaryMessage) =
  consumeResponse msgId syncMap (Right binaryMessage)
clientEnvelopeHandler _ _ syncMap (Envelope _ TimeoutResponseMessage msgId _) =
  consumeResponse msgId syncMap (Left TimeoutError)
clientEnvelopeHandler _ _ syncMap (Envelope _ ExceptionResponseMessage msgId excPayload) = 
  case msgDeserialise excPayload of
        Left err -> error ("failed to deserialise exception string" <> show err)
        Right excStr ->
          consumeResponse msgId syncMap (Left (ExceptionError excStr))
      
-- | Basic remote function call via data type and return value.
call :: (Serialise request, Serialise response) => Connection -> request -> IO (Either ConnectionError response)
call = callTimeout Nothing

-- | Send a request to the remote server and returns a response but with the possibility of a timeout after n microseconds.
callTimeout :: (Serialise request, Serialise response) => Maybe Int -> Connection -> request -> IO (Either ConnectionError response)
callTimeout mTimeout conn msg = do
  requestID <- UUID <$> UUIDBase.nextRandom  
  let mVarMap = _conn_syncmap conn
      timeoutms = case mTimeout of
        Nothing -> 0
        Just tm | tm < 0 -> 0
        Just tm -> fromIntegral tm
        
      envelope = Envelope fprint (RequestMessage timeoutms) requestID (msgSerialise msg)
      fprint = fingerprint msg
  -- setup mvar to wait for response
  responseMVar <- newEmptyMVar
  now <- getCurrentTime
  atomically $ STMMap.insert (responseMVar, now) requestID mVarMap
  sendEnvelope envelope (_conn_sockContext conn)
  let timeoutMicroseconds =
        case mTimeout of
          Just timeout' -> timeout' + 100 --add 100 ms to account for unknown network latency
          Nothing -> -1
  mResponse <- timeout timeoutMicroseconds (takeMVar responseMVar)
  atomically $ STMMap.delete requestID mVarMap
  case mResponse of
    --timeout
    Nothing ->
      pure (Left TimeoutError)
    Just (Left exc) ->
      pure (Left exc)
    Just (Right binmsg) ->
      case msgDeserialise binmsg of
        Left err -> error ("deserialise client error " <> show err)
        Right v -> pure (Right v)

-- | Call a remote function but do not expect a response from the server.
asyncCall :: Serialise request => Connection -> request -> IO (Either ConnectionError ())
asyncCall conn msg = do
  requestID <- UUID <$> UUIDBase.nextRandom
  let envelope = Envelope fprint (RequestMessage 0) requestID (msgSerialise msg)
      fprint = fingerprint msg
  sendEnvelope envelope (_conn_sockContext conn)
  pure (Right ())

setupClientSocket :: ConnectionConfig -> Socket -> IO SocketContext
setupClientSocket config sock = do
  sockLock <- newLock sock
  case config of
    UnencryptedConnectionConfig{} -> pure (UnencryptedSocketContext sockLock)
    EncryptedConnectionConfig tlsConfig -> do
      let pubKeyPath = x509PublicFilePath (tlsCertData tlsConfig)
          privKeyPath = x509PrivateFilePath (tlsCertData tlsConfig)
          serverHostTuple = (tlsServerHostName tlsConfig,
                             tlsServerServiceName tlsConfig)
          certPath = x509CertFilePath (tlsCertData tlsConfig)
      eCred <- credentialLoadX509 pubKeyPath privKeyPath
      case eCred of
        Left err -> error err
        Right cred -> do
          mCAStore <- readCertificateStore certPath
          case mCAStore of
            Nothing -> error ("failed to load certificate store at " <> certPath)
            Just caStore -> do
              tlsCtx <- STLS.clientHandshake sock serverHostTuple cred (Just caStore)
              traceShowM ("client handshake complete"::String)
              pure (EncryptedSocketContext sockLock tlsCtx)

  
