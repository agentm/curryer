{-# LANGUAGE DerivingVia, DeriveGeneric #-}
import Network.RPC.Curryer.Server
import Control.Concurrent.STM
import StmContainers.Map as M
import GHC.Generics
import Codec.Winery
import Data.Functor

-- create data structures to represent remote function calls
data SetKey = SetKey String String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant SetKey

data GetKey = GetKey String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant GetKey

--call the `serve` function to handle incoming requests
main :: IO ()
main = do
  kvmap <- M.newIO
  void $ serveIPv4 kvRequestHandlers kvmap UnencryptedConnectionConfig localHostAddr 8765 Nothing

-- setup incoming request handlers to operate on the server's state
kvRequestHandlers :: RequestHandlers (M.Map String String)
kvRequestHandlers = [ RequestHandler $ \state (SetKey k v) ->
                        atomically $ M.insert v k (connectionServerState state)
                    , RequestHandler $ \state (GetKey k) ->
                        atomically $ M.lookup k (connectionServerState state)
                    ]
