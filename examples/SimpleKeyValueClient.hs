{-# LANGUAGE DerivingVia, DeriveGeneric, OverloadedStrings #-}
import GHC.Generics
import Network.RPC.Curryer.Client
import Network.RPC.Curryer.Server (localHostAddr)
import Options.Generic
import Codec.Winery

data SetKey = SetKey String String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant SetKey

data GetKey = GetKey String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant GetKey

data CommandOptions = Get {name :: String}
                    | Set {name :: String, value :: String}
                    deriving (Generic, Show)

instance ParseRecord CommandOptions
                    
main :: IO ()
main = do
  opts <- getRecord "SimpleKeyValueClient"
  -- connect to the remote server (in this case on the localhost address)
  conn <- connect [] localHostAddr 8765
  case opts of
    Get k -> do
      --call the remote function and validate the result
      eRet <- call conn (GetKey k)
      case eRet of
        Left err -> error (show err)
        Right (Just val) -> putStrLn val
        Right Nothing -> error "no such key"
    Set k v -> do
      eRet <- call conn (SetKey k v)
      case eRet of
        Left err -> error (show err)
        Right () -> pure ()
