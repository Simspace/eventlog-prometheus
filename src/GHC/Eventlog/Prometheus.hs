-- | Description: Expose eventlog aggregates as a prometheus server

{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module GHC.Eventlog.Prometheus
  ( start,
  )
where

import Control.Concurrent
import Control.Exception (SomeException, finally, mask, onException, try)
import Data.Array (Array, listArray, (!))
import qualified Data.ByteString as B
import qualified Data.Text as T
import Data.Traversable (for)
import qualified GHC.Eventlog.Socket as Sock
import GHC.RTS.Events
import GHC.RTS.Events.Incremental (Decoder (..), decodeEvents, decodeHeader)
import qualified Network.Socket as N
import qualified Network.Socket.ByteString as NBS
import System.Exit (exitFailure, exitSuccess)
import System.Metrics.Prometheus.Concurrent.Registry (Registry, registerCounter, sample)
import qualified System.Metrics.Prometheus.Concurrent.Registry as Registry
import System.Metrics.Prometheus.Http.Scrape (serveMetrics)
import System.Metrics.Prometheus.Metric.Counter (Counter)
import qualified System.Metrics.Prometheus.Metric.Counter as Counter
import System.Metrics.Prometheus.MetricId (Name (..), addLabel, fromList)
import System.Posix (forkProcess, mkdtemp, removeDirectory, removeLink)

start :: Int -> IO ()
start port = mask \restore -> do
  capCount <- getNumCapabilities
  tmpdir <- mkdtemp "/tmp/eventlog"
  let sockPath = tmpdir <> "/socket"
  let startCollectorProcess = do
        sock <- N.socket N.AF_UNIX N.Stream N.defaultProtocol `onException` removeLink sockPath
        flip onException (N.close sock) do
          N.connect sock (N.SockAddrUnix sockPath) `finally` removeLink sockPath
          restore do
            (r, m) <- createMetrics capCount
            startPrometheusServer port r m sock
  let createSocketAndFork = do
        Sock.start sockPath
        _cpid <- forkProcess (startCollectorProcess `finally` removeDirectory tmpdir)
        pure ()
  createSocketAndFork `onException` (removeLink sockPath >> removeDirectory tmpdir)
  Sock.wait

data Metrics = Metrics
  { threadHeapOverflowCount :: {-# UNPACK #-} !Counter,
    threadStackOverflowCount :: {-# UNPACK #-} !Counter,
    threadYieldCount :: {-# UNPACK #-} !Counter,
    threadBlockedCount :: {-# UNPACK #-} !Counter,
    threadFinishedCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnForeignCallCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnMvarCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnMvarReadCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnBlackHoleCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnReadCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnWriteCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnDelayCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnStmCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnMsgThrowToCount :: {-# UNPACK #-} !Counter,
    threadBlockedOnOtherCount :: {-# UNPACK #-} !Counter,
    threadCreateCount :: {-# UNPACK #-} !Counter,
    threadMigrateInCount :: {-# UNPACK #-} !Counter,
    threadMigrateOutCount :: {-# UNPACK #-} !Counter,
    threadWakeupSendCount :: {-# UNPACK #-} !Counter,
    threadWakeupRecvCount :: {-# UNPACK #-} !Counter,
    threadRunCount :: {-# UNPACK #-} !Counter
  }

startPrometheusServer :: Int -> Registry -> Array Int Metrics -> N.Socket -> IO ()
startPrometheusServer port r m sock = do
  ptid <- myThreadId
  mask \restore -> do
    _ <- forkIO do
      restore (withEvents sock (trackEvents m)) `finally` killThread ptid
    pure ()
  serveMetrics port [] (sample r)

createMetrics :: Int -> IO (Registry, Array Int Metrics)
createMetrics capCount = do
  r <- Registry.new
  cs <- for [0 .. capCount - 1] \capNum -> do
    let mkCounter txt lbls =
          registerCounter
            (Name txt)
            (addLabel "capability" capNumTxt (fromList lbls))
            r
        capNumTxt = T.pack (show capNum)

    threadRunCount <- mkCounter "thread_run_count" []
    threadCreateCount <- mkCounter "thread_create_count" []
    threadMigrateInCount <- mkCounter "thread_migrate_count" [("type", "recv")]
    threadMigrateOutCount <- mkCounter "thread_migrate_count" [("type", "send")]
    threadWakeupSendCount <- mkCounter "thread_wakeup_count" [("type", "send")]
    threadWakeupRecvCount <- mkCounter "thread_wakeup_count" [("type", "recv")]
    threadHeapOverflowCount <- mkCounter "thread_stop_count" [("status", "heap_overflow")]
    threadStackOverflowCount <- mkCounter "thread_stop_count" [("status", "stack_overflow")]
    threadYieldCount <- mkCounter "thread_stop_count" [("status", "yield")]
    threadBlockedOnOtherCount <- mkCounter "thread_stop_count" [("status", "other")]
    threadBlockedCount <- mkCounter "thread_stop_count" [("status", "blocked")]
    threadBlockedOnMvarCount <- mkCounter "thread_stop_count" [("status", "mvar")]
    threadBlockedOnMvarReadCount <- mkCounter "thread_stop_count" [("status", "mvar_read")]
    threadBlockedOnBlackHoleCount <- mkCounter "thread_stop_count" [("status", "black_hole")]
    threadBlockedOnReadCount <- mkCounter "thread_stop_count" [("status", "read")]
    threadBlockedOnWriteCount <- mkCounter "thread_stop_count" [("status", "write")]
    threadBlockedOnDelayCount <- mkCounter "thread_stop_count" [("status", "delay")]
    threadBlockedOnStmCount <- mkCounter "thread_stop_count" [("status", "stm")]
    threadBlockedOnForeignCallCount <- mkCounter "thread_stop_count" [("status", "foreign_call")]
    threadBlockedOnMsgThrowToCount <- mkCounter "thread_stop_count" [("status", "throw_to")]
    threadFinishedCount <- mkCounter "thread_stop_count" [("status", "finished")]
    pure Metrics {..}

  pure (r, listArray (0, length cs - 1) cs)

trackEvents :: Array Int Metrics -> Event -> IO ()
trackEvents m = \case
  Event _ ei (Just capN) ->
    let capM = m ! capN
     in case ei of
          CreateThread _ -> Counter.inc (threadCreateCount capM)
          MigrateThread _ tgt -> do
            let tgtM = m ! tgt
            Counter.inc (threadMigrateOutCount capM)
            Counter.inc (threadMigrateInCount tgtM)
          StopThread _ st -> case st of
            HeapOverflow -> Counter.inc (threadHeapOverflowCount capM)
            StackOverflow -> Counter.inc (threadStackOverflowCount capM)
            ThreadYielding -> Counter.inc (threadYieldCount capM)
            ThreadBlocked -> Counter.inc (threadBlockedCount capM)
            ThreadFinished -> Counter.inc (threadFinishedCount capM)
            ForeignCall -> Counter.inc (threadBlockedOnForeignCallCount capM)
            BlockedOnMVar -> Counter.inc (threadBlockedOnMvarCount capM)
            BlockedOnMVarRead -> Counter.inc (threadBlockedOnMvarReadCount capM)
            BlockedOnBlackHole -> Counter.inc (threadBlockedOnBlackHoleCount capM)
            BlockedOnRead -> Counter.inc (threadBlockedOnReadCount capM)
            BlockedOnWrite -> Counter.inc (threadBlockedOnWriteCount capM)
            BlockedOnDelay -> Counter.inc (threadBlockedOnDelayCount capM)
            BlockedOnSTM -> Counter.inc (threadBlockedOnStmCount capM)
            BlockedOnMsgThrowTo -> Counter.inc (threadBlockedOnMsgThrowToCount capM)
            _ -> Counter.inc (threadBlockedOnOtherCount capM)
          RunThread _ -> Counter.inc (threadRunCount capM)
          WakeupThread _ tgt -> do
            Counter.inc (threadWakeupSendCount capM)
            Counter.inc (threadWakeupRecvCount (m ! tgt))
          _ -> pure ()
  _ -> pure ()

withEvents :: N.Socket -> (Event -> IO ()) -> IO ()
withEvents sock k = do
  let getBytes :: IO B.ByteString
      getBytes =
        NBS.recv sock 4096 >>= \bs -> case B.null bs of
          True -> exitSuccess
          False -> pure bs

  let getHeader :: IO (Header, B.ByteString)
      getHeader =
        let loop mhdr = \case
              Consume cont -> do
                loop mhdr . cont =<< getBytes
              Produce a d -> loop (Just a) d
              Done leftoverBytes -> case mhdr of
                Nothing -> exitFailure
                Just hdr -> pure (hdr, leftoverBytes)
              Error lo errStr -> case errStr of
                "Header begin marker not found" ->
                  -- There can be some extra bytes written to the socket before the eventlog header. I think this
                  -- is caused by the eventlog buffers not getting cleared after we halt the eventlog. To work
                  -- around this we drop bytes until we hit the first byte of the header. If that doesn't parse as
                  -- a header we drop until the next first byte of the header.
                  case decodeHeader of
                    Consume cont -> do
                      bs <-
                        let lo' = B.dropWhile (/= 104) (B.drop 1 lo)
                         in case B.null lo' of
                              True -> getBytes
                              False -> pure lo'
                      loop mhdr (cont bs)
                    _ -> error "getHeader: getHeader doesn't first consume"
                _ -> error errStr
         in loop Nothing decodeHeader

  let getEvents = \case
        Consume cont -> do
          getEvents . cont =<< getBytes
        Produce a d -> do
          _ <- try @SomeException (k a)
          getEvents d
        Done _ -> pure ()
        Error _ errmsg -> do
          error ("withEventSock: " <> show errmsg)

  (hdr, leftoverBytes) <- getHeader

  initialDecoder <- case decodeEvents hdr of
    Consume cont -> do
      bs <- case B.null leftoverBytes of
        True -> getBytes
        False -> pure leftoverBytes
      pure (cont bs)
    _ -> error "initialDecoder: decodeEvents doesn't first consume"

  getEvents initialDecoder
