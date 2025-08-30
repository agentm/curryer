{-# LANGUAGE DerivingStrategies, DerivingVia, DeriveGeneric #-}
module Curryer.Test.TLS where
import Test.Tasty
import Test.Tasty.HUnit
import Codec.Winery
import GHC.Generics
import Control.Concurrent.MVar
import Network.Socket (SockAddr(..))
import Control.Concurrent.Async
import Control.Monad
--import Control.Concurrent
--import Control.Concurrent.STM

import Network.RPC.Curryer.Server as S
import Network.RPC.Curryer.Client as C

{- Setup in test/Curryer/Test/:
mkdir ca ca/certs ca/private ca/newcerts client_certs server
echo 01 > ca/serial
touch ca/index.txt
cp /usr/lib/ssl/openssl.cnf .
#modify openssl.cnf
dir = /root/mtls
new_certs_dir = $dir/certs
certificate = $dir/certs/cacert.pem
countryName_default
stateOrProvinceName_default
localityName_default
0.organizationName_default
organizationalUnitName_default
# back to shell
# Generate the private key for the CA certificate
openssl genrsa -out ca/private/cakey.pem 4096
# Create the CA certificate
openssl req -new -x509 -days 3650 -config openssl.cnf -key ca/private/cakey.pem -out ca/certs/cacert.pem
# Generate the private key for the client.
openssl genrsa -out client_certs/client.key.pem 4096
# Generating a Certificate Signing Request (CSR) for the Client
# Remember to revise the Common Name (CN) to match the client's hostname, e.g., "client.yourdomain.com."
openssl req -new -key client_certs/client.key.pem -out ca/client.csr
# Creating the Client Certificate
openssl ca -config openssl.cnf -days 1650 -notext -batch -in ca/client.csr -out client_certs/client.cert.pem
# Generate the private key for the server
openssl genrsa -out server/server.key.pem 4096
# Generating a Certificate Signing Request (CSR) for the Server.
# Remember to revise the Common Name (CN) to match the server's hostname, e.g., "server.yourdomain.com."
openssl req -new -key server/server.key.pem -out server/server.csr
# Creating the Server Certificate
openssl ca -config openssl.cnf -days 1650 -notext -batch -in server/server.csr -out server.cert.pem

#validate tls connection
#open server tls socket
openssl s_server -accept 3000 -CAfile ca/certs/cacert.pem -cert server_certs/server.cert.pem -key /root/server_certs/server.key.pem -state
#connect client tls socket
openssl s_client -connect 127.0.0.1:3000 -key client_certs/client.key.pem -cert client_certs/client.cert.pem -CAfile ca/certs/cacert.pem -state

-}

testTree :: TestTree
testTree = testGroup "tls" [
  testCase "simple request and response" testSimpleCall,
  testCase "mutual TLS" testMutualTLS--,
--  testCase "test rejected anonymous client" testRejectedAnonymousClient
  ]

-- TODO test should create its own self-signed CA, keys, and certs

data AddTwoNumbersReq = AddTwoNumbersReq Int Int
  deriving (Generic, Show)
  deriving Serialise via WineryVariant AddTwoNumbersReq

data GetRoleName = GetRoleName
  deriving (Generic, Show)
  deriving Serialise via WineryVariant GetRoleName

testServerRequestHandlers :: Maybe (MVar String) -> RequestHandlers ()
testServerRequestHandlers _mAsyncMVar =
    [ RequestHandler $ \_ (AddTwoNumbersReq x y) -> pure (x + y),
      RequestHandler $ \state GetRoleName -> do
        print ("GONK"::String, connectionRoleName state)
        pure (connectionRoleName state)]
  

serverConnectionConfig :: ServerConnectionConfig
serverConnectionConfig = S.EncryptedConnectionConfig
                         (ServerTLSConfig
                           {S.tlsCertData = certData,
                            S.tlsServerHostName = "localhost",
                            S.tlsServerServiceName = mempty}) AcceptAnonymousClient
  where
    certData = ServerTLSCertInfo {
      x509PublicFilePath = "./test/Curryer/Test/server/server.cert.pem",
      S.x509CertFilePath = "./test/Curryer/Test/ca/certs/cacert.pem",
      x509PrivateFilePath = "./test/Curryer/Test/server/server.key.pem"
      }

mTLSServerConnectionConfig :: ServerConnectionConfig
mTLSServerConnectionConfig = S.EncryptedConnectionConfig
                         (ServerTLSConfig
                           {S.tlsCertData = certData,
                            S.tlsServerHostName = "localhost",
                            S.tlsServerServiceName = mempty}) ClientAuthRequired
  where
    certData = ServerTLSCertInfo {
      x509PublicFilePath = "./test/Curryer/Test/server/server.cert.pem",
      S.x509CertFilePath = "./test/Curryer/Test/ca/certs/cacert.pem",
      x509PrivateFilePath = "./test/Curryer/Test/server/server.key.pem"
      }

mTLSClientConnectionConfig :: ClientConnectionConfig
mTLSClientConnectionConfig = C.EncryptedConnectionConfig
                         (ClientTLSConfig {C.tlsCertData = certData,
                                     C.tlsServerHostName = "localhost",
                                     C.tlsServerServiceName = mempty})
  where
    certData = ClientTLSCertInfo {
      x509PublicPrivateFilePaths = Just ("./test/Curryer/Test/client/client.cert.pem",
                                    "./test/Curryer/Test/client/client.key.pem"),
      C.x509CertFilePath = Just "./test/Curryer/Test/ca/certs/cacert.pem"
      }

clientConnectionConfig :: ClientConnectionConfig
clientConnectionConfig = C.EncryptedConnectionConfig
                         (ClientTLSConfig {C.tlsCertData = certData,
                                     C.tlsServerHostName = "localhost",
                                     C.tlsServerServiceName = mempty})
  where
    certData = ClientTLSCertInfo {
      x509PublicPrivateFilePaths = Nothing,
      C.x509CertFilePath = Just "./test/Curryer/Test/ca/certs/cacert.pem"
      }

-- test an anonymous client connecting to a self-signed cert server
testSimpleCall :: Assertion
testSimpleCall = do
  readyVar <- newEmptyMVar
  let emptyServerState = ()
  server <- async (serveIPv4 (testServerRequestHandlers Nothing) emptyServerState serverConnectionConfig localHostAddr 0 (Just readyVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar readyVar
  conn <- connectIPv4 [] clientConnectionConfig localHostAddr port
  replicateM_ 5 $ do --make five AddTwo calls to shake out parallelism bugs
    x <- call conn (AddTwoNumbersReq 1 1)
    assertEqual "server request+response" (Right (2 :: Int)) x
  close conn
  cancel server
  
-- test a mutual TLS RPC call
testMutualTLS :: Assertion
testMutualTLS = do
  readyVar <- newEmptyMVar
  let emptyServerState = ()
  server <- async (serveIPv4 (testServerRequestHandlers Nothing) emptyServerState mTLSServerConnectionConfig localHostAddr 0 (Just readyVar))
  --wait for server to be ready
  (SockAddrInet port _) <- takeMVar readyVar
  conn <- connectIPv4 [] mTLSClientConnectionConfig localHostAddr port
  x <- call conn GetRoleName
  assertEqual "get role name" (Right (Just "testou" :: Maybe String)) x
  close conn
  cancel server
  
