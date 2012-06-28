-- | [Cloud Haskell]
-- 
-- This is an implementation of Cloud Haskell, as described in 
-- /Towards Haskell in the Cloud/ by Jeff Epstein, Andrew Black, and Simon
-- Peyton Jones
-- (<http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/>),
-- although some of the details are different. The precise message passing
-- semantics are based on /A unified semantics for future Erlang/ by	Hans
-- Svensson, Lars-Åke Fredlund and Clara Benac Earle.
module Control.Distributed.Process 
  ( -- * Basic types 
    ProcessId
  , NodeId
  , Process
    -- * Basic messaging
  , send 
  , expect
    -- * Channels
  , ReceivePort
  , SendPort
  , newChan
  , sendChan
  , receiveChan
  , mergePortsBiased
  , mergePortsRR
    -- * Advanced messaging
  , Match
  , receiveWait
  , receiveTimeout
  , match
  , matchIf
  , matchUnknown
    -- * Process management
  , spawn
  , call
  , terminate
  , ProcessTerminationException(..)
  , SpawnRef
  , getSelfPid
  , getSelfNode
    -- * Monitoring and linking
  , link
  , unlink
  , monitor
  , unmonitor
  , LinkException(..)
  , MonitorRef -- opaque
  , MonitorNotification(..)
  , DiedReason(..)
  , DidUnmonitor(..)
  , DidUnlink(..)
    -- * Closures
  , Closure
  , Static
  , unClosure
  , RemoteTable
    -- * Auxiliary API
  , catch
  , expectTimeout
  , spawnAsync
  , spawnSupervised
  ) where

import Prelude hiding (catch)
import Data.Binary (decode)
import Data.Typeable (Typeable, typeOf)
import Control.Monad.Reader (ask)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throw)
import qualified Control.Exception as Exception (catch)
import Control.Concurrent.MVar (modifyMVar)
import Control.Concurrent.Chan (writeChan)
import Control.Concurrent.STM 
  ( STM
  , atomically
  , orElse
  , newTChan
  , readTChan
  , newTVar
  , readTVar
  , writeTVar
  )
import Control.Distributed.Process.Internal.CQueue (dequeue, BlockSpec(..))
import Control.Distributed.Process.Serializable (Serializable, fingerprint)
import Data.Accessor ((^.), (^:), (^=))
import Control.Distributed.Process.Internal.Types 
  ( RemoteTable
  , NodeId(..)
  , ProcessId(..)
  , LocalNode(..)
  , LocalProcess(..)
  , Process(..)
  , Closure(..)
  , Static(..)
  , Message(..)
  , MonitorRef(..)
  , MonitorNotification(..)
  , LinkException(..)
  , DidUnmonitor(..)
  , DidUnlink(..)
  , DiedReason(..)
  , SpawnRef(..)
  , DidSpawn(..)
  , NCMsg(..)
  , ProcessSignal(..)
  , monitorCounter 
  , spawnCounter
  , Closure(..)
  , SendPort(..)
  , ReceivePort(..)
  , channelCounter
  , typedChannelWithId
  , TypedChannel(..)
  , ChannelId(..)
  , Identifier(..)
  , procMsg
  , SerializableDict(..)
  )
import Control.Distributed.Process.Internal.MessageT 
  ( sendMessage
  , sendBinary
  , getLocalNode
  )  
