{-# LANGUAGE DerivingVia, DeriveGeneric, TypeApplications #-}
module Curryer.Test.Basic where
import Test.Tasty
import Test.Tasty.HUnit
import Codec.Winery
import GHC.Generics
import Control.Concurrent.MVar
import Network.Socket (SockAddr(..))
import Control.Concurrent.Async
import Control.Monad
import Control.Concurrent
import Data.List

import Network.RPC.Curryer.Server
import Network.RPC.Curryer.Client

import Debug.Trace

-- TODO: add test for nested calls

testTree :: TestTree
testTree = testGroup "basic" [testCase "simple" testSimpleCall
                              {-testCase "client async" testAsyncServerCall,
                              testCase "server async" testAsyncClientCall,
                              testCase "client sync timeout" testSyncClientCallTimeout,
                              testCase "server-side exception" testSyncException,
                              testCase "multi-threaded client" testMultithreadedClient-}
                             ]

--client-to-server request
data TestRequest = AddTwoNumbersReq Int Int
                 | TestAsyncReq String
                 | TestCallMeBackReq String
                 | RoundtripStringReq String
                 | DelayMicrosecondsReq Int
                 | ThrowServerSideExceptionReq
  deriving (Generic, Show)
  deriving Serialise via WineryVariant TestRequest

--server responds to client
data TestResponse = AddTwoNumbersResp Int
                  | AsyncHello String
                  | DelayMicrosecondsResp
                  | RoundtripStringResp String
  deriving (Generic, Show, Eq)
  deriving Serialise via WineryVariant TestResponse

testServerMessageHandlers :: Maybe (MVar String) -> MessageHandlers
testServerMessageHandlers mAsyncMVar =
  MessageHandlers [\(AddTwoNumbersReq x y) ->
                      pure (AddTwoNumbersResp (x + y))]
{-  --print msg        
  case msg of
      --round-trip request to add two Ints
      AddTwoNumbersReq x y -> pure (AddTwoNumbersResp (x+y))
      --respond to a request for an async callback
      TestCallMeBackReq s -> do
        case mAsyncMVar of
          Nothing -> pure ()
          Just mvar -> putMVar mvar s
        pure NoResponse
      TestAsyncReq _ -> pure NoResponse
      RoundtripStringReq s -> pure (RoundtripStringResp s)
      DelayMicrosecondsReq ms -> do
        threadDelay ms
        pure (HandlerResponse DelayMicrosecondsResp)
      ThrowServerSideExceptionReq -> error "test server exception"
-}      
-- test a simple client-to-server round-trip function execution
testSimpleCall :: Assertion
testSimpleCall = do
  readyVar <- newEmptyMVar
        
  server <- async (serve (testServerMessageHandlers Nothing) localHostAddr 0 (Just readyVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar readyVar
  let clientHandler :: AsyncMessageHandler TestResponse
      clientHandler _ = error "async handler called"
      mkConn :: IO Connection
      mkConn = connect localHostAddr port
  conn <- mkConn
  let c :: IO (Either ConnectionError TestResponse)
      c = call conn (AddTwoNumbersReq 1 1)
  replicateM_ 5 $ do --make five AddTwo calls to shake out parallelism bugs
    x <- c 
    assertEqual "server request+response" (Right (AddTwoNumbersResp 2)) x
  close conn
  cancel server

{-
--test that the client can proces a server-initiated asynchronous callback from the server
testAsyncServerCall :: Assertion
testAsyncServerCall = do
  portReadyVar <- newEmptyMVar
  receivedAsyncMessageVar <- newEmptyMVar
  
  let testServerNewConnHandler :: NewConnectionHandler TestResponse
      testServerNewConnHandler =
        pure (Just (AsyncHello "welcome"))
        
  server <- async (serve testServerNewConnHandler (testServerMessageHandler Nothing) localHostAddr 0 (Just portReadyVar))
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
  cancel server

--test that the client can make a non-blocking call
testAsyncClientCall :: Assertion
testAsyncClientCall = do
  portReadyVar <- newEmptyMVar
  receivedAsyncMessageVar <- newEmptyMVar
  
  server <- async (serve (pure Nothing) (testServerMessageHandler (Just receivedAsyncMessageVar)) localHostAddr 0 (Just portReadyVar))
  (SockAddrInet port _) <- takeMVar portReadyVar
  
  conn <- connect @TestResponse (\_ -> pure ()) localHostAddr port
  --send an async message, wait for an async response to confirm receipt
  Right () <- asyncCall conn (TestCallMeBackReq "hi server")
  asyncMessage <- takeMVar receivedAsyncMessageVar
  assertEqual "async message" "hi server" asyncMessage  
  close conn
  cancel server

testSyncClientCallTimeout :: Assertion
testSyncClientCallTimeout = do
  readyVar <- newEmptyMVar
        
  server <- async (serve (pure Nothing) (testServerMessageHandler Nothing) localHostAddr 0 (Just readyVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar readyVar
  let clientHandler :: AsyncMessageHandler TestResponse
      clientHandler _ = error "async handler called"
      mkConn :: IO (Connection TestResponse)
      mkConn = connect clientHandler localHostAddr port
  conn <- mkConn
  let c :: IO (Either ConnectionError TestResponse)
      c = callTimeout (Just 500) conn (DelayMicrosecondsReq 1000)
  x <- c
  assertEqual "client sync timeout" (Left TimeoutError) x
  close conn
  cancel server
  
testSyncException :: Assertion
testSyncException = do
  readyVar <- newEmptyMVar
        
  server <- async (serve (pure Nothing) (testServerMessageHandler Nothing) localHostAddr 0 (Just readyVar))
  (SockAddrInet port _) <- takeMVar readyVar
  let clientHandler :: AsyncMessageHandler TestResponse
      clientHandler _ = error "async handler called"
      mkConn :: IO (Connection TestResponse)
      mkConn = connect clientHandler localHostAddr port
  conn <- mkConn
  ret <- call conn ThrowServerSideExceptionReq
  case ret of
    Left (ExceptionError actualExc) ->
      assertBool "server-side exception" ("test server exception" `isPrefixOf` actualExc)
    Right _ -> assertFailure "missed exception"
  close conn
  cancel server

--throw large messages (> PIPE_BUF) at the server from multiple client connections to exercise the socket lock
testMultithreadedClient :: Assertion
testMultithreadedClient = do
  readyVar <- newEmptyMVar
        
  server <- async (serve (pure Nothing) (testServerMessageHandler Nothing) localHostAddr 0 (Just readyVar))
  (SockAddrInet port _) <- takeMVar readyVar
  let clientHandler :: AsyncMessageHandler TestResponse
      clientHandler _ = error "async handler called"
      mkConn :: IO (Connection TestResponse)
      mkConn = connect clientHandler localHostAddr port
  conn <- mkConn
  let bigString = replicate (1024 * 1000) 'x'
  replicateM_ 10 $ do
    ret <- call conn (RoundtripStringReq bigString)
    assertEqual "big string multithread" (Right (RoundtripStringResp bigString)) ret
    putStrLn "plus one"
  close conn
  cancel server
    
-}
