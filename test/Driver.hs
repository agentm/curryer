import Test.Tasty
import Curryer.Test.Basic as Basic

main :: IO ()
main = defaultMain curryerTestTree

curryerTestTree :: TestTree
curryerTestTree = testGroup "curryer" [Basic.testTree]
  
