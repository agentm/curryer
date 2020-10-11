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

type SyncMap a = STMMap.Map UUID (MVar a, UTCTime)
-- the request map holds
data Connection a = Connection Socket (Async ()) (SyncMap a)

connect :: (Serialise msg) =>
           AsyncMessageHandler msg ->
           HostAddr ->
           PortNumber ->
           IO (Connection msg)
connect notificationCallback hostAddr portNum = do
  sock <- TCP.connect hostAddr portNum
  syncmap <- STMMap.newIO
  asyncThread <- async (clientAsync sock syncmap notificationCallback)
  pure (Connection sock asyncThread syncmap)

close :: Connection a -> IO ()
close (Connection sock asyncThread _) = do
  Socket.close sock
  cancel asyncThread

-- async thread for handling client-side incoming messages- dispatch to proper waiting thread or handler asynchronous notifications
clientAsync :: Serialise b =>
  Socket ->
  SyncMap b ->
  AsyncMessageHandler b ->
  IO ()
clientAsync sock syncmap asyncHandler = do
  -- ping proper thread to continue
  let responseHandler responseMsg = do
        putStrLn "client-side message handler"
        case responseMsg of
          Response requestId val -> do
            varval <- atomically $ do
              val' <- STMMap.lookup requestId syncmap
              STMMap.delete requestId syncmap
              pure val'
            case varval of
              Nothing -> error "dumped unrequested response"
              Just (mVar,_) -> putMVar mVar val
          AsyncRequest _ asyncMsg ->
            asyncHandler asyncMsg
          ResponseExpectedRequest _ _ -> error "dumped response expected request"
          ExceptionResponse _ -> error "TODO Exception"
  drainSocketMessages sock responseHandler

call :: (Serialise request, Serialise response) => Connection response -> request -> IO (Either ConnectionError response)
call = callTimeout Nothing

-- | Send a request to the remote server and returns a response.
callTimeout :: (Serialise request, Serialise response) => Maybe Int -> Connection response -> request -> IO (Either ConnectionError response)
callTimeout mTimeout (Connection sock _ mVarMap) msg = do
  requestID <- UUID <$> UUIDBase.nextRandom
  -- setup mvar to wait for response
  responseMVar <- newEmptyMVar
  now <- getCurrentTime
  atomically $ STMMap.insert (responseMVar, now) requestID mVarMap
  sendMessage (ResponseExpectedRequest requestID msg) sock
  let timeoutMicroseconds =
        case mTimeout of
          Just timeout' -> timeout'
          Nothing -> -1
  mResponse <- timeout timeoutMicroseconds (takeMVar responseMVar)
  atomically $ STMMap.delete requestID mVarMap
  case mResponse of
    --timeout
    Nothing -> do
      pure (Left TimeoutError)
    Just response -> pure (Right response)

asyncCall :: (Serialise request, Serialise response) => Connection response -> request -> IO (Either ConnectionError ())
asyncCall (Connection sock _ _) msg = do
  requestID <- UUID <$> UUIDBase.nextRandom
  sendMessage (AsyncRequest requestID msg) sock
  pure (Right ())
  
