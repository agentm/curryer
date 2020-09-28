{-# LANGUAGE DerivingVia, DeriveGeneric, RankNTypes, ScopedTypeVariables, MultiParamTypeClasses, OverloadedStrings, GeneralizedNewtypeDeriving #-}
{-# HLINT ignore "Use lambda-case" #-}
module Network.RPC.Curryer.Server where
import Streamly
import qualified Streamly.Prelude as S
import Streamly.Network.Socket
import Streamly.Internal.Network.Socket (handleWithM, writeChunk)
import Network.Socket as Socket
import Streamly.Internal.Data.Parser.ParserD as PD
import Codec.Winery
import Codec.Winery.Internal (varInt, decodeVarInt, getBytes)
import Codec.Winery.Class (mkExtractor)
import GHC.Generics
import Control.Concurrent.MVar (MVar)
import Control.Exception
import Data.Function ((&))
import Data.Word
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.FastBuilder as BB
import Streamly.Data.Fold as FL
import qualified Streamly.Internal.Data.Stream.IsStream as S
import Data.Foldable
import Data.Bits
import qualified Data.Binary as B
import qualified Data.UUID as UUIDBase
import qualified Streamly.Internal.Data.Array.Storable.Foreign.Types as SA
import qualified Network.RPC.Curryer.StreamlyAdditions as SA
import Control.Monad
import Data.Hashable

-- for toArrayS conversion
import qualified Data.ByteString.Internal as BSI
import Foreign.ForeignPtr (plusForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import GHC.Ptr (plusPtr)

import Debug.Trace

data ClientHelloMessage = ClientHelloMessage Int Int
  deriving Generic
  deriving Serialise via WineryVariant ClientHelloMessage

data ServerHelloMessage = ServerHelloMessage { serverServices :: [String],
                                               serverInfo :: String
                                               }
                          deriving Generic
                          deriving Serialise via WineryRecord ServerHelloMessage

--request-response token
--client-side timeout
--server-to-client and client-to-server async request (no response requested)

data Message a = Response UUID a
                | AsyncRequest a
                | ResponseExpectedRequest UUID a
                -- | Services                
                | ExceptionResponse String
                deriving (Generic, Show)
                deriving Serialise via WineryVariant (Message a)

-- | The response type 
data HandlerResponse a = NoResponse
                       | HandlerResponse a
                       | HandlerException a
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
                     deriving (Generic, Show, Eq)
                     deriving Serialise via WineryVariant ConnectionError

type HostAddr = (Word8, Word8, Word8, Word8)

allHostAddrs,localHostAddr :: HostAddr
allHostAddrs = (0,0,0,0)
localHostAddr = (127,0,0,1)

-- Each message is length-prefixed by a 32-bit unsigned length.
messageBoundaryP :: Parser IO Word8 BS.ByteString
messageBoundaryP = do
  --traceShowM "message!"
  w4x8 <- PD.take 4 FL.toList
  --traceShowM ("w4x8",w4x8)
  let c = fromIntegral (fromOctets w4x8)
  --traceShowM ("c", c)
  vals <- PD.take c FL.toList
  let bytes = BS.pack vals
  traceShowM ("vals", BS.length bytes, bytes)
  pure bytes

type NewConnectionHandler msg = IO (Maybe msg)

type NewMessageHandler msg resp = msg -> IO (HandlerResponse resp)
  
serve :: (Show msg, Serialise msg, Serialise resp) =>
         NewConnectionHandler resp ->
         NewMessageHandler msg resp ->
         HostAddr ->
         PortNumber ->
         Maybe (MVar SockAddr) ->
         IO Bool
serve connhandler msghandler hostaddr port mSockLock = do
  let handleSock sock = do
        putStrLn "handleSock"
        let messageHandler msg = do
              putStrLn $ "GOT MSG " ++ show msg
              case msg of
                Response{} -> putStrLn "client sent response"
                ResponseExpectedRequest requestID val -> do
                  putStrLn "ResponseExp"
                  resp <- msghandler val
                  case resp of
                    HandlerResponse responseVal -> sendMessage (Response requestID responseVal) sock
                    NoResponse -> error "attempt to return non-response to expected response message"
                    HandlerException _ -> error "TODO HandlerException"
                AsyncRequest val -> do
                  putStrLn "AsyncReq"
                  void $ msghandler val
                  --no response necessaryxs
                ExceptionResponse{} -> putStrLn "client sent exception response"
        -- allow the server to send an async welcome message to the new client, if necessary
        mResp <- connhandler
        case mResp of
          Nothing -> pure ()
          Just resp -> sendMessage (AsyncRequest resp) sock
        drainSocketMessages sock messageHandler
  serially (S.unfold (SA.acceptOnAddrWith [(ReuseAddr,1)] mSockLock) (hostaddr, port)) & parallely . S.mapM (handleWithM handleSock) & S.drain
  pure True

--add callback to allow for responses via socket
type MessageHandler a = Message a -> IO ()

type AsyncMessageHandler a = a -> IO ()

drainSocketMessages :: Serialise msg => Socket -> MessageHandler msg -> IO ()
drainSocketMessages sock msgHandler = do
  let sockStream = S.unfold readWithBufferOf (1024 * 4, sock)
      handler bs = do
        --print ("drain handler", bs)
        case deserialise bs of
          Left err ->
            print err
          Right val -> do
            --putStrLn "deserialized value for msgHandler"
            msgHandler val --add response function
  S.drain $ S.parseManyD messageBoundaryP sockStream & S.mapM handler

fromOctets :: [Word8] -> Word32
fromOctets = foldl' accum 0
  where
    accum a o = (a `shiftL` 8) .|. fromIntegral o

octets :: Word32 -> [Word8]
octets w = 
    [ fromIntegral (w `shiftR` 24)
    , fromIntegral (w `shiftR` 16)
    , fromIntegral (w `shiftR` 8)
    , fromIntegral w
    ]

--send length-tagged bytestring, perhaps should be in network byte order?
sendMessage :: Serialise a => a -> Socket -> IO ()
sendMessage msg socket' = do
  putStrLn ("sending bytes: " ++ show (blen <> bytes))
  writeChunk socket' (toArrayS (blen <> bytes))
  where
    bytes = serialise msg
    len = BS.length bytes
    blen = BS.pack (octets (fromIntegral len))


--from streamly-bytestring
-- | Convert a 'ByteString' to an array of 'Word8'. This function unwraps the
-- 'ByteString' and wraps it with 'Array' constructors and hence the operation
-- is performed in constant time.
{-# INLINE toArrayS #-}
toArrayS :: BS.ByteString -> SA.Array Word8
--slow path
--toArrayS = SA.fromList . BS.unpack
toArrayS (BSI.PS fp off len) = SA.Array nfp endPtr
  where
    nfp = fp `plusForeignPtr` off
    endPtr = unsafeForeignPtrToPtr nfp `plusPtr` len `plusPtr` 1 -- ? why +1?

