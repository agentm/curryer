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
import Data.Proxy

type SyncMap a = STMMap.Map UUID (MVar (Either ConnectionError a), UTCTime)
-- the request map holds
data Connection a = Connection { _conn_sock :: Socket,
                                 _conn_asyncThread :: Async (),
                                 _conn_syncmap :: SyncMap a
                               }

connect :: forall clientmsg. (Serialise clientmsg) =>
           AsyncMessageHandler clientmsg ->
           HostAddr ->
           PortNumber ->
           IO (Connection clientmsg)
connect notificationCallback hostAddr portNum = do
  sock <- TCP.connect hostAddr portNum
  syncmap <- STMMap.newIO
  let decoder :: Decoder (Message clientmsg)
      decoder = case getDecoder (schema (Proxy @(Message clientmsg))) of
        Left err -> error (show err)
        Right dec -> dec
  asyncThread <- async (clientAsync sock syncmap decoder notificationCallback)
  pure (Connection {
           _conn_sock = sock,
           _conn_asyncThread = asyncThread,
           _conn_syncmap = syncmap
           })

close :: Connection a -> IO ()
close conn = do
  Socket.close (_conn_sock conn)
  cancel (_conn_asyncThread conn)

-- async thread for handling client-side incoming messages- dispatch to proper waiting thread or handler asynchronous notifications
clientAsync :: forall b. Serialise b =>
  Socket ->
  SyncMap b ->
  Decoder (Message b) ->
  AsyncMessageHandler b ->
  IO ()
clientAsync sock syncmap decoder asyncHandler = do
  -- ping proper thread to continue
  let findRequest requestId =
        atomically $ do
          val' <- STMMap.lookup requestId syncmap
          STMMap.delete requestId syncmap
          pure val'        
  
  let responseHandler responseMsg = do
        --putStrLn "client-side message handler"
        case responseMsg of
          Response requestId val -> do
            varval <- findRequest requestId
            case varval of
              Nothing -> error "dumped unrequested response"
              Just (mVar,_) -> putMVar mVar (Right val)
          AsyncRequest _ asyncMsg ->
            asyncHandler asyncMsg
          ResponseExpectedRequest{} -> error "dumped response expected request"
          ExceptionResponse _ -> error "TODO Exception"
          TimedOutResponse requestId -> do
            varval <- findRequest requestId
            case varval of
              Nothing -> error "dumped unrequested timeout response"
              Just (mVar,_) -> putMVar mVar (Left TimeoutError)
  drainSocketMessages sock decoder responseHandler

call :: (Serialise request, Serialise response) => Connection response -> request -> IO (Either ConnectionError response)
call = callTimeout Nothing

-- | Send a request to the remote server and returns a response.
callTimeout :: (Serialise request, Serialise response) => Maybe Int -> Connection response -> request -> IO (Either ConnectionError response)
callTimeout mTimeout conn msg = do
  let mVarMap = _conn_syncmap conn
  requestID <- UUID <$> UUIDBase.nextRandom
  -- setup mvar to wait for response
  responseMVar <- newEmptyMVar
  now <- getCurrentTime
  atomically $ STMMap.insert (responseMVar, now) requestID mVarMap
  sendMessage (ResponseExpectedRequest requestID mTimeout msg) (_conn_sock conn)
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
    Just res -> pure res

asyncCall :: (Serialise request, Serialise response) => Connection response -> request -> IO (Either ConnectionError ())
asyncCall conn msg = do
  requestID <- UUID <$> UUIDBase.nextRandom
  sendMessage (AsyncRequest requestID msg) (_conn_sock conn)
  pure (Right ())
  
