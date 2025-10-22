# Curryer - Fast Haskell-to-Haskell RPC

Curryer (pun intended) is a fast, Haskell-exclusive RPC (remote procedure call) library. By using the latest Haskell serialization and streaming libraries, curryer aims to be the fastest and easiest means of communicating between Haskell-based processes.

Curryer is inspired by the now unmaintained [distributed-process](https://hackage.haskell.org/package/distributed-process) library, but is lighter-weight and uses a higher-performance serialization package.

## Features

* blocking and non-blocking remote function calls
* asynchronous server-to-client callbacks (for server-initiated notifications)
* timeouts
* leverages [winery](https://hackage.haskell.org/package/winery) for high-performance serialization
* TLS including mutual TLS (mTLS) authentication

## Requirements

* GHC 9.0+

## Code Example

[Server](examples/SimpleKeyValueServer.hs):

```haskell
data SetKey = SetKey String String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant SetKey

data GetKey = GetKey String
  deriving (Generic, Show)
  deriving Serialise via WineryVariant GetKey

main :: IO ()
main = do
  kvmap <- M.newIO
  void $ serve kvRequestHandlers kvmap localHostAddr 8765 Nothing
  
kvRequestHandlers :: RequestHandlers (M.Map String String)
kvRequestHandlers = [ RequestHandler $ \state (SetKey k v) ->
                        atomically $ M.insert v k (connectionServerState state)
                    , RequestHandler $ \state (GetKey k) ->
                        atomically $ M.lookup k (connectionServerState state)
                    ]
```

[Client](examples/SimpleKeyValueClient.hs):

```haskell
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
  conn <- connect [] localHostAddr 8765
  case opts of
    Get k -> do
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

```
