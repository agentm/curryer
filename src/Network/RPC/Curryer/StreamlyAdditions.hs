module Network.RPC.Curryer.StreamlyAdditions where
import Control.Monad.IO.Class
import Network.Socket (Socket, PortNumber, SocketOption, SockAddr(..), maxListenQueue, Family(..), SocketType(..), defaultProtocol, tupleToHostAddress, withSocketsDo, socket, setSocketOption, bind, getSocketName)
import qualified Network.Socket as Net
import Control.Exception (onException)
import Control.Monad.Catch (finally)
import Control.Concurrent.MVar
import Data.Word
import qualified Streamly.Internal.Data.Unfold as UF
import Streamly.Network.Socket hiding (accept)
import qualified Streamly.Internal.Data.Stream.StreamD.Type as D
import Streamly.Internal.Data.Unfold.Type (Unfold(..))

acceptOnAddrWith
    :: MonadIO m
    => [(SocketOption, Int)]
    -> Maybe (MVar SockAddr)
    -> Unfold m ((Word8, Word8, Word8, Word8), PortNumber) Socket
acceptOnAddrWith opts mSockLock = UF.lmap f (accept mSockLock)
    where
    f (addr, port) =
        (maxListenQueue
        , SockSpec
            { sockFamily = AF_INET
            , sockType = Stream
            , sockProto = defaultProtocol -- TCP
            , sockOpts = opts
            }
        , SockAddrInet port (tupleToHostAddress addr)
        )

accept :: MonadIO m => Maybe (MVar SockAddr) -> Unfold m (Int, SockSpec, SockAddr) Socket
accept mSockLock = UF.map fst (listenTuples mSockLock)

initListener :: Int -> SockSpec -> SockAddr -> IO Socket
initListener listenQLen sockSpec addr =
  withSocketsDo $ do
    sock <- socket (sockFamily sockSpec) (sockType sockSpec) (sockProto sockSpec)
    use sock `onException` Net.close sock
    return sock

    where

    use sock = do
        mapM_ (uncurry (setSocketOption sock)) (sockOpts sockSpec)
        bind sock addr
        Net.listen sock listenQLen        

listenTuples :: MonadIO m
    => Maybe (MVar SockAddr)
    -> Unfold m (Int, SockSpec, SockAddr) (Socket, SockAddr)
listenTuples mSockLock = Unfold step inject
 where
    inject (listenQLen, spec, addr) =
      liftIO $ do
        sock <- initListener listenQLen spec addr
        sockAddr <- getSocketName sock
        case mSockLock of
          Just mvar ->
            putMVar mvar sockAddr
          Nothing -> pure ()
        pure sock

    step listener = do
        r <- liftIO (Net.accept listener `onException` Net.close listener)
        return $ D.Yield r listener

handleWithM :: (Socket -> IO ()) -> Socket -> IO ()
handleWithM f sk = finally (f sk) (Net.close sk)
