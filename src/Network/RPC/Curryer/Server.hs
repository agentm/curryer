{-# LANGUAGE DerivingVia, DeriveGeneric, RankNTypes, ScopedTypeVariables, MultiParamTypeClasses, OverloadedStrings, GeneralizedNewtypeDeriving, TypeApplications, CPP #-}
{- HLINT ignore "Use lambda-case" -}
module Network.RPC.Curryer.Server where
import Streamly
import qualified Streamly.Prelude as S
import Streamly.Network.Socket
import Streamly.Internal.Network.Socket (handleWithM)
import Network.Socket as Socket
import Network.Socket.ByteString as Socket
import Streamly.Internal.Data.Parser as P
import Codec.Winery
import Codec.Winery.Internal (varInt, decodeVarInt, getBytes)
import Codec.Winery.Class (mkExtractor)
import GHC.Generics
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
import qualified Data.UUID.V4 as UUIDBase

import qualified Network.RPC.Curryer.StreamlyAdditions as SA
import Control.Monad
import Data.Hashable
import System.Timeout
import qualified Network.ByteOrder as BO
import Data.Proxy

-- for toArrayS conversion
{-import qualified Data.ByteString.Internal as BSI
import qualified Streamly.Internal.Data.Array.Storable.Foreign.Types as SA
import Foreign.ForeignPtr (plusForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import GHC.Ptr (plusPtr)
-}
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

data Message a = Response UUID a
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
messageBoundaryP :: Parser IO Word8 BS.ByteString
messageBoundaryP = do
  let s = FL.toList
  w4x8 <- P.take 4 s
  --traceShowM ("w4x8"::String, w4x8)
  let c = fromIntegral (BO.word32 (BS.pack w4x8))
  --traceShowM ("c"::String, c)
  vals <- P.take c s
  let bytes = BS.pack vals
  --traceShowM ("parsedBytes"::String, c, BS.length bytes, bytes)
  pure bytes

type NewConnectionHandler msg = IO (Maybe msg)

type NewMessageHandler req resp = req -> IO (HandlerResponse resp)
  
serve :: forall req resp. (Show req, Serialise req, Serialise resp) =>
         NewConnectionHandler resp ->
         NewMessageHandler req resp ->
         HostAddr ->
         PortNumber ->
         Maybe (MVar SockAddr) ->
         IO Bool
serve connhandler userMsgHandler hostaddr port mSockLock = do
  let
      decoder :: NewMessageHandler req resp -> Decoder (Message req)
      decoder _ =
        case getDecoder (schema (Proxy @(Message req))) of
          Left exc -> error (show exc)
          Right dec -> dec
      handleSock sock = do
        mResp <- connhandler
        lockingSocket <- newLock sock
        case mResp of
          Nothing -> pure ()
          Just resp -> do
            requestID <- UUID <$> UUIDBase.nextRandom            
            sendMessage (AsyncRequest requestID resp) lockingSocket
        drainSocketMessages sock (decoder userMsgHandler) (serverMessageHandler lockingSocket userMsgHandler)
  serially (S.unfold (SA.acceptOnAddrWith [(ReuseAddr,1)] mSockLock) (hostaddr, port)) & parallely . S.mapM (handleWithM handleSock) & S.drain
  pure True

serverMessageHandler :: forall req resp. (Show req,
                          Serialise req,
                          Serialise resp)
                     => Locking Socket
                     -> NewMessageHandler req resp
                     -> Message req
                     -> IO ()
serverMessageHandler sockLock requestMessageHandler msg = do
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

--add callback to allow for responses via socket
type MessageHandler a = Message a -> IO ()

type AsyncMessageHandler a = a -> IO ()



drainSocketMessages :: Serialise msg => Socket -> Decoder (Message msg) -> MessageHandler msg -> IO ()
drainSocketMessages sock decoder msgHandler = do
  let sockStream = S.unfold readWithBufferOf (1024 * 4, sock)
      handler bs = do
        let decoded = evalDecoder decoder bs
        msgHandler decoded
  S.drain $ serially $ S.parseMany messageBoundaryP sockStream & S.mapM handler

--send length-tagged bytestring, perhaps should be in network byte order?
sendMessage :: Serialise a => Message a -> Locking Socket -> IO ()
sendMessage msg sockLock = do
  let 
      msgbytes = serialiseOnly msg
      fullbytes = lenbytes <> msgbytes
      len = BS.length msgbytes
      lenbytes = BO.bytestring32 (fromIntegral len)

  --Socket.sendAll syscalls send() on a loop until all the bytes are sent, so we need socket locking here to account for serialized messages of size > PIPE_BUF
  withLock sockLock $ \socket' ->
    Socket.sendAll socket' fullbytes
  traceBytes "sendMessage" fullbytes
