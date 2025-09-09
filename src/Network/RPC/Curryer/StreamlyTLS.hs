{-# LANGUAGE CPP #-}
module Network.RPC.Curryer.StreamlyTLS where
--import Network.RPC.Curryer.StreamlyAdditions (initListener)
import Network.TLS as TLS
import Network.Socket hiding (socket)
--import Control.Monad.IO.Class
--import Streamly.Network.Socket (SockSpec)
--import Control.Concurrent (MVar, putMVar)
import qualified Streamly.Data.Array as A
import Streamly.Internal.Data.Unfold (Unfold(..))
import Streamly.External.ByteString (toArray)
import Streamly.Data.Array (Array)
import qualified Streamly.Internal.Data.Unfold as UF
import qualified Network.TLS.Extra as TLSExtra
--import qualified Network.Socket as Net
import qualified Streamly.Internal.Data.Stream as D
import Data.Default
--import Control.Exception (onException)
import Network.Socket.ByteString (sendAll, recv)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word8)
import Data.X509.CertificateStore
import Data.X509
import Data.ASN1.Types.String
import Control.Concurrent.MVar
import Control.Monad (void, when)
import Data.Maybe

clientHandshake :: Socket -> (HostName, ByteString) -> Maybe Credential -> Maybe CertificateStore -> IO TLS.Context
clientHandshake socket (serverHostName, serverService) mCred mCertStore = do
  let backend = TLS.Backend { backendFlush = pure (),
                              backendClose = pure (),
                              backendSend = sendAll socket,
                              backendRecv = recvExact socket
                            }
      params = (defaultParamsClient serverHostName serverService)
               {
--                 clientDebug = defaultDebugParams { debugError = \x -> putStrLn ("client debug: " <> x) },
                 clientShared = defaultShared { sharedCAStore = fromMaybe mempty mCertStore 
                                              },
                 clientSupported = defaultSupported { supportedVersions = [TLS13] },
                 clientHooks = defaultClientHooks {
                   onCertificateRequest = \_ -> pure mCred
                   }
               }
  ctx <- TLS.contextNew backend params
  TLS.handshake ctx
  pure ctx

type RoleName = String

serverHandshake :: Socket -> TLS.Credentials -> Bool -> Maybe CertificateStore -> IO (TLS.Context, Maybe RoleName)
serverHandshake socket creds requireClientAuth mCertStore = do
  roleName <- newMVar Nothing
  let backend = TLS.Backend { backendFlush = pure (),
                              backendClose = pure (),
                              backendSend = sendAll socket,
                              backendRecv = recvExact socket
                            }
      certStore = fromMaybe mempty mCertStore
      validationCache = sharedValidationCache defaultShared
      params = defaultParamsServer
        { serverWantClientCert = requireClientAuth
        , serverSupported = def
            { supportedCiphers = TLSExtra.ciphersuite_default,
              supportedVersions = [TLS13]
            }
        , serverShared = def
            { sharedCredentials = creds,
              sharedCAStore = certStore
            }
        , serverDebug = defaultDebugParams { debugError = \x -> putStrLn ("server: " <> x) }
        , serverHooks = defaultServerHooks {
            onClientCertificate = \certChain -> do
                --extract role from client certificate and save it
                valRes <- validateClientCertificate certStore validationCache certChain
                when (valRes == CertificateUsageAccept) $
                    void $ swapMVar roleName (extractRoleFromCertChain certChain)
                pure valRes
            }
        }
  ctx <- TLS.contextNew backend params
  TLS.handshake ctx
  roleName' <- takeMVar roleName
  pure (ctx, roleName')

extractRoleFromCertChain :: CertificateChain -> Maybe String
extractRoleFromCertChain (CertificateChain [signedClientCert]) =
  let clientCert = signedObject (getSigned signedClientCert)
      dnElements = certSubjectDN clientCert
      mOUElement = getDnElement DnOrganizationUnit dnElements
  in
    asn1CharacterToString =<< mOUElement
extractRoleFromCertChain _ = Nothing      


-- | TLS requires exactly the number of bytes requested to be returned.
recvExact :: Socket -> Int -> IO ByteString
recvExact socket i = do
    loop id i
  where
    loop front rest
        | rest < 0 = error "StreamlyTLS.recvExact: rest < 0"
        | rest == 0 = return $ BS.concat $ front []
        | otherwise = do
            next <- safeRecv socket rest
            if BS.length next == 0
                then
                  return $ BS.concat $ front []
                else loop (front . (next:)) $ rest - BS.length next

#if defined(__GLASGOW_HASKELL__) && WINDOWS
-- Socket recv and accept calls on Windows platform cannot be interrupted when compiled with -threaded.
-- See https://ghc.haskell.org/trac/ghc/ticket/5797 for details.
-- The following enables simple workaround
#define SOCKET_ACCEPT_RECV_WORKAROUND
#endif

safeRecv :: Socket -> Int -> IO ByteString
#ifndef SOCKET_ACCEPT_RECV_WORKAROUND
safeRecv = recv
#else
safeRecv s buf = do
    var <- newEmptyMVar
    forkIO $ recv s buf `E.catch` (\(_::IOException) -> return S8.empty) >>= putMVar var
    takeMVar var
#endif


tlsReader :: TLS.Context -> UF.Unfold IO Socket Word8
tlsReader ctx = UF.many A.reader (chunkTLSReader ctx)
  
-- | Read from TLS socket as soon as it is created.
chunkTLSReader :: TLS.Context -> UF.Unfold IO Socket (Array Word8)
chunkTLSReader ctx = Unfold step inject
  where
    step () = do
      bs <- recvData ctx
      if BS.length bs == 0 then
        pure D.Stop
        else do
        pure (D.Yield (toArray bs) ())
    inject _sock = pure ()
      
data TlsCertData = TlsCertData { getTLSCert :: IO ByteString
                               , getTLSChainCerts :: IO [ByteString]
                               , getTLSKey :: IO ByteString }

readCreds :: FilePath -> FilePath -> IO TLS.Credentials
readCreds certPath keyPath = do
  eCred <- credentialLoadX509 certPath keyPath
  case eCred of
    Left err -> error (show err)
    Right cred -> pure (Credentials [cred])
