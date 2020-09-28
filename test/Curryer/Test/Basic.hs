{-# LANGUAGE DerivingVia, DeriveGeneric, TypeApplications #-}
module Curryer.Test.Basic where
import Test.Tasty
import Test.Tasty.HUnit
import Codec.Winery
import GHC.Generics
import Control.Concurrent.MVar
import Network.Socket (SockAddr(..))
import Control.Concurrent.Async

import Network.RPC.Curryer.Server
import Network.RPC.Curryer.Client

testTree :: TestTree
testTree = testGroup "basic" [--testCase "simple" testSimpleCall,
                              testCase "client async" testAsyncServerCall
                             ]

--client-to-server request
data TestRequest = AddTwoNumbersReq Int Int
  deriving (Generic, Show)
  deriving Serialise via WineryVariant TestRequest

--server responds to client
data TestResponse = AddTwoNumbersResp Int
                  | AsyncHello String
  deriving (Generic, Show, Eq)
  deriving Serialise via WineryVariant TestResponse

testServerMessageHandler :: TestRequest -> IO (HandlerResponse TestResponse)
testServerMessageHandler msg = do
  --print msg        
  case msg of
      AddTwoNumbersReq x y -> pure (HandlerResponse (AddTwoNumbersResp (x+y)))
      
-- test a simple client-to-server round-trip function execution
testSimpleCall :: Assertion
testSimpleCall = do
  readyVar <- newEmptyMVar
        
  server <- async (serve (pure Nothing) testServerMessageHandler localHostAddr 0 (Just readyVar))
  --wait for server to be ready
--  putStrLn "waiting for server"
  sock@(SockAddrInet port _) <- takeMVar readyVar
--  putStrLn $ "server ready: " ++ show sock
  let clientHandler :: AsyncMessageHandler TestResponse
      clientHandler _ = error "async handler called"
      mkConn :: IO (Connection TestResponse)
      mkConn = connect clientHandler localHostAddr port
  conn <- mkConn
--  putStrLn "connect complete"
  let c :: IO (Either ConnectionError TestResponse)
      c = call conn (AddTwoNumbersReq 1 1)
  x <- c 
--  putStrLn "call complete"
  assertEqual "server request+response" (Right (AddTwoNumbersResp 2)) x
--  print x
  close conn

--test that the client can proces a server-initiated asynchronous callback from the server
testAsyncServerCall :: Assertion
testAsyncServerCall = do
  portReadyVar <- newEmptyMVar
  receivedAsyncMessageVar <- newEmptyMVar
  
  let testServerNewConnHandler :: NewConnectionHandler TestResponse
      testServerNewConnHandler = do
        pure (Just (AsyncHello "welcome"))
        
  server <- async (serve testServerNewConnHandler testServerMessageHandler localHostAddr 0 (Just portReadyVar))
  (SockAddrInet port _) <- takeMVar portReadyVar
  let clientHandler :: AsyncMessageHandler TestResponse
      clientHandler msg = do
        case msg of
          AsyncHello str -> putMVar receivedAsyncMessageVar str
          x -> error ("unexpected message " <> show x)
  conn <- connect @TestResponse clientHandler localHostAddr port  
  asyncMessage <- takeMVar receivedAsyncMessageVar
  assertEqual "async message" "welcome" asyncMessage
  close conn

--test that the client can make a non-blocking call
--testAsyncClientCall :: Assertion

