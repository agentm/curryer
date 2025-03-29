{-# LANGUAGE CPP #-}
module Network.RPC.Curryer.StreamlyAdditions where
import Control.Monad.IO.Class
import Network.Socket (Socket, SockAddr(..), maxListenQueue, withSocketsDo, socket, setSocketOption, bind, getSocketName)
import qualified Network.Socket as Net
import Control.Exception (onException)
import Control.Concurrent.MVar
import qualified Streamly.Internal.Data.Unfold as UF
import Streamly.Network.Socket hiding (acceptor)
import qualified Streamly.Internal.Data.Stream as D
import Streamly.Internal.Data.Unfold (Unfold(..))
import Control.Monad (when)
--import Streamly.Internal.Network.Socket as INS

acceptorOnSockSpec
    :: MonadIO m
    => SockSpec
    -> Maybe (MVar SockAddr)
    -> Unfold m SockAddr Socket
acceptorOnSockSpec sockSpec mLock = UF.lmap f (acceptor mLock)
    where
    f sockAddr' =
        (maxListenQueue
        , sockSpec
        , sockAddr'
        )

acceptor :: MonadIO m => Maybe (MVar SockAddr) -> Unfold m (Int, SockSpec, SockAddr) Socket
acceptor mLock = UF.map fst (listenTuples mLock)

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
          Just mvar -> putMVar mvar sockAddr
          Nothing -> pure ()
        pure sock

    step listener = do
        r <- liftIO (Net.accept listener `onException` Net.close listener)
        return $ D.Yield r listener

initListener :: Int -> SockSpec -> SockAddr -> IO Socket
initListener listenQLen sockSpec addr =
  withSocketsDo $ do
    sock <- socket (sockFamily sockSpec) (sockType sockSpec) (sockProto sockSpec)
    use sock `onException` Net.close sock
    return sock

    where

    use sock = do
        when (not (null (sockOpts sockSpec))) $ mapM_ (uncurry (setSocketOption sock)) (sockOpts sockSpec)
        bind sock addr
        Net.listen sock listenQLen
        
