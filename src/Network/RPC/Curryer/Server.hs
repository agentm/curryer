{-# LANGUAGE DerivingVia, DeriveGeneric, RankNTypes, ScopedTypeVariables, MultiParamTypeClasses, OverloadedStrings, GeneralizedNewtypeDeriving, CPP, ExistentialQuantification, StandaloneDeriving, GADTs, UnboxedTuples, BangPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{- HLINT ignore "Use lambda-case" -}
module Network.RPC.Curryer.Server where
import qualified Streamly.Data.Stream.Prelude as SP
import Streamly.Data.Stream as Stream hiding (foldr)
import Streamly.Internal.Data.Array (pinnedCreateOf)

import Streamly.Network.Socket as SSock
import Network.Socket as Socket
import Network.Socket.ByteString as Socket
import Streamly.Data.Parser as P
import Codec.Winery
import Codec.Winery.Internal (varInt, decodeVarInt, getBytes)
import GHC.Generics
import GHC.Fingerprint
import Data.Typeable
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception
import Data.Function ((&))
import Data.Word
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.FastBuilder as BB
import Streamly.Data.Fold as FL hiding (foldr)
--import qualified Streamly.Internal.Data.Stream.IsStream as P
import qualified Streamly.Data.Stream.Prelude as P
import qualified Streamly.External.ByteString as StreamlyBS
import Streamly.Data.Stream.Prelude as Stream hiding (foldr)
import Streamly.Internal.Data.Binary.Parser (word32be)
import qualified Streamly.Data.Unfold as UF
import qualified Data.Binary as B
import qualified Data.UUID as UUIDBase
import qualified Data.UUID.V4 as UUIDBase
import Control.Monad
import Data.Functor
import Control.Applicative

import qualified Network.RPC.Curryer.StreamlyAdditions as SA
import qualified Network.RPC.Curryer.StreamlyTLS as STLS
import Data.Hashable
import System.Timeout
import qualified Network.ByteOrder as BO
import qualified Network.TLS as TLS
import Data.X509.CertificateStore

#define CURRYER_SHOW_BYTES 0
#define CURRYER_PASS_SCHEMA 0

#if CURRYER_SHOW_BYTES == 1
import Debug.Trace
#endif

traceBytes :: Applicative f => String -> BS.ByteString -> f ()  
#if CURRYER_SHOW_BYTES == 1
traceBytes msg bs = traceShowM (msg, BS.length bs, bs)
#else
traceBytes _ _ = pure ()
#endif

-- a level of indirection to be able to switch between serialising with and without the winery schema
msgSerialise :: Serialise a => a -> BS.ByteString
#if CURRYER_PASS_SCHEMA == 1
msgSerialise = serialise
#else
msgSerialise = serialiseOnly
#endif

msgDeserialise :: forall s. Serialise s => BS.ByteString -> Either WineryException s
#if CURRYER_PASS_SCHEMA == 1
msgDeserialise = deserialise
#else
msgDeserialise = deserialiseOnly'
#endif

data Locking a = Locking (MVar ()) a

newLock :: a -> IO (Locking a)
newLock x = do
  lock <- newMVar ()
  pure (Locking lock x)
  
withLock :: Locking a -> (a -> IO b) -> IO b
withLock (Locking mvar v) m =
  withMVar mvar $ \_ -> m v

lockless :: Locking a -> a
lockless (Locking _ a) = a

-- | Server-side TLS key/certificate information.
data ServerTLSCertInfo = ServerTLSCertInfo
  {
    x509PublicFilePath :: FilePath,
    x509CertFilePath :: FilePath,
    x509PrivateFilePath :: FilePath
  } deriving Show

-- | Server-side TLS configuration.
data ServerTLSConfig = ServerTLSConfig
    { tlsCertData :: ServerTLSCertInfo,
      tlsServerHostName :: ServerHostName,
      tlsServerServiceName :: ServerServiceName
    } deriving Show

type ServerHostName = HostName
type ServerServiceName = BS.ByteString

-- | Specify whether server should listen for unencrypted connections or TLS-encrypted connections (preferred).
data ServerConnectionConfig = UnencryptedConnectionConfig |
                              EncryptedConnectionConfig ServerTLSConfig ClientAuth
                            deriving Show

-- | Specify whether the server should require a client-provided certificate for login (preferred) or whether anonymous clients should be granted access, too.
data ClientAuth = ClientAuthRequired | AcceptAnonymousClient
  deriving (Eq, Show)

type Timeout = Word32

type BinaryMessage = BS.ByteString

--includes the fingerprint of the incoming data type (held in the BinaryMessage) to determine how to dispatch the message.
--add another envelope type for unencoded binary messages for any easy optimization for in-process communication
data Envelope = Envelope {
  envFingerprint :: !Fingerprint,
  envMessageType :: !MessageType,
  envMsgId :: !UUID,
  envPayload :: !BinaryMessage
  }
  deriving (Generic, Show)

type TimeoutMicroseconds = Int

#if MIN_VERSION_base(4,15,0)
#else
deriving instance Generic Fingerprint
#endif
deriving via WineryVariant Fingerprint instance Serialise Fingerprint

-- | Internal type used to mark envelope types.
data MessageType = RequestMessage TimeoutMicroseconds
                 | ResponseMessage
                 | TimeoutResponseMessage
                 | ExceptionResponseMessage
                 deriving (Generic, Show)
                 deriving Serialise via WineryVariant MessageType

-- | A list of `RequestHandler`s.
type RequestHandlers serverState = [RequestHandler serverState]

-- | Data types for server-side request handlers, in synchronous (client waits for return value) and asynchronous (client does not wait for return value) forms.
data RequestHandler serverState where
  -- | create a request handler with a response
  RequestHandler :: forall a b serverState. (Serialise a, Serialise b) => (ConnectionState serverState -> a -> IO b) -> RequestHandler serverState
  -- | create an asynchronous request handler where the client does not expect nor await a response
  AsyncRequestHandler :: forall a serverState. Serialise a => (ConnectionState serverState -> a -> IO ()) -> RequestHandler serverState

-- | Server state sent in via `serve` and passed to `RequestHandler`s.
data ConnectionState a = ConnectionState {
  connectionServerState :: a,
  connectionSocketContext :: SocketContext,
  connectionRoleName :: Maybe STLS.RoleName -- ^ if a client certificate is provided during the TLS handshake, the connection role is the organization unit, if available
  }

data SocketContext = UnencryptedSocketContext (Locking Socket) |
                     EncryptedSocketContext (Locking Socket) TLS.Context

lockingSocket :: SocketContext -> Locking Socket
lockingSocket (UnencryptedSocketContext ls) = ls
lockingSocket (EncryptedSocketContext ls _tlsCtx) = ls

-- | Used by server-side request handlers to send additional messages to the client. This is useful for sending asynchronous responses to the client outside of the normal request-response flow. The locking socket can be found in the ConnectionState when a request handler is called.
sendMessage :: Serialise a => SocketContext -> a -> IO ()
sendMessage sockCtx msg = do
  requestID <- UUID <$> UUIDBase.nextRandom
  let env =
        Envelope (fingerprint msg) (RequestMessage timeout') requestID (msgSerialise msg)
      timeout' = 0
  sendEnvelope env sockCtx
  
--avoid orphan instance
newtype UUID = UUID { _unUUID :: UUIDBase.UUID }
  deriving (Show, Eq, B.Binary, Hashable)

instance Serialise UUID where
  schemaGen _ = pure (STag (TagStr "Data.UUID") SBytes)
  toBuilder uuid = let bytes = BSL.toStrict (B.encode uuid) in
                     varInt (BS.length bytes) <> BB.byteString bytes
  {-# INLINE toBuilder #-}
  extractor = mkExtractor $
    \schema' -> case schema' of
                 STag (TagStr "Data.UUID") SBytes ->
                   pure $ \term -> case term of
                              TBytes bs -> B.decode (BSL.fromStrict bs)
                              term' -> throw (InvalidTerm term')
                 x -> error $ "invalid schema element " <> show x
  decodeCurrent = B.decode . BSL.fromStrict <$> (decodeVarInt >>= getBytes)

-- | Errors from remote calls.
data ConnectionError = CodecError String -- show of WineryException from exception initiator which cannot otherwise be transmitted over a line due to dependencies on TypeReps
                     | TimeoutError
                     | ExceptionError String
                     deriving (Generic, Show, Eq)
                     deriving Serialise via WineryVariant ConnectionError

data TimeoutException = TimeoutException
  deriving Show

instance Exception TimeoutException  

type BParser a = Parser Word8 IO a

type HostAddressTuple = (Word8, Word8, Word8, Word8)
type HostAddressTuple6 = (Word16, Word16, Word16, Word16, Word16, Word16, Word16, Word16)
                        
allHostAddrs,localHostAddr :: HostAddressTuple
allHostAddrs = (0,0,0,0)
localHostAddr = (127,0,0,1)

localHostAddr6 :: HostAddressTuple6
localHostAddr6 = (0,0,0,0,0,0,0,1)


msgTypeP :: BParser MessageType
msgTypeP = (P.satisfy (== 0) *>
             (RequestMessage . fromIntegral <$> word32P)) <|>
           (P.satisfy (== 1) $> ResponseMessage) <|>
           (P.satisfy (== 2) $> TimeoutResponseMessage) <|>
           (P.satisfy (== 3) $> ExceptionResponseMessage)
                 
-- Each message is length-prefixed by a 32-bit unsigned length.
envelopeP :: BParser Envelope
envelopeP = do
  let lenPrefixedByteStringP = do
        c <- fromIntegral <$> word32be
        --streamly can't handle takeEQ 0, so add special handling
--        traceShowM ("envelopeP payload byteCount"::String, c)
        if c == 0 then
          pure mempty
          else do
          ps <- P.takeEQ c (pinnedCreateOf c)
--          traceShowM ("envelopeP read bytes", c)
          let !bs = StreamlyBS.fromArray ps
--          traceShowM ("unoptimized bs")
          pure bs 
  Envelope <$> fingerprintP <*> msgTypeP <*> uuidP <*> lenPrefixedByteStringP

--overhead is fingerprint (16 bytes), msgType (1+4 optional bytes for request message), msgId (4 bytes), uuid (16 bytes) = 41 bytes per request message, 37 bytes for all others
encodeEnvelope :: Envelope -> BS.ByteString
encodeEnvelope (Envelope (Fingerprint fp1 fp2) msgType msgId bs) =
{-  traceShow ("encodeEnvelope"::String,
             ("fingerprint len"::String, BS.length fingerprintBs),
             ("msgtype length"::String,BS.length msgTypeBs),
             ("id len"::String, BS.length msgIdBs),
             ("payload len"::String, payloadLen),
             ("complete len"::String, BS.length completeMessage)) $-}
  completeMessage
  where
    completeMessage = fingerprintBs <> msgTypeBs <> msgIdBs <> lenPrefixedBs
    fingerprintBs = BO.bytestring64 fp1 <> BO.bytestring64 fp2
    msgTypeBs = case msgType of
      RequestMessage timeoutms -> BS.singleton 0 <> BO.bytestring32 (fromIntegral timeoutms)
      ResponseMessage -> BS.singleton 1
      TimeoutResponseMessage -> BS.singleton 2
      ExceptionResponseMessage -> BS.singleton 3
    msgIdBs =
      case UUIDBase.toWords (_unUUID msgId) of
        (u1, u2, u3, u4) -> foldr ((<>) . BO.bytestring32) BS.empty [u1, u2, u3, u4]
    lenPrefixedBs = BO.bytestring32 payloadLen <> bs
    payloadLen = fromIntegral (BS.length bs)
    
    

fingerprintP :: BParser Fingerprint
fingerprintP =
  Fingerprint <$> word64P <*> word64P

word64P :: BParser Word64
word64P = do
  let s = FL.toList
  b <- P.takeEQ 8 s
  pure (BO.word64 (BS.pack b))

--parse a 32-bit integer from network byte order
word32P :: BParser Word32
word32P = do
  let s = FL.toList
  w4x8 <- P.takeEQ 4 s
--  traceShowM ("w4x8"::String, BO.word32 (BS.pack w4x8))
  pure (BO.word32 (BS.pack w4x8))

-- uuid is encode as 4 32-bit words because of its convenient 32-bit tuple encoding
uuidP :: BParser UUID
uuidP = do
  u1 <- word32P
  u2 <- word32P
  u3 <- word32P
  --u4 <- word32P
  --pure (UUID (UUIDBase.fromWords u1 u2 u3 u4))-}
  --(UUID . UUIDBase.fromWords) <$> word32P <*> word32P <*> word32P <*> word32P
  UUID . UUIDBase.fromWords u1 u2 u3 <$> word32P

type NewConnectionHandler msg = IO (Maybe msg)

type NewMessageHandler req resp = req -> IO resp

defaultSocketOptions :: [(SocketOption, Int)]
defaultSocketOptions = [(ReuseAddr, 1), (NoDelay, 1)]

-- | Listen for new connections and handle requests on an IPv4 address. Wraps `serve1.
serveIPv4 :: RequestHandlers s -> s -> ServerConnectionConfig -> HostAddressTuple -> PortNumber -> Maybe (MVar SockAddr) -> IO Bool
serveIPv4 handlers state config hostaddr port  =
  serve handlers state config sockSpec sockAddr
  where
    sockAddr = SockAddrInet port (tupleToHostAddress hostaddr)
    sockSpec = SockSpec { sockFamily = AF_INET,
                          sockType = Stream,
                          sockProto = 0,
                          sockOpts = defaultSocketOptions
                        }

-- | Listen for IPv6 RPC requests. Wraps `serve`.
serveIPv6 :: RequestHandlers s -> s -> ServerConnectionConfig -> HostAddressTuple6 -> PortNumber -> Maybe (MVar SockAddr) -> IO Bool
serveIPv6 handlers state config hostaddr port =
  serve handlers state config sockSpec sockAddr
  where
    flowInfo = 0
    scopeInfo = 0
    sockAddr = SockAddrInet6 port flowInfo (tupleToHostAddress6 hostaddr) scopeInfo
    sockSpec = SockSpec { sockFamily = AF_INET6,
                          sockType = Stream,
                          sockProto = 0,
                          sockOpts = defaultSocketOptions
                          }

-- | Listen for Unix domain socket RPC requests. Wraps `serve`.
serveUnixDomain :: RequestHandlers s -> s -> FilePath -> Maybe (MVar SockAddr) -> IO Bool
serveUnixDomain handlers state socketPath =
  serve handlers state UnencryptedConnectionConfig sockSpec sockAddr
  where
    sockSpec = SockSpec { sockFamily = AF_UNIX,
                          sockType = Stream,
                          sockProto = 0,
                          sockOpts = [] }
    sockAddr = SockAddrUnix socketPath
  
-- | Listen for new connections and handle requests which are passed the server state 's'. The MVar SockAddr can be be optionally used to know when the server is ready for processing requests.
serve :: 
         RequestHandlers s ->
         s ->
         ServerConnectionConfig ->
         SockSpec ->
         SockAddr -> 
         Maybe (MVar SockAddr) ->
         IO Bool
serve userMsgHandlers serverState config sockSpec sockAddr mSockLock = do
  let handleSock sock = do
        (sockCtx, mRoleName) <- setupServerSocket config sock
        drainSocketMessages sockCtx (serverEnvelopeHandler sockCtx mRoleName userMsgHandlers serverState)
  Stream.unfold (SA.acceptorOnSockSpec sockSpec mSockLock) sockAddr
   & Stream.parMapM id handleSock
   & Stream.fold FL.drain
  pure True

-- | Negotiate TLS on the socket, if necessary. If ClientAuth is True, then all clients are required to present a certificate for mutual TLS (anonymous clients will be rejected during the TLS handshake).
setupServerSocket :: ServerConnectionConfig -> Socket -> IO (SocketContext, Maybe STLS.RoleName)
setupServerSocket config sock = do
  sockLock <- newLock sock
  case config of
    UnencryptedConnectionConfig{} -> pure (UnencryptedSocketContext sockLock, Nothing)
    EncryptedConnectionConfig tlsConfig clientAuth -> do
      let certPath = x509CertFilePath (tlsCertData tlsConfig)
      creds <- STLS.readCreds (x509PublicFilePath (tlsCertData tlsConfig)) (x509PrivateFilePath (tlsCertData tlsConfig))
      mCAStore <- readCertificateStore certPath
      case mCAStore of
        Nothing -> error ("failed to load certificate store at " <> certPath)
        Just caStore -> do
          (tlsCtx, mRoleName) <- STLS.serverHandshake sock creds (clientAuth /= AcceptAnonymousClient) (Just caStore)
          pure (EncryptedSocketContext sockLock tlsCtx, mRoleName)

openEnvelope :: forall s. (Serialise s, Typeable s) => Envelope -> Maybe s
openEnvelope (Envelope eprint _ _ bytes) =
  if eprint == fingerprint (undefined :: s) then
    case msgDeserialise bytes of
      Left _e -> {-traceShow ("openEnv error"::String, _e)-} Nothing
      Right decoded -> Just decoded
    else
    Nothing

--use winery to decode only the data structure and skip the schema
deserialiseOnly' :: forall s. Serialise s => BS.ByteString -> Either WineryException s
deserialiseOnly' bytes = do
  dec <- getDecoder (schema (Proxy :: Proxy s))
  pure (evalDecoder dec bytes)


matchEnvelope :: forall a b s. (Serialise a, Serialise b, Typeable b) =>
              Envelope -> 
              (ConnectionState s -> a -> IO b) ->
              Maybe (ConnectionState s -> a -> IO b, a)
matchEnvelope envelope dispatchf =
  case openEnvelope envelope :: Maybe a of
    Nothing -> Nothing
    Just decoded -> Just (dispatchf, decoded)

-- | Called by `serve` to process incoming envelope requests. Never returns, so use `async` to spin it off on another thread.
serverEnvelopeHandler :: SocketContext
                     -> Maybe STLS.RoleName
                     -> RequestHandlers s
                     -> s         
                     -> Envelope
                     -> IO ()
serverEnvelopeHandler _ _ _ _ (Envelope _ TimeoutResponseMessage _ _) = pure ()
serverEnvelopeHandler _ _ _ _ (Envelope _ ExceptionResponseMessage _ _) = pure ()
serverEnvelopeHandler _ _ _ _ (Envelope _ ResponseMessage _ _) = pure ()
serverEnvelopeHandler sockCtx mRoleName msgHandlers serverState envelope@(Envelope _ (RequestMessage timeoutms) msgId _) = do
  --find first matching handler
  let runTimeout :: IO b -> IO (Maybe b)
      runTimeout m = 
        if timeoutms == 0 then
          (Just <$> m) `catch` timeoutExcHandler
        else
          timeout (fromIntegral timeoutms) m `catch` timeoutExcHandler
      --allow server-side function to throw TimeoutError which is caught here and becomes TimeoutError value
      timeoutExcHandler :: TimeoutException -> IO (Maybe b)
      timeoutExcHandler _ = pure Nothing
      
      sState = ConnectionState {
        connectionServerState = serverState,
        connectionSocketContext = sockCtx,
        connectionRoleName = mRoleName
        }
            
      firstMatcher (RequestHandler msghandler) Nothing =
        case matchEnvelope envelope msghandler of
          Nothing -> pure Nothing
          Just (dispatchf, decoded) -> do
            --TODO add exception handling
            mResponse <- runTimeout (dispatchf sState decoded)
            let envelopeResponse =
                  case mResponse of
                        Just response ->
                          Envelope (fingerprint response) ResponseMessage msgId (msgSerialise response)
                        Nothing -> 
                          Envelope (fingerprint TimeoutError) TimeoutResponseMessage msgId BS.empty
            sendEnvelope envelopeResponse sockCtx
            pure (Just ())
      firstMatcher (AsyncRequestHandler msghandler) Nothing =        
        case matchEnvelope envelope msghandler of
          Nothing -> pure Nothing
          Just (dispatchf, decoded) -> do
              _ <- dispatchf sState decoded
              pure (Just ())
      firstMatcher _ acc = pure acc
  eExc <- try $ foldM_ (flip firstMatcher) Nothing msgHandlers :: IO (Either SomeException ())
  case eExc of
    Left exc ->
      let env = Envelope (fingerprint (show exc)) ExceptionResponseMessage msgId (msgSerialise (show exc)) in
      sendEnvelope env sockCtx
    Right () -> pure ()


type EnvelopeHandler = Envelope -> IO ()

drainSocketMessages :: SocketContext -> EnvelopeHandler -> IO ()
drainSocketMessages sockCtx envelopeHandler = do
      
  let socketReader :: UF.Unfold IO Socket Word8
      socketReader = case sockCtx of
                       UnencryptedSocketContext{} -> SSock.reader
                       EncryptedSocketContext _lsock tlsCtx ->
                         STLS.tlsReader tlsCtx
      sock = lockless (lockingSocket sockCtx)
  SP.unfold socketReader sock
   & P.parseMany envelopeP
   & SP.catRights
   & SP.parMapM (SP.ordered False) envelopeHandler 
   & SP.fold FL.drain

--send length-tagged bytestring, perhaps should be in network byte order?
sendEnvelope :: Envelope -> SocketContext -> IO ()
sendEnvelope envelope sockCtx = do
  let envelopebytes = encodeEnvelope envelope
  --Socket.sendAll syscalls send() on a loop until all the bytes are sent, so we need socket locking here to account for serialized messages of size > PIPE_BUF
  withLock (lockingSocket sockCtx) $ \socket' -> do
    {-traceShowM ("sendEnvelope"::String,
                ("type"::String, envMessageType envelope),
                socket',
                ("envelope len out"::String, BS.length envelopebytes),
                "payloadbytes"::String, envPayload envelope
               )-}
    case sockCtx of
      UnencryptedSocketContext{} ->
        Socket.sendAll socket' envelopebytes
      EncryptedSocketContext _ls tlsCtx ->
        TLS.sendData tlsCtx (BSL.fromStrict envelopebytes)
  traceBytes "sendEnvelope" envelopebytes

fingerprint :: Typeable a => a -> Fingerprint
fingerprint = typeRepFingerprint . typeOf
