-- | Description: Expose eventlog aggregates as a prometheus server

{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module GHC.Eventlog.Prometheus
  ( start,
  )
where

import Data.Word
import Data.IORef
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
    threadRunCount :: {-# UNPACK #-} !Counter,
    threadHeapOverflowTime :: {-# UNPACK #-} !Counter,
    threadStackOverflowTime :: {-# UNPACK #-} !Counter,
    threadYieldTime :: {-# UNPACK #-} !Counter,
    threadBlockedTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnForeignCallTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnMvarTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnMvarReadTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnBlackHoleTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnReadTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnWriteTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnDelayTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnStmTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnMsgThrowToTime :: {-# UNPACK #-} !Counter,
    threadBlockedOnOtherTime :: {-# UNPACK #-} !Counter,
    threadFinishedTime :: {-# UNPACK #-} !Counter,
    threadRunTime :: {-# UNPACK #-} !Counter,
    gcTime :: {-# UNPACK #-} !Counter,
    lastEvTime :: {-# UNPACK #-} !(IORef Word64),
    lastEvTimeCounter :: {-# UNPACK #-} !(IORef (Maybe Counter))
  }

startPrometheusServer :: Int -> Registry -> Array Int Metrics -> N.Socket -> IO ()
startPrometheusServer port r m sock = do
  ptid <- myThreadId
  mask \restore -> do
    _ <- forkIO do
      restore (withEvents sock (trackEvents m)) `finally` killThread ptid
    pure ()
  serveMetrics port ["metrics"] (sample r)

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
    threadHeapOverflowTime <- mkCounter "thread_stop_time" [("status", "heap_overflow")]
    threadStackOverflowTime <- mkCounter "thread_stop_time" [("status", "stack_overflow")]
    threadYieldTime <- mkCounter "thread_stop_time" [("status", "yield")]
    threadBlockedOnOtherTime <- mkCounter "thread_stop_time" [("status", "other")]
    threadBlockedTime <- mkCounter "thread_stop_time" [("status", "blocked")]
    threadBlockedOnMvarTime <- mkCounter "thread_stop_time" [("status", "mvar")]
    threadBlockedOnMvarReadTime <- mkCounter "thread_stop_time" [("status", "mvar_read")]
    threadBlockedOnBlackHoleTime <- mkCounter "thread_stop_time" [("status", "black_hole")]
    threadBlockedOnReadTime <- mkCounter "thread_stop_time" [("status", "read")]
    threadBlockedOnWriteTime <- mkCounter "thread_stop_time" [("status", "write")]
    threadBlockedOnDelayTime <- mkCounter "thread_stop_time" [("status", "delay")]
    threadBlockedOnStmTime <- mkCounter "thread_stop_time" [("status", "stm")]
    threadBlockedOnForeignCallTime <- mkCounter "thread_stop_time" [("status", "foreign_call")]
    threadBlockedOnMsgThrowToTime <- mkCounter "thread_stop_time" [("status", "throw_to")]
    threadFinishedTime <- mkCounter "thread_stop_time" [("status", "finished")]
    threadRunTime <- mkCounter "thread_run_time" []
    gcTime <- mkCounter "gc_time" []
    lastEvTime <- newIORef 0
    lastEvTimeCounter <- newIORef Nothing
    pure Metrics {..}

  pure (r, listArray (0, length cs - 1) cs)

trackEvents :: Array Int Metrics -> Event -> IO ()
trackEvents m = \case
  Event et ei (Just capN) ->
    let capM = m ! capN
        updateState timeSel mcountSel = do
          prevTime <- readIORef (lastEvTime capM)
          mPrevEv <- readIORef (lastEvTimeCounter capM)
          case mPrevEv of
            Nothing -> pure ()
            Just prevEv ->
              let delta = fromIntegral (et - prevTime)
              in Counter.add delta prevEv
          case mcountSel of
            Nothing -> pure ()
            Just countSel -> Counter.inc (countSel capM)
          writeIORef (lastEvTime capM) et
          writeIORef (lastEvTimeCounter capM) (Just (timeSel capM))
        updateTC a b = updateState a (Just b)
        updateT a = updateState a Nothing
     in case ei of
          CreateThread _ -> Counter.inc (threadCreateCount capM)
          MigrateThread _ tgt -> do
            let tgtM = m ! tgt
            Counter.inc (threadMigrateOutCount capM)
            Counter.inc (threadMigrateInCount tgtM)
          StopThread _ st -> do
            case st of
              HeapOverflow -> updateTC threadHeapOverflowTime threadHeapOverflowCount
              StackOverflow -> updateTC threadStackOverflowTime threadStackOverflowCount
              ThreadYielding -> updateTC threadYieldTime threadYieldCount
              ThreadBlocked -> updateTC threadBlockedTime threadBlockedCount
              ThreadFinished -> updateTC threadFinishedTime threadFinishedCount
              ForeignCall -> updateTC threadBlockedOnForeignCallTime threadBlockedOnForeignCallCount
              BlockedOnMVar -> updateTC threadBlockedOnMvarTime threadBlockedOnMvarCount
              BlockedOnMVarRead -> updateTC threadBlockedOnMvarReadTime threadBlockedOnMvarReadCount
              BlockedOnBlackHole -> updateTC threadBlockedOnBlackHoleTime threadBlockedOnBlackHoleCount
              BlockedOnRead -> updateTC threadBlockedOnReadTime threadBlockedOnReadCount
              BlockedOnWrite -> updateTC threadBlockedOnWriteTime threadBlockedOnWriteCount
              BlockedOnDelay -> updateTC threadBlockedOnDelayTime threadBlockedOnDelayCount
              BlockedOnSTM -> updateTC threadBlockedOnStmTime threadBlockedOnStmCount
              BlockedOnMsgThrowTo -> updateTC threadBlockedOnMsgThrowToTime threadBlockedOnMsgThrowToCount
              _ -> updateTC threadBlockedOnOtherTime threadBlockedOnOtherCount
          RunThread _ -> updateTC threadRunTime threadRunCount
          RequestParGC -> updateT gcTime
          RequestSeqGC -> updateT gcTime
          StartGC -> updateT gcTime
          WakeupThread _ tgt -> do
            Counter.inc (threadWakeupSendCount capM)
            Counter.inc (threadWakeupRecvCount (m ! tgt))
          _ -> pure ()
  _ -> pure ()

withEvents :: N.Socket -> (Event -> IO ()) -> IO ()
withEvents sock eventContinuation = do
  let getBytes :: IO B.ByteString
      getBytes =
        NBS.recv sock 4096 >>= \bs -> case B.null bs of
          True -> exitSuccess
          False -> pure bs

  let getHeader :: IO (Header, B.ByteString)
  -- The bytes returned here are leftover bytes after we parse the
  -- header, so they should be fed into the event parser
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
          _ <- try @SomeException (eventContinuation a)
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
