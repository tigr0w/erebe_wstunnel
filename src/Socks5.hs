{-# LANGUAGE DuplicateRecordFields     #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE StrictData                #-}

module Socks5 where


import           ClassyPrelude
import           Data.Binary
import           Data.Binary.Get
import           Data.Binary.Put
import qualified Data.ByteString        as BC
import qualified Data.ByteString.Char8  as BC8
import           Data.Either
import qualified Data.Text              as T
import qualified Data.Text.Read         as T
import qualified Data.Text.Encoding     as E
import           Network.Socket         (HostName, PortNumber)
import           Numeric                (showHex)

import           Control.Monad.Except   (MonadError)
import qualified Data.Streaming.Network as N


socksVersion :: Word8
socksVersion = 0x05

data AuthMethod = NoAuth
                | GSSAPI
                | Login
                | Reserved
                | NotAllowed
                deriving (Show, Read)

data AddressType = DOMAIN_NAME
                | IPv4
                deriving (Show, Read, Eq)

data RequestAuth = RequestAuth
  { version :: Int
  , methods :: Vector AuthMethod
  } deriving (Show, Read)

data ResponseAuth = ResponseAuth
  { version :: Int
  , method  :: AuthMethod
  } deriving (Show, Read)

instance Binary ResponseAuth where
  put ResponseAuth{..} = putWord8 (fromIntegral version) >> put method
  get = ResponseAuth <$> (fromIntegral <$> getWord8)
                     <*> get


instance Binary AuthMethod where
  put val = case val of
    NoAuth -> putWord8 0x00
    GSSAPI -> putWord8 0x01
    Login -> putWord8 0x02
    NotAllowed -> putWord8 0xFF
    _ {- Reserverd -} -> putWord8 0x03

  get = do
    method <- getWord8
    return $ case method of
      0x00 -> NoAuth
      0x01 -> GSSAPI
      0x02 -> Login
      0xFF -> NotAllowed
      _ -> Reserved


instance Binary RequestAuth where
  put RequestAuth{..} = do
    putWord8 (fromIntegral version)
    putWord8 (fromIntegral $ length methods)
    mapM_ put methods
    -- Check length <= 255

  get = do
    version <- fromIntegral <$> getWord8
    guard (version == 0x05)
    nbMethods <- fromIntegral <$> getWord8
    guard (nbMethods > 0 && nbMethods <= 0xFF)
    methods <- replicateM nbMethods get
    return $ RequestAuth version methods



data Request = Request
  { version :: Int
  , command :: Command
  , addr    :: HostName
  , port    :: PortNumber
  , addrType :: AddressType
  } deriving (Show)

data Command = Connect
             | Bind
             | UdpAssociate
             deriving (Show, Eq, Enum, Bounded)


instance Binary Command where
  put = putWord8 . (+1) . fromIntegral . fromEnum

  get = do
    cmd <- (\val -> fromIntegral val - 1) <$> getWord8
    guard $ cmd >= fromEnum (minBound :: Command) && cmd <= fromEnum (maxBound :: Command)

    return .toEnum $ cmd


instance Binary Request where
  put Request{..} = do
    putWord8 (fromIntegral version)
    put command
    putWord8 0x00 -- RESERVED
    _ <- if addrType == DOMAIN_NAME 
    then do 
      putWord8 0x03
      let host = BC8.pack addr
      putWord8 (fromIntegral . length $ host)
      traverse_ put host
    else do
      putWord8 0x01
      let ipv4 = fst . Data.Either.fromRight (0, mempty) . T.decimal . T.pack <$> splitElem '.' addr
      traverse_ putWord8 ipv4
      
    putWord16be (fromIntegral port)



  get = do
    version <- fromIntegral <$> getWord8
    guard (version == 5)
    cmd <- get :: Get Command
    _ <- getWord8 -- RESERVED

    opCode <- fromIntegral <$> getWord8 -- Addr type, we support only ipv4 and domainame
    guard (opCode == 0x03 || opCode == 0x01) -- DOMAINNAME OR IPV4

    host <- if opCode == 0x03
            then do
              length <- fromIntegral <$> getWord8
              fromRight T.empty . E.decodeUtf8' <$> replicateM length getWord8
            else do
              ipv4 <- replicateM 4 getWord8 :: Get [Word8]
              let ipv4Str = T.intercalate "." $ fmap (tshow . fromEnum) ipv4
              return ipv4Str

    guard (not $ null host)
    port <- fromIntegral <$> getWord16be

    return Request
      { version = version
      , command = cmd
      , addr = unpack host
      , port = port
      , addrType = if opCode == 0x03 then DOMAIN_NAME else IPv4
      }



toHex :: LByteString -> String
toHex = foldr showHex "" . unpack

data Response = Response
  { version    :: Int
  , returnCode :: RetCode
  , serverAddr :: HostName
  , serverPort :: PortNumber
  , serverAddrType   :: AddressType
  } deriving (Show)

data RetCode = SUCCEEDED
             | GENERAL_FAILURE
             | NOT_ALLOWED
             | NO_NETWORK
             | HOST_UNREACHABLE
             | CONNECTION_REFUSED
             | TTL_EXPIRED
             | UNSUPPORTED_COMMAND
             | UNSUPPORTED_ADDRESS_TYPE
             | UNASSIGNED
             deriving (Show, Eq, Enum, Bounded)

instance Binary RetCode where
  put = putWord8 . fromIntegral . fromEnum
  get = toEnum . min maxBound . fromIntegral <$> getWord8


instance Binary Response where
  put Response{..} = do
    putWord8 socksVersion
    put returnCode
    putWord8 0x00 -- Reserved
    _ <- if serverAddrType == DOMAIN_NAME
    then do
      putWord8 0x03
      let host = BC8.pack serverAddr
      putWord8 (fromIntegral . length $ host)
      traverse_ put host
    else do
      putWord8 0x01
      let ipv4 = fst . Data.Either.fromRight (0, mempty) . T.decimal . T.pack <$> splitElem '.' serverAddr
      traverse_ putWord8 ipv4

    putWord16be (fromIntegral serverPort)


  get = do
    version <- fromIntegral <$> getWord8
    guard(version == fromIntegral socksVersion)
    ret <- toEnum . min maxBound . fromIntegral <$> getWord8
    getWord8 -- RESERVED
    opCode <- fromIntegral <$> getWord8 -- Type
    guard(opCode == 0x03 || opCode == 0x01)
    host <- if opCode == 0x03
            then do
              length <- fromIntegral <$> getWord8
              fromRight T.empty . E.decodeUtf8' <$> replicateM length getWord8
            else do
              ipv4 <- replicateM 4 getWord8 :: Get [Word8]
              let ipv4Str = T.intercalate "." $ fmap (tshow . fromEnum) ipv4
              return ipv4Str
    guard (not $ null host)
    port <- getWord16be

    return Response
      { version = version
      , returnCode = ret
      , serverAddr = unpack host
      , serverPort = fromIntegral port
      , serverAddrType = if opCode == 0x03 then DOMAIN_NAME else IPv4
      }



data ServerSettings = ServerSettings
  { listenOn :: PortNumber
  , bindOn   :: HostName
  -- , onAuthentification :: (MonadIO m, MonadError IOException m) => RequestAuth -> m ResponseAuth
  -- , onRequest          :: (MonadIO m, MonadError IOException m) => Request -> m Response
  } deriving (Show)