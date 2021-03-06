{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving #-}
-- An example of embedding a custom monad into
-- Scotty's transformer stack, using ReaderT to provide access
-- to a TVar containing global state.
--
-- Note: this example is somewhat simple, as our top level
-- is IO itself. The types of 'scottyT' and 'scottyAppT' are
-- general enough to allow a Scotty application to be
-- embedded into any MonadIO monad.
module Main where

import Control.Concurrent.STM
import Control.Monad.Reader 

import Data.Default
import Data.String
import Data.Text.Lazy (Text)

import Network.Wai.Middleware.RequestLogger

import Web.Scotty.Trans

newtype AppState = AppState { tickCount :: Int }

instance Default AppState where
    def = AppState 0

-- Why 'ReaderT (TVar AppState)' rather than 'StateT AppState'?
-- With a state transformer, 'runActionToIO' (below) would have
-- to provide the state to _every action_, and save the resulting
-- state, using an MVar. This means actions would be blocking,
-- effectively meaning only one request could be serviced at a time.
-- The 'ReaderT' solution means only actions that actually modify 
-- the state need to block/retry.
-- 
-- Also note: your monad must be an instance of 'MonadIO' for
-- Scotty to use it.
newtype WebM a = WebM { runWebM :: ReaderT (TVar AppState) IO a }
    deriving (Monad, MonadIO, MonadReader (TVar AppState))

-- Scotty's monads are layered on top of our custom monad.
-- We define this synonym for lift in order to be explicit
-- about when we are operating at the 'WebM' layer.
webM :: MonadTrans t => WebM a -> t WebM a
webM = lift

-- Some helpers to make this feel more like a state monad.
gets :: (AppState -> b) -> WebM b
gets f = ask >>= liftIO . readTVarIO >>= return . f

modify :: (AppState -> AppState) -> WebM ()
modify f = ask >>= liftIO . atomically . flip modifyTVar' f

main :: IO ()
main = do
    sync <- newTVarIO def
        -- Note that 'runM' is only called once, at startup.
    let runM m = runReaderT (runWebM m) sync
        -- 'runActionToIO' is called once per action.
        runActionToIO = runM

    scottyT 3000 runM runActionToIO app

-- This app doesn't use raise/rescue, so the exception
-- type is ambiguous. We can fix it by putting a type
-- annotation just about anywhere. In this case, we'll
-- just do it on the entire app.
app :: ScottyT Text WebM ()
app = do
    middleware logStdoutDev
    scottyMiddleware logTickCount
    get "/" $ do
        c <- webM $ gets tickCount
        text $ fromString $ show c

    get "/plusone" $ do
        webM $ modify $ \ st -> st { tickCount = tickCount st + 1 }
        redirect "/"

    get "/plustwo" $ do
        webM $ modify $ \ st -> st { tickCount = tickCount st + 2 }
        redirect "/"

-- Log tick count after every request, but before the 'logStdoutDev'
-- logs the status. As you can see, it can access AppState.
-- However, unlike in actions, you do not need 'WebM' to lift state accessing.
logTickCount :: ScottyApplication WebM -> ScottyApplication WebM
logTickCount a req = do
  r <- a req
  c <- gets tickCount
  liftIO $ putStrLn $ "* tick count after request handled: " ++ show c
  return r
