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

main :: IO ()
main = do
  --start server shared across benchmarks- gather stats on round-trip requests-responses
  portReadyMVar <- newEmptyMVar
  server <- async (serve (pure Nothing) benchmarkServerMessageHandler localHostAddr 0 (Just portReadyMVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar portReadyMVar
  clientConn <- connect (const (pure ())) localHostAddr port

  _ <- syncWaitRequest clientConn 100
  defaultMain [bgroup "wait sync" [bench "100 ms" (nfIO $ syncWaitRequest clientConn 100)]]

  putStrLn "benchmark complete"
  close clientConn 
  cancel server

data BenchRequest = WaitMillisecondsReq Int
  deriving (Generic, Show)
  deriving Serialise via WineryVariant BenchRequest

data BenchResponse = WaitMillisecondsResp
  deriving (Generic, Show, Eq)
  deriving Serialise via WineryVariant BenchResponse

benchmarkServerMessageHandler :: BenchRequest -> IO (HandlerResponse BenchResponse)
benchmarkServerMessageHandler (WaitMillisecondsReq ms) = do
  threadDelay (1000 * ms)
  pure (HandlerResponse WaitMillisecondsResp)

--perform 10000 small synchronous requests
syncWaitRequest :: Connection BenchResponse -> Int -> IO Int
syncWaitRequest conn ms = do
  ret <- call conn (WaitMillisecondsReq ms)
  when (ret /= Right WaitMillisecondsResp) (error "ret failed")
  pure ms

