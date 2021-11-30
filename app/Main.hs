-- | Description: a simple executable to start a prometheus server
-- with the eventlog output.

{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Function
import GHC.Eventlog.Prometheus (start)
import System.IO

main :: IO ()
main = do
  start 8080

  let bonk x = do
        var <- newEmptyMVar
        mask \restore -> do
          void $ forkIO do
            try @SomeException (restore . evaluate $ naiveFib x) >>= putMVar var
        pure var

  hSetBuffering stdout NoBuffering
  putStrLn "how high to fib?"
  putStr "> "
  c <- read <$> getLine
  fix \again -> do
    _res <- traverse (takeMVar <=< bonk) [0 .. c]
    putChar '.'
    again

naiveFib :: Int -> Int
naiveFib = \case
  0 -> 0
  1 -> 1
  n -> naiveFib (n - 2) + naiveFib (n - 1)
