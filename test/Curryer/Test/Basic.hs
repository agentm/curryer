{-# LANGUAGE DerivingVia, DeriveGeneric, TypeApplications, ExistentialQuantification, ScopedTypeVariables #-}
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
import Control.Concurrent.STM
import Control.Exception
import Data.List
import Data.Text (Text, pack)

import Network.RPC.Curryer.Server as S
import Network.RPC.Curryer.Client as C

-- TODO: add test for nested calls

testTree :: TestTree
testTree = testGroup "basic" [
  testCase "simple request and response" testSimpleCall
  ,testCase "complex ADT" testComplexADT
  ,testCase "client async" testAsyncServerCall
  ,testCase "server async" testAsyncClientCall
  ,testCase "client sync timeout" testSyncClientCallTimeout
  ,testCase "server-side exception" testSyncException
  ,testCase "multi-threaded client" testMultithreadedClient
  ,testCase "server state" testServerState
  ,testCase "request handler throws timeout" testRequestHandlerThrowTimeout
  ,testCase "ipv6 server" testIPv6Server
  ,testCase "unix domain socket server" testUnixDomainSocketServer
  ]


data AddTwoNumbersReq = AddTwoNumbersReq Int Int
  deriving (Generic, Show)
  deriving Serialise via WineryVariant AddTwoNumbersReq

data TestCallMeBackReq = TestCallMeBackReq String
  deriving (Generic, Show, Eq)
  deriving Serialise via WineryVariant TestCallMeBackReq

data TestAsyncReq = TestAsyncReq String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant TestAsyncReq

data DelayMicrosecondsReq = DelayMicrosecondsReq Int
  deriving (Generic, Show)
  deriving Serialise via WineryVariant DelayMicrosecondsReq

data RoundtripStringReq = RoundtripStringReq String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant RoundtripStringReq

data ThrowServerSideExceptionReq = ThrowServerSideExceptionReq
  deriving (Generic, Show)
  deriving Serialise via WineryVariant ThrowServerSideExceptionReq

data ChangeServerState = ChangeServerState
  deriving (Generic, Show)
  deriving Serialise via WineryVariant ChangeServerState

--used to server -> client async request
data AsyncHelloReq = AsyncHelloReq String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant AsyncHelloReq

data ThrowTimeout = ThrowTimeout
  deriving (Generic, Show)
  deriving Serialise via WineryVariant ThrowTimeout

data RoundtripSomeADTReq = RoundtripSomeADTReq SomeADT
  deriving (Generic, Show)
  deriving Serialise via WineryVariant RoundtripSomeADTReq

testServerRequestHandlers :: Maybe (MVar String) -> RequestHandlers ()
testServerRequestHandlers mAsyncMVar =
    [ RequestHandler $ \_ (AddTwoNumbersReq x y) -> pure (x + y)
    , RequestHandler $ \_ (TestCallMeBackReq s) ->
                         case mAsyncMVar of
                           Nothing -> pure ()
                           Just mvar -> putMVar mvar s
    , AsyncRequestHandler $ \_ (TestAsyncReq v) ->
        maybe (pure ()) (\mvar -> putMVar mvar v) mAsyncMVar
    -- an async hello to the server generates an async hello to the client        
    , AsyncRequestHandler $ \sState (AsyncHelloReq s) -> do
        sendMessage (connectionSocketContext sState) (AsyncHelloReq s)
        
    , RequestHandler $ \_ (RoundtripStringReq s) -> pure s
    , RequestHandler $ \_ (DelayMicrosecondsReq ms) -> do
        threadDelay ms
        pure ()
    , RequestHandler $ \_ ThrowServerSideExceptionReq -> do
        _ <- error "test server exception"
        pure ()
    , RequestHandler $ \_ (RoundtripSomeADTReq s) -> pure s
               ]
      
-- test a simple client-to-server round-trip function execution
testSimpleCall :: Assertion
testSimpleCall = do
  readyVar <- newEmptyMVar
        
  server <- async (serveIPv4 (testServerRequestHandlers Nothing) emptyServerState S.UnencryptedConnectionConfig localHostAddr 0 (Just readyVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar readyVar
  conn <- connectIPv4 [] C.UnencryptedConnectionConfig localHostAddr port
  replicateM_ 5 $ do --make five AddTwo calls to shake out parallelism bugs
    x <- call conn (AddTwoNumbersReq 1 1)
    assertEqual "server request+response" (Right (2 :: Int)) x
  close conn
  cancel server


--test that the client can proces a server-initiated asynchronous callback from the server
testAsyncServerCall :: Assertion
testAsyncServerCall = do
  portReadyVar <- newEmptyMVar
  receivedAsyncMessageVar <- newEmptyMVar
  let clientAsyncHandlers =
        [ClientAsyncRequestHandler (\(AsyncHelloReq s) ->
                                        putMVar receivedAsyncMessageVar s)]
  server <- async (serveIPv4 (testServerRequestHandlers (Just receivedAsyncMessageVar)) emptyServerState S.UnencryptedConnectionConfig localHostAddr 0 (Just portReadyVar))
  (SockAddrInet port _) <- takeMVar portReadyVar
  conn <- connectIPv4 clientAsyncHandlers C.UnencryptedConnectionConfig localHostAddr port
  Right () <- asyncCall conn (AsyncHelloReq "welcome")
  asyncMessage <- takeMVar receivedAsyncMessageVar
  assertEqual "async message" "welcome" asyncMessage
  close conn
  cancel server


emptyServerState :: ()
emptyServerState = ()

--test that the client can make a non-blocking call
testAsyncClientCall :: Assertion
testAsyncClientCall = do
  portReadyVar <- newEmptyMVar
  receivedAsyncMessageVar <- newEmptyMVar
  
  server <- async (serveIPv4 (testServerRequestHandlers (Just receivedAsyncMessageVar)) emptyServerState S.UnencryptedConnectionConfig localHostAddr 0 (Just portReadyVar))
  (SockAddrInet port _) <- takeMVar portReadyVar

  conn <- connectIPv4 [] C.UnencryptedConnectionConfig localHostAddr port
  --send an async message, wait for an async response to confirm receipt
  Right () <- asyncCall conn (TestCallMeBackReq "hi server")
  asyncMessage <- takeMVar receivedAsyncMessageVar
  assertEqual "async message" "hi server" asyncMessage  
  close conn
  cancel server

testSyncClientCallTimeout :: Assertion
testSyncClientCallTimeout = do
  readyVar <- newEmptyMVar
        
  server <- async (serveIPv4 (testServerRequestHandlers Nothing) emptyServerState S.UnencryptedConnectionConfig localHostAddr 0 (Just readyVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar readyVar
  conn <- connectIPv4 [] C.UnencryptedConnectionConfig localHostAddr port
  x <- callTimeout @_ @Int (Just 500) conn (DelayMicrosecondsReq 1000)
  assertEqual "client sync timeout" (Left TimeoutError) x
  close conn
  cancel server

testSyncException :: Assertion
testSyncException = do
  readyVar <- newEmptyMVar
        
  server <- async (serveIPv4 (testServerRequestHandlers Nothing) emptyServerState S.UnencryptedConnectionConfig localHostAddr 0 (Just readyVar))
  (SockAddrInet port _) <- takeMVar readyVar

  conn <- connectIPv4 [] C.UnencryptedConnectionConfig localHostAddr port
  ret <- call conn ThrowServerSideExceptionReq
  case ret of
    Left (ExceptionError actualExc) ->
      assertBool "server-side exception" ("test server exception" `isPrefixOf` actualExc)
    Left otherErr ->
      assertFailure ("server-side error " <> show otherErr)
    Right () -> assertFailure "missed exception"
  close conn
  cancel server

--throw large messages (> PIPE_BUF) at the server from multiple client connections to exercise the socket lock
testMultithreadedClient :: Assertion
testMultithreadedClient = do
  readyVar <- newEmptyMVar
        
  server <- async (serveIPv4 (testServerRequestHandlers Nothing) emptyServerState S.UnencryptedConnectionConfig localHostAddr 0 (Just readyVar))
  (SockAddrInet port _) <- takeMVar readyVar
  conn <- connectIPv4 [] C.UnencryptedConnectionConfig localHostAddr port
  let bigString = replicate (1024 * 1000) 'x'
  replicateM_ 10 $ do
    ret <- call conn (RoundtripStringReq bigString)
    assertEqual "big string multithread" (Right bigString) ret
    --putStrLn "plus one"
  close conn
  cancel server

testServerState :: Assertion
testServerState = do
  readyVar <- newEmptyMVar

  let serverHandlers = [RequestHandler (\sState ChangeServerState -> 
                                           atomically $
                                             modifyTVar (connectionServerState sState) (+ 1))
                                             ]
  serverState <- newTVarIO @Int 1
  server <- async (serveIPv4 serverHandlers serverState S.UnencryptedConnectionConfig localHostAddr 0 (Just readyVar))
  (SockAddrInet port _) <- takeMVar readyVar
  conn <- connectIPv4 [] C.UnencryptedConnectionConfig localHostAddr port
  ret <- call conn ChangeServerState
  assertEqual "server ret" (Right ()) ret
  serverState' <- readTVarIO serverState
  assertEqual "server state" 2 serverState'
  close conn
  cancel server

--test that the request handler can throw a TimeoutError exception which is converted into a TimeoutError response
testRequestHandlerThrowTimeout :: Assertion
testRequestHandlerThrowTimeout = do
  readyVar <- newEmptyMVar

  let serverHandlers = [RequestHandler (\_ ThrowTimeout ->
                                          throw TimeoutException >> pure (1 :: Int)
                                          )
                                             ]
  server <- async (serveIPv4 serverHandlers () S.UnencryptedConnectionConfig localHostAddr 0 (Just readyVar))
  (SockAddrInet port _) <- takeMVar readyVar
  conn <- connectIPv4 [] C.UnencryptedConnectionConfig localHostAddr port
  ret <- call @_ @Int conn ThrowTimeout
  assertEqual "handler timeout exception" (Left TimeoutError) ret
  close conn
  cancel server

data SomeADT = SomeTextCon Text SomeADT
             | SomeIntCon Integer SomeADT
             | EndCon
  deriving (Generic, Show, Eq)
  deriving Serialise via WineryVariant SomeADT

testComplexADT :: Assertion
testComplexADT = do
  let arg = SomeTextCon (pack "sduofhsldkfsldkfjsldkfjsdlkfjsdlfksdjlfksjdflksdjflksdjfjlsdjlfjdklskfjlsdlfk") (SomeIntCon 0 (EndCon))
  readyVar <- newEmptyMVar
  server <- async (serveIPv4 (testServerRequestHandlers Nothing) emptyServerState S.UnencryptedConnectionConfig localHostAddr 0 (Just readyVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar readyVar
  conn <- connectIPv4 [] C.UnencryptedConnectionConfig localHostAddr port
  replicateM_ 5 $ do --make five AddTwo calls to shake out parallelism bugs
    res <- call conn (RoundtripSomeADTReq arg)
    assertEqual "complex ADT" (Right arg) res
  close conn
  cancel server

testIPv6Server :: Assertion
testIPv6Server = do
  readyVar <- newEmptyMVar
        
  server <- async (serveIPv6 (testServerRequestHandlers Nothing) emptyServerState S.UnencryptedConnectionConfig localHostAddr6 0 (Just readyVar))
  --wait for server to be ready
  (SockAddrInet6 port _ _ _) <- takeMVar readyVar
  conn <- connectIPv6 [] C.UnencryptedConnectionConfig localHostAddr6 port
  replicateM_ 5 $ do --make five AddTwo calls to shake out parallelism bugs
    x <- call conn (AddTwoNumbersReq 1 1)
    assertEqual "server request+response" (Right (2 :: Int)) x
  close conn
  cancel server
  
testUnixDomainSocketServer :: Assertion
testUnixDomainSocketServer = do
  readyVar <- newEmptyMVar
  let socketPath = "/tmp/curryertest.sock"
  server <- async (serveUnixDomain (testServerRequestHandlers Nothing) emptyServerState socketPath (Just readyVar))

  --wait for server to be ready
  (SockAddrUnix socketPath') <- takeMVar readyVar
  conn <- connectUnixDomain [] socketPath'
  replicateM_ 5 $ do --make five AddTwo calls to shake out parallelism bugs
    x <- call conn (AddTwoNumbersReq 1 1)
    assertEqual "server request+response" (Right (2 :: Int)) x
  close conn
  cancel server
  
