{-# LANGUAGE StandaloneDeriving, DerivingVia, DeriveGeneric, RankNTypes, TypeApplications, ScopedTypeVariables, MultiParamTypeClasses #-}
module Network.RPC.Vintner.Server where
import Streamly
import qualified Streamly.Prelude as S
import qualified Streamly.Network.Inet.TCP as TCP
import Streamly.Network.Socket
import Streamly.Internal.Network.Socket (handleWithM, writeChunk)
import Network.Socket as Socket
import Streamly.Internal.Data.Parser.ParserD as PD
import Codec.Winery
import GHC.Generics
import Control.Concurrent.MVar (putMVar, MVar)
import Control.Exception
import Data.Function ((&))
import Data.Word
import Control.Monad.Catch
import qualified Data.ByteString as BS
import Streamly.Data.Fold as FL
import qualified Streamly.Internal.Data.Stream.IsStream as S
import Data.Foldable
import Data.Word
import Data.Bits
import qualified Streamly.Internal.Data.Array.Storable.Foreign.Types as SA

-- for toArrayS conversion
import qualified Data.ByteString.Internal as BSI
import Foreign.ForeignPtr (plusForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import GHC.Ptr (minusPtr, plusPtr)

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

data Response a = Response a
                | ExceptionResponse String
                deriving Generic
                deriving Serialise via WineryVariant (Response a)

data Request a = Request a
               | Services
               deriving Generic
               deriving Serialise via WineryVariant (Request a)

class Event a where
  dispatchAsyncEvent :: a -> IO ()
  dispatchEvent :: a -> IO (Response b)

type HostAddr = (Word8, Word8, Word8, Word8)

allHostAddrs = (0,0,0,0)
localHostAddr = (127,0,0,1)

-- Each message is length-prefixed by a 32-bit unsigned length.
messageBoundaryP :: Parser IO Word8 BS.ByteString
messageBoundaryP = do
  w4x8 <- PD.take 4 FL.toList
  let c = fromIntegral (fromOctets w4x8)
  vals <- PD.take c FL.toList
  pure (BS.pack vals)

serve :: Serialise msg =>
         (msg -> Socket -> IO ()) ->
         HostAddr ->
         PortNumber ->
         Maybe (MVar AddrInfo) ->
         IO Bool
serve handler hostaddr port mAddressMVar = do
  let handleSock sock = do
        let sockStream :: SerialT IO Word8
            sockStream = S.unfold readWithBufferOf (1024 * 4, sock)
            messageHandler bs = case deserialise bs of
              Left err -> error (show err) --FIXME
              Right val -> handler val sock
        drainSocketMessages sock messageHandler
  serially (S.unfold TCP.acceptOnAddr (hostaddr, port)) & parallely . S.mapM (handleWithM handleSock) & S.drain
  pure True

type MessageHandler a = a -> IO ()

drainSocketMessages :: Serialise msg => Socket -> MessageHandler msg -> IO ()
drainSocketMessages sock msgHandler = do
  let sockStream = S.unfold readWithBufferOf (1024 * 4, sock)
      handler bs =
        case deserialise bs of
          Left err -> error (show err) --FIXME
          Right val -> msgHandler val --add response function
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

sendMessage :: Serialise a => a -> Socket -> IO ()
sendMessage msg socket = writeChunk socket (toArrayS (serialise msg))

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
    endPtr = unsafeForeignPtrToPtr nfp `plusPtr` len