import Control.Distributed.Process.Internal.Dynamic (fromDyn, dynTypeRep)
import Control.Distributed.Process.Internal.Closure (resolveClosure)
import Control.Distributed.Process.Internal.Node (runLocalProcess)
import {-# SOURCE #-} Control.Distributed.Process.Internal.Closure.BuiltIn 
  ( linkClosure
  , sendClosure
  )
import Control.Distributed.Process.Internal.Closure.Combinators (cpSeq, cpBind)

-- INTERNAL NOTES
-- 
-- 1.  'send' never fails. If you want to know that the remote process received
--     your message, you will need to send an explicit acknowledgement. If you
--     want to know when the remote process failed, you will need to monitor
--     that remote process.
--
-- 2.  'send' may block (when the system TCP buffers are full, while we are
--     trying to establish a connection to the remote endpoint, etc.) but its
--     return does not imply that the remote process received the message (much
--     less processed it)
--
-- 3.  Message delivery is reliable and ordered. That means that if process A
--     sends messages m1, m2, m3 to process B, B will either arrive all three
--     messages in order (m1, m2, m3) or a prefix thereof; messages will not be
--     'missing' (m1, m3) or reordered (m1, m3, m2)
--
-- In order to guarantee (3), we stipulate that
--
-- 3a. We do not garbage collect connections because Network.Transport provides
--     ordering guarantees only *per connection*.
--
-- 3b. Once a connection breaks, we have no way of knowing which messages
--     arrived and which did not; hence, once a connection fails, we assume the
--     remote process to be forever unreachable. Otherwise we might sent m1 and
--     m2, get notified of the broken connection, reconnect, send m3, but only
--     m1 and m3 arrive.
--
-- 3c. As a consequence of (3b) we should not reuse PIDs. If a process dies,
--     we consider it forever unreachable. Hence, new processes should get new
--     IDs or they too would be considered unreachable.
--
-- Main reference for Cloud Haskell is
--
-- [1] "Towards Haskell in the Cloud", Jeff Epstein, Andrew Black and Simon
--     Peyton-Jones.
--       http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
--
-- The precise semantics for message passing is based on
-- 
-- [2] "A Unified Semantics for Future Erlang", Hans Svensson, Lars-Ake Fredlund
--     and Clara Benac Earle (not freely available online, unfortunately)
--
-- Some pointers to related documentation about Erlang, for comparison and
-- inspiration: 
--
-- [3] "Programming Distributed Erlang Applications: Pitfalls and Recipes",
--     Hans Svensson and Lars-Ake Fredlund 
--       http://man.lupaworld.com/content/develop/p37-svensson.pdf
-- [4] The Erlang manual, sections "Message Sending" and "Send" 
--       http://www.erlang.org/doc/reference_manual/processes.html#id82409
--       http://www.erlang.org/doc/reference_manual/expressions.html#send
-- [5] Questions "Is the order of message reception guaranteed?" and
--     "If I send a message, is it guaranteed to reach the receiver?" of
--     the Erlang FAQ
--       http://www.erlang.org/faq/academic.html
-- [6] "Delivery of Messages", post on erlang-questions
--       http://erlang.org/pipermail/erlang-questions/2012-February/064767.html

--------------------------------------------------------------------------------
-- Basic messaging                                                            --
--------------------------------------------------------------------------------

-- | Send a message
send :: Serializable a => ProcessId -> a -> Process ()
-- This requires a lookup on every send. If we want to avoid that we need to
-- modify serializable to allow for stateful (IO) deserialization
-- Warning: if we change how 'send' is implemented, might also want to change
-- the implementation of 'Internal.Closure.TH.generateSender'
send them msg = procMsg $ sendMessage (ProcessIdentifier them) msg 

-- | Wait for a message of a specific type
expect :: forall a. Serializable a => Process a
expect = receiveWait [match return] 

--------------------------------------------------------------------------------
-- Channels                                                                   --
--------------------------------------------------------------------------------

-- | Create a new typed channel
newChan :: Serializable a => Process (SendPort a, ReceivePort a)
newChan = do
  proc <- ask 
  liftIO . modifyMVar (processState proc) $ \st -> do
    chan <- liftIO . atomically $ newTChan
    let lcid  = st ^. channelCounter
        cid   = ChannelId { channelProcessId = processId proc
                          , channelLocalId   = lcid
                          }
        sport = SendPort cid 
        rport = ReceivePortSingle chan
        tch   = TypedChannel chan 
    return ( (channelCounter ^: (+ 1))
           . (typedChannelWithId lcid ^= Just tch)
           $ st
           , (sport, rport)
           )

-- | Send a message on a typed channel
sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan (SendPort them) msg = procMsg $ sendBinary (ChannelIdentifier them) msg 

-- | Wait for a message on a typed channel
receiveChan :: Serializable a => ReceivePort a -> Process a
receiveChan = liftIO . atomically . receiveSTM 
  where
    receiveSTM :: ReceivePort a -> STM a
    receiveSTM (ReceivePortSingle c) = 
      readTChan c
    receiveSTM (ReceivePortBiased ps) =
      foldr1 orElse (map receiveSTM ps)
    receiveSTM (ReceivePortRR psVar) = do
      ps <- readTVar psVar
      a  <- foldr1 orElse (map receiveSTM ps)
      writeTVar psVar (rotate ps)
      return a

    rotate :: [a] -> [a]
    rotate []     = []
    rotate (x:xs) = xs ++ [x]

-- | Merge a list of typed channels.
-- 
-- The result port is left-biased: if there are messages available on more
-- than one port, the first available message is returned.
mergePortsBiased :: Serializable a => [ReceivePort a] -> Process (ReceivePort a)
mergePortsBiased = return . ReceivePortBiased 

-- | Like 'mergePortsBiased', but with a round-robin scheduler (rather than
-- left-biased)
mergePortsRR :: Serializable a => [ReceivePort a] -> Process (ReceivePort a)
mergePortsRR ps = liftIO . atomically $ ReceivePortRR <$> newTVar ps

--------------------------------------------------------------------------------
-- Advanced messaging                                                         -- 
--------------------------------------------------------------------------------

-- | Opaque type used in 'receiveWait' and 'receiveTimeout'
newtype Match b = Match { unMatch :: Message -> Maybe (Process b) }

-- | Test the matches in order against each message in the queue
receiveWait :: [Match b] -> Process b
receiveWait ms = do
  queue <- processQueue <$> ask
  Just proc <- liftIO $ dequeue queue Blocking (map unMatch ms)
  proc

-- | Like 'receiveWait' but with a timeout.
-- 
-- If the timeout is zero do a non-blocking check for matching messages.
receiveTimeout :: Int -> [Match b] -> Process (Maybe b)
receiveTimeout t ms = do
  queue <- processQueue <$> ask
  let blockSpec = if t == 0 then NonBlocking else Timeout t
  mProc <- liftIO $ dequeue queue blockSpec (map unMatch ms)
  case mProc of
    Nothing   -> return Nothing
    Just proc -> Just <$> proc

-- | Match against any message of the right type
match :: forall a b. Serializable a => (a -> Process b) -> Match b
match = matchIf (const True) 

-- | Match against any message of the right type that satisfies a predicate
matchIf :: forall a b. Serializable a => (a -> Bool) -> (a -> Process b) -> Match b
matchIf c p = Match $ \msg -> 
  let decoded :: a
      decoded = decode . messageEncoding $ msg in
  if messageFingerprint msg == fingerprint (undefined :: a) && c decoded
    then Just $ p decoded 
    else Nothing

-- | Remove any message from the queue
matchUnknown :: Process b -> Match b
matchUnknown = Match . const . Just

--------------------------------------------------------------------------------
-- Process management                                                         --
--------------------------------------------------------------------------------

-- | Spawn a process
spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn nid proc = do
  ref <- spawnAsync nid proc 
  receiveWait [ matchIf (\(DidSpawn ref' _) -> ref == ref')
                        (\(DidSpawn _ pid) -> return pid)
              ]

-- | Run a process remotely and wait for it to reply
call :: SerializableDict a -> NodeId -> Closure (Process a) -> Process a
call sdict@SerializableDict nid proc = do 
  us <- getSelfPid
  spawn nid (proc `cpBind` sendClosure sdict us)
  expect

-- | Thrown by 'terminate'
data ProcessTerminationException = ProcessTerminationException
  deriving (Show, Typeable)

instance Exception ProcessTerminationException

-- | Terminate (throws a ProcessTerminationException)
terminate :: Process a
terminate = liftIO $ throw ProcessTerminationException

-- | Our own process ID
getSelfPid :: Process ProcessId
getSelfPid = processId <$> ask 

-- | Get the node ID of our local node
getSelfNode :: Process NodeId
getSelfNode = localNodeId <$> procMsg getLocalNode

--------------------------------------------------------------------------------
-- Monitoring and linking                                                     --
--------------------------------------------------------------------------------

-- | Link to a remote process (asynchronous)
--
-- Note that 'link' provides unidirectional linking (see 'spawnSupervised').
link :: ProcessId -> Process ()
link = sendCtrlMsg Nothing . Link

-- | Remove a link (asynchronous)
unlink :: ProcessId -> Process ()
unlink = sendCtrlMsg Nothing . Unlink

-- | Monitor another process (asynchronous)
monitor :: ProcessId -> Process MonitorRef 
monitor them = do
  monitorRef <- getMonitorRefFor them
  sendCtrlMsg Nothing $ Monitor them monitorRef
  return monitorRef

-- | Remove a monitor (asynchronous)
unmonitor :: MonitorRef -> Process ()
unmonitor = sendCtrlMsg Nothing . Unmonitor

--------------------------------------------------------------------------------
-- Closures                                                                   --
--------------------------------------------------------------------------------

-- | Deserialize a closure
unClosure :: forall a. Typeable a => Closure a -> Process a
unClosure (Closure (Static label) env) = do
    rtable <- remoteTable <$> procMsg getLocalNode 
    let Just dyn = resolveClosure rtable label env
    return $ fromDyn dyn (throw (typeError dyn))
  where
    typeError dyn = userError $ "lookupStatic type error: " 
                 ++ "cannot match " ++ show (dynTypeRep dyn) 
                 ++ " against " ++ show (typeOf (undefined :: a))

--------------------------------------------------------------------------------
-- Auxiliary API                                                              --
--------------------------------------------------------------------------------

-- | Catch exceptions within a process
catch :: Exception e => Process a -> (e -> Process a) -> Process a
catch p h = do
  node  <- procMsg getLocalNode
  lproc <- ask
  let run :: Process a -> IO a
      run proc = runLocalProcess node proc lproc 
  liftIO $ Exception.catch (run p) (run . h) 

-- | Like 'expect' but with a timeout
expectTimeout :: forall a. Serializable a => Int -> Process (Maybe a)
expectTimeout timeout = receiveTimeout timeout [match return] 

-- | Asynchronous version of 'spawn'
-- 
-- ('spawn' is defined in terms of 'spawnAsync' and 'expect')
spawnAsync :: NodeId -> Closure (Process ()) -> Process SpawnRef
spawnAsync nid proc = do
  spawnRef <- getSpawnRef
  sendCtrlMsg (Just nid) $ Spawn proc spawnRef
  return spawnRef

-- | Spawn a child process, have the child link to the parent and the parent
-- monitor the child
spawnSupervised :: NodeId 
                -> Closure (Process ()) 
                -> Process (ProcessId, MonitorRef)
spawnSupervised nid proc = do
  us   <- getSelfPid
  them <- spawn nid (linkClosure us `cpSeq` proc) 
  ref  <- monitor them
  return (them, ref)

--------------------------------------------------------------------------------
-- Auxiliary functions                                                        --
--------------------------------------------------------------------------------

getMonitorRefFor :: ProcessId -> Process MonitorRef
getMonitorRefFor pid = do
  proc <- ask
  liftIO $ modifyMVar (processState proc) $ \st -> do 
    let counter = st ^. monitorCounter 
    return ( monitorCounter ^: (+ 1) $ st
           , MonitorRef pid counter 
           )

getSpawnRef :: Process SpawnRef
getSpawnRef = do
  proc <- ask
  liftIO $ modifyMVar (processState proc) $ \st -> do
    let counter = st ^. spawnCounter
    return ( spawnCounter ^: (+ 1) $ st
           , SpawnRef counter
           )

-- Send a control message
sendCtrlMsg :: Maybe NodeId  -- ^ Nothing for the local node
            -> ProcessSignal -- ^ Message to send 
            -> Process ()
sendCtrlMsg mNid signal = do            
  us <- getSelfPid
  let msg = NCMsg { ctrlMsgSender = ProcessIdentifier us
                  , ctrlMsgSignal = signal
                  }
  case mNid of
    Nothing -> do
      ctrlChan <- localCtrlChan <$> procMsg getLocalNode 
      liftIO $ writeChan ctrlChan msg 
    Just nid ->
      procMsg $ sendBinary (NodeIdentifier nid) msg
