{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Snap.Internal.Http.Parser
  ( IRequest(..)
  , parseRequest
  , readChunkedTransferEncoding
  , parserToIteratee
  , parseCookie
  , parseUrlEncoded
  , writeChunkedTransferEncoding
  , strictize
  ) where


------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Arrow (first, second)
import           Control.Monad (liftM)
import           Control.Monad.Trans
import           Data.Attoparsec hiding (many, Result(..))
import           Data.Attoparsec.Iteratee
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import           Data.ByteString.Internal (c2w, w2c)
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Nums.Careless.Hex as Cvt
import           Data.Char
import           Data.CIByteString
import           Data.List (foldl')
import           Data.Int
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (catMaybes, fromMaybe)
import           Data.Time.Format (parseTime)
import           Data.Word (Word8)
import           Prelude hiding (take, takeWhile)
import           System.Locale (defaultTimeLocale)
import           Text.Printf
------------------------------------------------------------------------------
import           Snap.Internal.Http.Types hiding (Enumerator)
import           Snap.Iteratee hiding (take, foldl')



------------------------------------------------------------------------------
-- | an internal version of the headers part of an HTTP request
data IRequest = IRequest
    { iMethod :: Method
    , iRequestUri :: ByteString
    , iHttpVersion :: (Int,Int)
    , iRequestHeaders :: [(ByteString, ByteString)]
    }

instance Show IRequest where
    show (IRequest m u v r) =
        concat [ show m
               , " "
               , show u
               , " "
               , show v
               , " "
               , show r ]

------------------------------------------------------------------------------
parseRequest :: (Monad m) => Iteratee m (Maybe IRequest)
parseRequest = parserToIteratee pRequest


readChunkedTransferEncoding :: (Monad m) => Enumerator m a
readChunkedTransferEncoding iter = do
      i <- chunkParserToEnumerator (parserToIteratee pGetTransferChunk)
                                   iter

      return i 


-- fixme: replace with something faster later
toHex :: Int64 -> ByteString
toHex = S.pack . map c2w . printf "%x"

-- | Given an iteratee, produces a new one that wraps chunks sent to it with a
-- chunked transfer-encoding. Example usage:
--
-- > > (writeChunkedTransferEncoding
-- >     (enumLBS (L.fromChunks ["foo","bar","quux"]))
-- >     stream2stream) >>=
-- >     run >>=
-- >     return . fromWrap
-- >
-- > Chunk "3\r\nfoo\r\n3\r\nbar\r\n4\r\nquux\r\n0\r\n\r\n" Empty
--
writeChunkedTransferEncoding :: (Monad m) => Enumerator m a -> Enumerator m a
writeChunkedTransferEncoding enum it = do
    i <- wrap it
    enum i

  where
    wrap iter = return $ IterateeG $ \s ->
        case s of
          (EOF Nothing) -> do
              v <- runIter iter (Chunk $ toWrap "0\r\n\r\n")
              i <- checkIfDone return v
              runIter i (EOF Nothing)
          (EOF e) -> return $ Cont undefined e
          (Chunk x') -> do
              let x = S.concat $ L.toChunks $ fromWrap x'
              let n = S.length x
              let o = L.fromChunks [ toHex (toEnum n)
                                   , "\r\n"
                                   , x
                                   , "\r\n" ]
              v <- runIter iter (Chunk $ toWrap o)
              i <- checkIfDone wrap v
              return $ Cont i Nothing


chunkParserToEnumerator :: (Monad m) =>
                           Iteratee m (Maybe ByteString)
                        -> Iteratee m a
                        -> m (Iteratee m a)
chunkParserToEnumerator getChunk client = return $ do
    mbB <- getChunk
    maybe (finishIt client) (sendBS client) mbB

  where
    sendBS iter s = do
        v <- lift $ runIter iter (Chunk $ toWrap $ L.fromChunks [s])

        case v of
          (Done _ (EOF (Just e))) -> throwErr e

          (Done x _) -> return x

          (Cont _ (Just e)) -> throwErr e

          (Cont k Nothing) -> joinIM $
                              chunkParserToEnumerator getChunk k

    finishIt iter = do
        e <- lift $ sendEof iter

        case e of
          Left x  -> throwErr x
          Right x -> return x

    sendEof iter = do
        v <- runIter iter (EOF Nothing)

        return $ case v of
          (Done _ (EOF (Just e))) -> Left e
          (Done x _)              -> Right x
          (Cont _ (Just e))       -> Left e
          (Cont _ _)              -> Left $ Err $ "divergent iteratee"


------------------------------------------------------------------------------
-- parse functions
------------------------------------------------------------------------------

-- theft alert: many of these routines adapted from Johan Tibell's hyena
-- package

-- | Parsers for different tokens in an HTTP request.
sp, digit, letter :: Parser Word8
sp       = word8 $ c2w ' '
digit    = satisfy (isDigit . w2c)
letter   = satisfy (isAlpha . w2c)

untilEOL :: Parser ByteString
untilEOL = option "" $ takeWhile1 (not . flip elem "\r\n" . w2c)

crlf :: Parser ByteString
crlf = string "\r\n"

-- | Parser for zero or more spaces.
spaces :: Parser [Word8]
spaces = many sp

pSpaces :: Parser ByteString
pSpaces = option "" $ takeWhile1 (isSpace . w2c)

-- | Parser for the internal request data type.
pRequest :: Parser (Maybe IRequest)
pRequest = (Just <$> pRequest') <|> (endOfInput *> pure Nothing)

pRequest' :: Parser IRequest
pRequest' = IRequest
               <$> (option "" crlf *> pMethod)  <* sp
               <*> pUri                         <* sp
               <*> pVersion                     <* crlf
               <*> pHeaders                     <* crlf

  -- note: the optional crlf is at the beginning because some older browsers
  -- send an extra crlf after a POST body


-- | Parser for the request method.
pMethod :: Parser Method
pMethod =     (OPTIONS <$ string "OPTIONS")
          <|> (GET     <$ string "GET")
          <|> (HEAD    <$ string "HEAD")
          <|> word8 (c2w 'P') *> ((POST <$ string "OST") <|>
                                  (PUT  <$ string "UT"))
          <|> (DELETE  <$ string "DELETE")
          <|> (TRACE   <$ string "TRACE")
          <|> (CONNECT <$ string "CONNECT")

-- | Parser for the request URI.
pUri :: Parser ByteString
pUri = option "" $ takeWhile1 (not . isSpace . w2c)

-- | Parser for the request's HTTP protocol version.
pVersion :: Parser (Int, Int)
pVersion = string "HTTP/" *>
           liftA2 (,) (digit' <* word8 (c2w '.')) digit'
    where
      digit' = fmap (digitToInt . w2c) digit

fieldChars :: Parser ByteString
fieldChars = option "" $ takeWhile1 (isFieldChar . w2c)
  where
    isFieldChar c = (isDigit c) || (isAlpha c) || c == '-' || c == '_'


-- | Parser for request headers.
pHeaders :: Parser [(ByteString, ByteString)]
pHeaders = many header
  where
    header            = liftA2 (,)
                               fieldName
                               (word8 (c2w ':') *> spaces *> contents)

    fieldName         = liftA2 S.cons letter fieldChars

    contents          = liftA2 S.append
                               (untilEOL <* crlf)
                               (continuation <|> pure S.empty)

    isLeadingWS w     = let c = w2c w in c == ' ' || c == '\t'
    leadingWhiteSpace = satisfy isLeadingWS
                          *> (option "" $ takeWhile1 isLeadingWS)

    continuation      = liftA2 S.cons
                               (c2w ' ' <$ leadingWhiteSpace)
                               contents


pGetTransferChunk :: Parser (Maybe ByteString)
pGetTransferChunk = do
    hex <- liftM fromHex $ (option "" $ takeWhile1 (isHexDigit . w2c))
    takeTill ((== '\r') . w2c)
    crlf
    if hex <= 0
      then return Nothing
      else do
          x <- take hex
          crlf
          return $ Just x
  where
    fromHex :: ByteString -> Int
    fromHex s = Cvt.hex (L.fromChunks [s])


------------------------------------------------------------------------------
-- COOKIE PARSING
------------------------------------------------------------------------------

-- these definitions try to mirror RFC-2068 (the HTTP/1.1 spec) and RFC-2109
-- (cookie spec): please point out any errors!

{-# INLINE matchAll #-}
matchAll :: [ Char -> Bool ] -> Char -> Bool
matchAll x c = and $ map ($ c) x

{-# INLINE isToken #-}
isToken :: Char -> Bool
isToken = matchAll [ isAscii
                   , not . isControl
                   , not . isSpace 
                   , not . flip elem [ '(', ')', '<', '>', '@', ',', ';'
                                           , ':', '\\', '\"', '/', '[', ']'
                                           , '?', '=', '{', '}' ]
                   ]

{-# INLINE isRFCText #-}
isRFCText :: Char -> Bool
isRFCText = not . isControl

pToken :: Parser ByteString
pToken = option "" $ takeWhile1 (isToken . w2c)


pQuotedString :: Parser ByteString
pQuotedString = q *> quotedText <* q
  where
    quotedText = (S.concat . reverse) <$> f []

    f soFar = do
        t <- option "" $ takeWhile1 qdtext

        let soFar' = t:soFar

        -- RFC says that backslash only escapes for <">
        choice [ string "\\\"" *> f ("\"" : soFar')
               , pure soFar' ]


    q = word8 $ c2w '\"'

    qdtext = matchAll [ isRFCText, (/= '\"'), (/= '\\') ] . w2c
    

pCookie :: Parser Cookie
pCookie = do
    -- grab kvps and turn to strict bytestrings
    kvps <- pAvPairs

    -- kvps guaranteed non-null due to grammar. First avpair specifies
    -- name=value mapping.
    let ((nm,val):attrs') = kvps
    let attrs             = map (first toCI) attrs'

    -- and we'll gather the rest of the fields with helper functions.
    return $ foldl' field (nullCookie nm val) attrs


  where
    nullCookie nm val = Cookie nm val Nothing Nothing Nothing

    fieldFuncs :: [ (CIByteString, Cookie -> ByteString -> Cookie) ]
    fieldFuncs = [ ("domain", domain)
                 , ("expires", expires)
                 , ("path", path) ]

    domain c d     = c { cookieDomain  = Just d }
    path c p       = c { cookiePath    = Just p }
    expires c e    = c { cookieExpires = parseExpires e }
    parseExpires e = parseTime defaultTimeLocale
                               "%a, %d-%b-%Y %H:%M:%S GMT"
                               (map w2c $ S.unpack e)

    field c (k,v) = fromMaybe c (flip ($ c) v <$> lookup k fieldFuncs)


-- unhelpfully, the spec mentions "old-style" cookies that don't have quotes
-- around the value. wonderful.
pWord :: Parser ByteString
pWord = pQuotedString <|> (option "" $ takeWhile1 ((/= ';') . w2c))

pAvPairs :: Parser [(ByteString, ByteString)]
pAvPairs = do
    a <- pAvPair
    b <- many (pSpaces *> char ';' *> pSpaces *> pAvPair)

    return $ a:b

pAvPair :: Parser (ByteString, ByteString)
pAvPair = do
    key <- pToken <* pSpaces
    val <- option "" $ char '=' *> pSpaces *> pWord

    return (key,val)

parseCookie :: ByteString -> Maybe Cookie
parseCookie = parseToCompletion pCookie

------------------------------------------------------------------------------
-- MULTIPART/FORMDATA
------------------------------------------------------------------------------
-- TODO


parseUrlEncoded :: ByteString -> Map ByteString [ByteString]
parseUrlEncoded s = foldl' (\m (k,v) -> Map.insertWith' (++) k [v] m)
                           Map.empty
                           decoded
  where
    breakApart = (second (S.drop 1)) . S.break (== (c2w '=')) 

    parts :: [(ByteString,ByteString)]
    parts = map breakApart $ S.split (c2w '&') s

    urldecode = parseToCompletion pUrlEscaped

    decodeOne (a,b) = do
        a' <- urldecode a
        b' <- urldecode b
        return (a',b')

    decoded = catMaybes $ map decodeOne parts


------------------------------------------------------------------------------
-- utility functions
------------------------------------------------------------------------------

strictize :: L.ByteString -> ByteString
strictize         = S.concat . L.toChunks