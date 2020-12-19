{-# LANGUAGE DerivingStrategies, DeriveGeneric, DerivingVia #-}
import Network.RPC.Curryer.Server
import Network.RPC.Curryer.Client
import Criterion.Main
import GHC.Generics
import Control.Concurrent.MVar
import Network.Socket (SockAddr(..))
import Codec.Winery
import Control.Concurrent.Async
import Control.Concurrent
import Control.Monad
import qualified Data.ByteString as BS

main :: IO ()
main = do
  --start server shared across benchmarks- gather stats on round-trip requests-responses
  portReadyMVar <- newEmptyMVar
  server <- async (serve benchmarkServerRequestHandlers () localHostAddr 0 (Just portReadyMVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar portReadyMVar
  clientConn <- connect [] localHostAddr port

  _ <- syncWaitRequest clientConn 100
  let syncWait ms = nfIO (syncWaitRequest clientConn ms)
      syncByteString bs = nfIO (syncByteStringRequest clientConn bs)
      bs0 = BS.empty      
      bs100 = BS.pack (replicate 100 3)
      bs1000 = BS.pack (replicate 1000 3)
      bs1M = BS.pack (replicate 1000000 3)
  defaultMain [bgroup "wait sync" [bench "0 ms" (syncWait 0),
                                   bench "10 ms" (syncWait 10),
                                   bench "100 ms" (syncWait 100)],
                bgroup "bytestring roundtrip" [bench "0 bytes" (syncByteString bs0)
                                              ,bench "100 bytes" (syncByteString bs100)
                                              ,bench "1000 bytes" (syncByteString bs1000)
                                              ,bench "1000000 bytes" (syncByteString bs1M)
                                               ]]

    --TODO: bench for > PIPE_BUF bytes

  close clientConn 
  cancel server

data WaitMillisecondsReq = WaitMillisecondsReq Int --ask the server to respond in X milliseconds
  deriving (Generic, Show)
  deriving Serialise via WineryVariant WaitMillisecondsReq

data WaitByteStringReq = WaitByteStringReq BS.ByteString
  deriving (Generic, Show)
  deriving Serialise via WineryVariant WaitByteStringReq

data WaitMillisecondsResp = WaitMillisecondsResp
  deriving (Generic, Show, Eq)
  deriving Serialise via WineryVariant WaitMillisecondsResp

benchmarkServerRequestHandlers :: RequestHandlers a
benchmarkServerRequestHandlers =
  [RequestHandler $ \_ (WaitMillisecondsReq ms) -> do
      threadDelay (1000 * ms)
      pure WaitMillisecondsResp,
   RequestHandler $ \_ (WaitByteStringReq bs) ->
      pure bs
  ]

--perform 10000 small synchronous requests
syncWaitRequest :: Connection -> Int -> IO Int
syncWaitRequest conn ms = do
  ret <- call conn (WaitMillisecondsReq ms)
  when (ret /= Right WaitMillisecondsResp) (error "ret failed")
  pure ms

syncByteStringRequest :: Connection -> BS.ByteString -> IO BS.ByteString
syncByteStringRequest conn bs = do
  ret <- call conn (WaitByteStringReq bs)
  case ret of
    Right bs' -> pure bs'
    Left err -> error (show err)

