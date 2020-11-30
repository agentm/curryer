{-# LANGUAGE TypeApplications, RankNTypes, ScopedTypeVariables #-}
module Network.RPC.Curryer.Client where
import Network.RPC.Curryer.Server
import Network.Socket as Socket
import qualified Streamly.Network.Inet.TCP as TCP
import Codec.Winery
import Control.Concurrent.Async
import qualified Data.UUID.V4 as UUIDBase
import qualified StmContainers.Map as STMMap
import Control.Concurrent.MVar
import GHC.Conc
import Data.Time.Clock
import System.Timeout

type SyncMap = STMMap.Map UUID (MVar (Either ConnectionError BinaryMessage), UTCTime)

-- the request map holds
data Connection = Connection { _conn_sockLock :: Locking Socket,
                                    _conn_asyncThread :: Async (),
                                    _conn_syncmap :: SyncMap
                                  }

connect :: 
  --AsyncMessageHandler ->
           HostAddr ->
           PortNumber ->
           IO Connection
connect hostAddr portNum = do
  sock <- TCP.connect hostAddr portNum
  syncmap <- STMMap.newIO
  asyncThread <- async (clientAsync sock syncmap)
  sockLock <- newLock sock
  pure (Connection {
           _conn_sockLock = sockLock,
           _conn_asyncThread = asyncThread,
           _conn_syncmap = syncmap
           })

close :: Connection -> IO ()
close conn = do
  withLock (_conn_sockLock conn) $ \sock ->
    Socket.close sock
  cancel (_conn_asyncThread conn)

-- async thread for handling client-side incoming messages- dispatch to proper waiting thread or handler asynchronous notifications
clientAsync :: 
  Socket ->
  SyncMap ->
  --AsyncMessageHandler ->
  IO ()
clientAsync sock syncmap = do
  lsock <- newLock sock
  drainSocketMessages sock (clientEnvelopeHandler lsock syncmap)

--handles envelope responses from server
clientEnvelopeHandler ::
  Locking Socket
  -> SyncMap
  -> Envelope
  -> IO ()
clientEnvelopeHandler _ _ (Envelope _ RequestMessage _ _) = error "client received request"
clientEnvelopeHandler _ syncMap (Envelope _ ResponseMessage msgId binaryMessage) = do
  --find a matching response item
  match <- atomically $ do
    val' <- STMMap.lookup msgId syncMap
    STMMap.delete msgId syncMap
    pure val'
  case match of
    Nothing -> error ("dropping unrequested response " <> show msgId)
    Just (mVar, _) ->
        putMVar mVar (Right binaryMessage)
  

call :: (Serialise request, Serialise response) => Connection -> request -> IO (Either ConnectionError response)
call = callTimeout Nothing

-- | Send a request to the remote server and returns a response.
callTimeout :: (Serialise request, Serialise response) => Maybe Int -> Connection -> request -> IO (Either ConnectionError response)
callTimeout mTimeout conn msg = do
  requestID <- UUID <$> UUIDBase.nextRandom  
  let mVarMap = _conn_syncmap conn
      envelope = Envelope fprint RequestMessage requestID (serialise msg)
      fprint = fingerprint msg
  -- setup mvar to wait for response
  responseMVar <- newEmptyMVar
  now <- getCurrentTime
  atomically $ STMMap.insert (responseMVar, now) requestID mVarMap
  sendEnvelope envelope (_conn_sockLock conn)
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
    Just (Left exc) -> error ("exception in client from server: " <> show exc)
    Just (Right binmsg) ->
      --TODO use decoder instead
      case deserialise binmsg of
        Left err -> error ("deserialise client error " <> show err)
        Right m -> pure (Right m)
{-
asyncCall :: (Serialise request, Serialise response) => Connection response -> request -> IO (Either ConnectionError ())
asyncCall conn msg = do
  requestID <- UUID <$> UUIDBase.nextRandom
  sendMessage (AsyncRequest requestID msg) (_conn_sockLock conn)
  pure (Right ())
  
-}
