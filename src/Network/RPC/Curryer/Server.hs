{-# LANGUAGE DerivingVia, DeriveGeneric, RankNTypes, ScopedTypeVariables, MultiParamTypeClasses, OverloadedStrings, GeneralizedNewtypeDeriving, TypeApplications, CPP, ExistentialQuantification, StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{- HLINT ignore "Use lambda-case" -}
module Network.RPC.Curryer.Server where
import Streamly
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

import qualified Network.RPC.Curryer.StreamlyAdditions as SA
--import Control.Monad
import Data.Hashable
--import System.Timeout
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

type Timeout = Int

type BinaryMessage = BS.ByteString

--includes the fingerprint of the incoming data type (held in the BinaryMessage) to determine how to dispatch the message.
--add another envelope type for unencoded binary messages for any easy optimization for in-process communication
data Envelope = Envelope !Fingerprint !MessageType !UUID !BinaryMessage
  deriving (Generic, Show)
  deriving Serialise via WineryVariant Envelope

deriving instance Generic Fingerprint
deriving via WineryVariant Fingerprint instance Serialise Fingerprint

data MessageType = RequestMessage
                 | ResponseMessage
                 deriving (Generic, Show)
                 deriving Serialise via WineryVariant MessageType

data MessageHandlers =
  forall a b. (Show a, Serialise a, Serialise b) => MessageHandlers [RequestHandler a b]
  
type RequestHandler a b = a -> IO b

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

-- Each message is length-prefixed by a 32-bit unsigned length.
envelopeP :: Parser IO Word8 Envelope
envelopeP = do
  let s = FL.toList
      msgTypeP = (P.satisfy (== 0) *> pure RequestMessage) `P.alt`
                 (P.satisfy (== 1) *> pure ResponseMessage)
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
      RequestMessage -> BS.singleton 0
      ResponseMessage -> BS.singleton 1
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
serve userMsgHandler hostaddr port mSockLock = do
  let
      handleSock sock = do
        lockingSocket <- newLock sock
        drainSocketMessages sock (serverEnvelopeHandler lockingSocket userMsgHandler)
        
  serially (S.unfold (SA.acceptOnAddrWith [(ReuseAddr,1)] mSockLock) (hostaddr, port)) & parallely . S.mapM (handleWithM handleSock) & S.drain
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

serverEnvelopeHandler :: 
                     Locking Socket
                     -> MessageHandlers
                     -> Envelope
                     -> IO ()
serverEnvelopeHandler sockLock (MessageHandlers msgHandlers) envelope@(Envelope _ RequestMessage msgId _) = do
  --find first matching handler
  let firstMatch = foldr firstMatcher Nothing msgHandlers
      firstMatcher :: forall a b. (Serialise a, Serialise b) => RequestHandler a b -> Maybe (RequestHandler a b, a) -> Maybe (RequestHandler a b, a)
      firstMatcher msghandler Nothing =
        case openEnvelope envelope :: Maybe a of
          Just decoded -> Just (msghandler, decoded)
          Nothing -> Nothing
      firstMatcher _ acc = acc
  case firstMatch of
    Nothing -> error "failed to handle msg"
    Just (msghandler, decoded) -> do
      --TODO add exception handling
      response <- msghandler decoded
      sendEnvelope (Envelope (fingerprint response) ResponseMessage msgId (serialise response)) sockLock
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
  S.drain $ serially $ S.parseMany envelopeP sockStream & S.mapM envelopeHandler

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
