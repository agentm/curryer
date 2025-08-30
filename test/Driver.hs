import Test.Tasty
import Curryer.Test.Basic as Basic
import Curryer.Test.TLS as TLS

main :: IO ()
main = defaultMain curryerTestTree

curryerTestTree :: TestTree
curryerTestTree = testGroup "curryer" [Basic.testTree,
                                       TLS.testTree]
  
