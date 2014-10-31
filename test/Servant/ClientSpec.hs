{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ViewPatterns #-}

module Servant.ClientSpec where

import Control.Concurrent
import Control.Exception
import Control.Monad.Trans.Either
import Data.Proxy
import Data.Typeable
import Network.Socket
import Network.URI
import Network.Wai
import Network.Wai.Handler.Warp
import Test.Hspec

import Servant.API
import Servant.Client
import Servant.Server

import Servant.ServerSpec

type Api =
       "get" :> Get Person
  :<|> "capture" :> Capture "name" String :> Get Person
  :<|> "body" :> ReqBody Person :> Post Person
  :<|> "param" :> QueryParam "name" String :> Get Person
api :: Proxy Api
api = Proxy

server :: Application
server = serve api (
       return alice
  :<|> (\ name -> return $ Person name 0)
  :<|> return
  :<|> (\ name -> case name of
                   Just "alice" -> return alice
                   Just name -> left (400, name ++ " not found")
                   Nothing -> left (400, "missing parameter"))
 )

withServer :: (URIAuth -> IO a) -> IO a
withServer action = withWaiDaemon (return server) (action . mkHost "localhost")

getGet :: URIAuth -> EitherT String IO Person
getCapture :: String -> URIAuth -> EitherT String IO Person
getBody :: Person -> URIAuth -> EitherT String IO Person
getQueryParam :: Maybe String -> URIAuth -> EitherT String IO Person
(getGet :<|> getCapture :<|> getBody :<|> getQueryParam) = client api

spec :: Spec
spec = do
  it "Servant.API.Get" $ withServer $ \ host -> do
    runEitherT (getGet host) `shouldReturn` Right alice

  it "Servant.API.Capture" $ withServer $ \ host -> do
    runEitherT (getCapture "Paula" host) `shouldReturn` Right (Person "Paula" 0)

  it "Servant.API.ReqBody" $ withServer $ \ host -> do
    let p = Person "Clara" 42
    runEitherT (getBody p host) `shouldReturn` Right p

  it "Servant.API.QueryParam" $ withServer $ \ host -> do
    runEitherT (getQueryParam (Just "alice") host) `shouldReturn` Right alice
    Left result <- runEitherT (getQueryParam (Just "bob") host)
    result `shouldContain` "bob not found"

  context "client correctly handles error status codes" $ do
    let test :: WrappedApi -> Spec
        test (WrappedApi api) =
          it (show (typeOf api)) $
          withWaiDaemon (return (serve api (left (500, "error message")))) $
          \ (mkHost "localhost" -> host) -> do
            let getResponse :: URIAuth -> EitherT String IO ()
                getResponse = client api
            Left result <- runEitherT (getResponse host)
            result `shouldContain` "error message"
    mapM_ test $
      (WrappedApi (Proxy :: Proxy Delete)) :
      (WrappedApi (Proxy :: Proxy (Get ()))) :
      (WrappedApi (Proxy :: Proxy (Post ()))) :
      (WrappedApi (Proxy :: Proxy (Put ()))) :
      []

data WrappedApi where
  WrappedApi :: (HasServer api, Server api ~ EitherT (Int, String) IO a,
                 HasClient api, Client api ~ (URIAuth -> EitherT String IO ()),
                 Typeable api) =>
    Proxy api -> WrappedApi


-- * utils

withWaiDaemon :: IO Application -> (Port -> IO a) -> IO a
withWaiDaemon mkApplication action = do
  application <- mkApplication
  bracket (acquire application) free (\ (_, _, port) -> action port)
 where
  acquire application = do
    (notifyStart, waitForStart) <- lvar
    (notifyKilled, waitForKilled) <- lvar
    thread <- forkIO $ (do
      (krakenPort, socket) <- openTestSocket
      let settings =
            setPort krakenPort $ -- set here just for consistency, shouldn't be
                                 -- used (it's set in the socket)
            setBeforeMainLoop (notifyStart krakenPort)
            defaultSettings
      runSettingsSocket settings socket application)
            `finally` notifyKilled ()
    krakenPort <- waitForStart
    return (thread, waitForKilled, krakenPort)
  free (thread, waitForKilled, _) = do
    killThread thread
    waitForKilled

  lvar :: IO (a -> IO (), IO a)
  lvar = do
    mvar <- newEmptyMVar
    let put = putMVar mvar
        wait = readMVar mvar
    return (put, wait)

openTestSocket :: IO (Port, Socket)
openTestSocket = do
  s <- socket AF_INET Stream defaultProtocol
  localhost <- inet_addr "127.0.0.1"
  bind s (SockAddrInet aNY_PORT localhost)
  listen s 1
  port <- socketPort s
  return (fromIntegral port, s)