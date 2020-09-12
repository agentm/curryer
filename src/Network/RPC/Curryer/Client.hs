module Network.RPC.Curryer.Client where
import Streamly.Prelude
import Network.RPC.Vintner.Server
import Streamly.Network.Socket
import Network.Socket as Socket
import qualified Streamly.Network.Inet.TCP as TCP
import Codec.Winery
import Control.Concurrent.Async

-- | client-side functions
data Connection = Connection Socket (Async ())

connect :: Serialise a => MessageHandler a -> HostAddr -> PortNumber -> IO Connection
connect notificationCallback hostAddr portNum = do
  sock <- TCP.connect hostAddr portNum
  asyncThread <- async (clientAsync sock notificationCallback)
  pure (Connection sock asyncThread)

close :: Connection -> IO ()
close (Connection sock asyncThread) = do
  Socket.close sock
  cancel asyncThread

-- async thread for handling incoming messages
clientAsync :: Serialise a => Socket -> MessageHandler a -> IO ()
clientAsync sock msgHandler = do
 drainSocketMessages sock msgHandler


