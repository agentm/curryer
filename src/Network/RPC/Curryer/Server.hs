{-# LANGUAGE DerivingVia, DeriveGeneric, RankNTypes, ScopedTypeVariables, MultiParamTypeClasses, OverloadedStrings, GeneralizedNewtypeDeriving, TypeApplications, CPP, ExistentialQuantification, StandaloneDeriving, GADTs #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{- HLINT ignore "Use lambda-case" -}
module Network.RPC.Curryer.Server where
import qualified Streamly.Prelude as S
import Streamly.Network.Socket
import Streamly.Internal.Network.Socket (handleWithM)
import Network.Socket as Socket
import Network.Socket.ByteString as Socket
import Streamly.Internal.Data.Parser as P hiding (concatMap)
import Codec.Winery
import Codec.Winery.Internal (varInt, decodeVarInt, getBytes)
import Codec.Winery.Class (mkExtractor)
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
import Streamly.Data.Fold as FL
import qualified Streamly.Internal.Data.Stream.IsStream as S
import qualified Data.Binary as B
import qualified Data.UUID as UUIDBase
import Control.Monad

import qualified Network.RPC.Curryer.StreamlyAdditions as SA
--import Control.Monad
import Data.Hashable
import System.Timeout
import qualified Network.ByteOrder as BO

-- for toArrayS conversion
{-import qualified Data.ByteString.Internal as BSI
import qualified Streamly.Internal.Data.Array.Storable.Foreign.Types as SA
import Foreign.ForeignPtr (plusForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import GHC.Ptr (plusPtr)
-}
-- #define CURRYER_SHOW_BYTES 1
#if CURRYER_SHOW_BYTES == 1
import Debug.Trace
#endif

traceBytes :: Applicative f => String -> BS.ByteString -> f ()  
#if CURRYER_SHOW_BYTES == 1
traceBytes msg bs = traceShowM (msg, BS.length bs, bs)
#else
traceBytes _ _ = pure ()
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

deriving instance Generic Fingerprint
deriving via WineryVariant Fingerprint instance Serialise Fingerprint

data MessageType = RequestMessage TimeoutMicroseconds
                 | ResponseMessage
                 | TimeoutResponseMessage
                 deriving (Generic, Show)
                 deriving Serialise via WineryVariant MessageType

type MessageHandlers = [RequestHandler]
  
--newtype RequestHandler = RequestHandler { handler :: forall a b. (Serialise a, Serialise b) => (a -> IO b) }

data RequestHandler where
  -- | create a request handler with a response
  RequestHandler :: forall a b. (Serialise a, Serialise b) => (a -> IO b) -> RequestHandler
  -- | create an asynchronous request handler where the client does not expect nor await a response
  AsyncRequestHandler :: forall a. Serialise a => (a -> IO ()) -> RequestHandler
  
{-
handleCall :: forall a b. (Serialise a, Serialise b)
           => (a -> IO b)
           -> RequestHandler
handleCall f = RequestHandler f
-}
{-data Message a = Response UUID a
                | AsyncRequest UUID a
                | ResponseExpectedRequest UUID (Maybe Timeout) a
                | TimedOutResponse UUID
                | ExceptionResponse UUID String
                deriving (Generic, Show)
                deriving Serialise via WineryVariant (Message a)

-- | The response type 

data HandlerResponse a = NoResponse
                       | HandlerResponse a
                       | HandlerException String
                       deriving Generic
                       deriving Serialise via WineryVariant (HandlerResponse a)
-}
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


data ConnectionError = CodecError String -- show of WineryException from exception initiator which cannot otherwise be transmitted over a line due to dependencies on TypeReps
                     | TimeoutError
                     | ExceptionError String
                     deriving (Generic, Show, Eq)
                     deriving Serialise via WineryVariant ConnectionError

type HostAddr = (Word8, Word8, Word8, Word8)

allHostAddrs,localHostAddr :: HostAddr
allHostAddrs = (0,0,0,0)
localHostAddr = (127,0,0,1)

-- Each message is lxggength-prefixed by a 32-bit unsigned length.
envelopeP :: Parser IO Word8 Envelope
envelopeP = do
  let s = FL.toList
      msgTypeP = (P.satisfy (== 0) *>
                     (RequestMessage . fromIntegral <$> word32P)) `P.alt`
                 (P.satisfy (== 1) *> pure ResponseMessage) `P.alt`
                 (P.satisfy (== 2) *> pure TimeoutResponseMessage)
      lenPrefixedByteStringP = do
        c <- fromIntegral <$> word32P
        BS.pack <$> P.takeEQ c s
  Envelope <$> fingerprintP <*> msgTypeP <*> uuidP <*> lenPrefixedByteStringP

encodeEnvelope :: Envelope -> BS.ByteString
encodeEnvelope (Envelope (Fingerprint fp1 fp2) msgType msgId bs) =
  fingerprintBs <> msgTypeBs <> msgIdBs <> lenPrefixedBs
  where
    fingerprintBs = BO.bytestring64 fp1 <> BO.bytestring64 fp2
    msgTypeBs = case msgType of
      RequestMessage timeoutms -> BS.singleton 0 <> BO.bytestring32 (fromIntegral timeoutms)
      ResponseMessage -> BS.singleton 1
      TimeoutResponseMessage -> BS.singleton 2
    msgIdBs =
      case UUIDBase.toWords (_unUUID msgId) of
        (u1, u2, u3, u4) -> foldr (<>) BS.empty (map BO.bytestring32 [u1, u2, u3, u4])
    msgLen = fromIntegral (BS.length bs)
    lenPrefixedBs = BO.bytestring32 msgLen <> bs

fingerprintP :: Parser IO Word8 Fingerprint
fingerprintP = do
  f1 <- word64P
  f2 <- word64P
  pure (Fingerprint f1 f2)

word64P :: Parser IO Word8 Word64
word64P = do
  let s = FL.toList
  b <- P.takeEQ 8 s
  pure (BO.word64 (BS.pack b))

--parse a 32-bit integer from network byte order
word32P :: Parser IO Word8 Word32
word32P = do
  let s = FL.toList
  w4x8 <- P.takeEQ 4 s 
  pure (BO.word32 (BS.pack w4x8))

-- uuid is encode as 4 32-bit words because of its convenient 32-bit tuple encoding
uuidP :: Parser IO Word8 UUID
uuidP = do
  u1 <- word32P
  u2 <- word32P
  u3 <- word32P
  u4 <- word32P
  pure (UUID (UUIDBase.fromWords u1 u2 u3 u4))

type NewConnectionHandler msg = IO (Maybe msg)

type NewMessageHandler req resp = req -> IO resp
  
serve :: 
         MessageHandlers -> 
         HostAddr ->
         PortNumber ->
         Maybe (MVar SockAddr) ->
         IO Bool
serve userMsgHandlers hostaddr port mSockLock = do
  let
      handleSock sock = do
        lockingSocket <- newLock sock
        drainSocketMessages sock (serverEnvelopeHandler lockingSocket userMsgHandlers)
        
  S.serially (S.unfold (SA.acceptOnAddrWith [(ReuseAddr,1)] mSockLock) (hostaddr, port)) & S.parallely . S.mapM (handleWithM handleSock) & S.drain
  pure True

{-serverEnvelopeHandler :: Locking Socket -> MessageHandlers s -> Envelope -> IO ()
serverEnvelopeHandler sockLock (Envelope fprint RequestMessage msgId messagebs) = do
 error "spam"
serverEnvelopeHandler sockLock (Envelope fprint ResponseMessage msgId messagebs) = do  
  error "spam2"
-}

openEnvelope :: forall s. (Serialise s, Typeable s) => Envelope -> Maybe s
openEnvelope (Envelope eprint _ _ bytes) = do
  {-let decoder = case getDecoder (schema (Proxy :: Proxy s)) of
        Left err -> error (show err)
        Right dec -> dec-}
  if eprint == fingerprint (undefined :: s) then
    case deserialise bytes of
      Left err -> error (show err)
      Right v -> Just v
    --Just (evalDecoder decoder bytes)
    else
    Nothing

matchEnvelope :: forall a b. (Serialise a, Serialise b, Typeable b) =>
              Envelope -> 
              (a -> IO b) ->
              Maybe (a -> IO b, a)
matchEnvelope envelope dispatchf =
  case openEnvelope envelope :: Maybe a of
    Nothing -> Nothing
    Just decoded -> Just (dispatchf, decoded)

serverEnvelopeHandler :: 
                     Locking Socket
                     -> MessageHandlers
                     -> Envelope
                     -> IO ()
serverEnvelopeHandler _ _ (Envelope _ TimeoutResponseMessage _ _) = pure ()
serverEnvelopeHandler sockLock msgHandlers envelope@(Envelope _ (RequestMessage timeoutms) msgId _) = do
  --find first matching handler
  let runTimeout :: IO b -> IO (Maybe b)
      runTimeout m =
        if timeoutms == 0 then
          Just <$> m
          else
          timeout (fromIntegral timeoutms) m               
      firstMatcher (RequestHandler (msghandler :: a -> IO b)) Nothing =
        case matchEnvelope envelope msghandler of
          Nothing -> pure Nothing
          Just (dispatchf, decoded) ->
            --TODO add exception handling
             do
              mResponse <- runTimeout (dispatchf decoded)
              let envelopeResponse =
                    case mResponse of
                      Just response ->
                        Envelope (fingerprint response) ResponseMessage msgId (serialise response)
                      Nothing -> Envelope (fingerprint TimeoutError) (TimeoutResponseMessage) msgId (BS.empty)
              sendEnvelope envelopeResponse sockLock
              pure (Just ())
      firstMatcher (AsyncRequestHandler (msghandler :: a -> IO ())) Nothing =
        case matchEnvelope envelope msghandler of
          Nothing -> pure Nothing
          Just (dispatchf, decoded) -> do
              _ <- dispatchf decoded
              pure (Just ())
      firstMatcher _ acc = pure acc
  foldM_ (flip firstMatcher) Nothing msgHandlers
serverEnvelopeHandler _ _ (Envelope _ ResponseMessage _ _) = error "server received response message"


{-      
      
  
  --putStrLn $ "GOT MSG " ++ show msg
  let --runTimeout :: IO (HandlerResponse resp) -> IO (Maybe (HandlerResponse resp))
      runTimeout mTimeout m = case mTimeout of
                       Nothing -> Just <$> m
                       Just timeoutMicroseconds -> timeout timeoutMicroseconds m
  case msg of
      Response{} -> putStrLn "client sent response"
      ResponseExpectedRequest requestID mTimeout val -> do
        let normalResponder = do
              resp <- runTimeout mTimeout (requestMessageHandler val)
              case resp of
                Just (HandlerResponse responseVal) -> sendMessage (Response requestID responseVal) sockLock
                Just NoResponse -> error "attempt to return non-response to expected response message"
                Just (HandlerException exc) -> sendMessage (ExceptionResponse @(Message resp) requestID exc) sockLock
                Nothing ->
                  sendMessage (TimedOutResponse @(Message resp) requestID) sockLock
            excHandler :: SomeException -> IO ()
            excHandler e = do
              --send exception to client
              sendMessage (ExceptionResponse @(Message resp) requestID (show e)) sockLock
              throwIO e
        catch normalResponder excHandler
      AsyncRequest _ val ->
        void $ requestMessageHandler val
        --no response necessary
      ExceptionResponse{} -> putStrLn "client sent exception response"
      TimedOutResponse{} -> putStrLn "client sent timed out response"
-}

--add callback to allow for responses via socket
--type MessageHandler a = Message a -> IO ()

type EnvelopeHandler = Envelope -> IO ()

type AsyncMessageHandler a = a -> IO ()

drainSocketMessages :: Socket -> EnvelopeHandler -> IO ()
drainSocketMessages sock envelopeHandler = do
  let sockStream = S.unfold readWithBufferOf (1024 * 4, sock)
  S.drain $ S.serially $ S.parseMany envelopeP sockStream & S.mapM envelopeHandler

--send length-tagged bytestring, perhaps should be in network byte order?
sendEnvelope :: Envelope -> Locking Socket -> IO ()
sendEnvelope envelope sockLock = do
  let envelopebytes = encodeEnvelope envelope
      fullbytes = envelopebytes
  --Socket.sendAll syscalls send() on a loop until all the bytes are sent, so we need socket locking here to account for serialized messages of size > PIPE_BUF
  withLock sockLock $ \socket' ->
    Socket.sendAll socket' fullbytes
  traceBytes "sendEnvelope" fullbytes

fingerprint :: Typeable a => a -> Fingerprint
fingerprint = typeRepFingerprint . typeOf

