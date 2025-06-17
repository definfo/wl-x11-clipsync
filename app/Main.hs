{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Exception (IOException, try)
import Control.Monad (when)

import Data.ByteString (ByteString)
import qualified Data.ByteString as B

import Data.Text (Text, isPrefixOf, strip)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)

import Data.List (nub)

import System.Exit (ExitCode (ExitFailure, ExitSuccess))

import System.Process (callCommand, proc)
import System.Process.ByteString (readCreateProcessWithExitCode) -- process-extras

{-----------------------------------------------------------------------------
-                           Utility Functions
-----------------------------------------------------------------------------}

data DisplayServer = Wayland | X11
    deriving (Show, Eq)

data ClipMethod = Get | Set

instance Show ClipMethod where
    show :: ClipMethod -> String
    show Get = "getting"
    show Set = "setting"

getClipName :: DisplayServer -> ClipMethod -> Text
getClipName Wayland Get = T.pack "wl-paste"
getClipName Wayland Set = T.pack "wl-copy"
getClipName X11 _ = T.pack "xclip"

-- Decode bytes to UTF-8 string safely (replace errors).
decode :: ByteString -> Text
decode = decodeUtf8With lenientDecode . B.takeWhileEnd (/= 0)

-- Normalize text data to reduce unnecessary re-copies.
-- For example, strip trailing newlines/spaces.
normalize :: ByteString -> ByteString
normalize = encodeUtf8 . strip . decode

-- Check if the MIME type indicates textual data.
isTextMime :: Text -> Bool
isTextMime text =
    T.pack "text/" `isPrefixOf` text
        || text == T.pack "UTF8_STRING"
        || text == T.pack "STRING"

-- Get the list of MIME types from the Wayland/X11 clipboard.
getTargets :: DisplayServer -> IO [Text]
getTargets server = do
    let p = case server of
            Wayland -> proc "wl-paste" ["-l"]
            X11 -> proc "xclip" ["-selection", "clipboard", "-o", "-t", "TARGETS"]
    result <- try @IOException $ readCreateProcessWithExitCode p B.empty
    case result of
        Left _ -> return []
        Right (exitCode, stdout, _) ->
            case exitCode of
                ExitSuccess -> return $ T.lines $ decode stdout
                ExitFailure _ -> return []

-- MIME priority (Wayland <→ X11):
-- 1) text/uri-list       (file lists)
-- 2) text/html           (sometimes images in Firefox appear as HTML)
-- 3) image/*             (raw images)
-- 4) text/plain;charset=utf-8
-- 5) text/plain
-- 6) UTF8_STRING (fallback)
getMime :: DisplayServer -> IO Text
getMime server = do
    targets <- getTargets server
    return $ pickMime $ nub targets
  where
    pickMime :: [Text] -> Text
    pickMime targets
        -- 1) text/uri-list
        | T.pack "text/uri-list" `elem` targets = T.pack "text/uri-list"
        -- 2) text/html
        | T.pack "text/html" `elem` targets = T.pack "text/html"
        -- 3) image/*
        | Just imageMime <- findImageMime targets = imageMime
        -- 4) text/plain;charset=utf-8
        | T.pack "text/plain;charset=utf-8" `elem` targets =
            T.pack "text/plain;charset=utf-8"
        -- 5) text/plain
        | T.pack "text/plain" `elem` targets = T.pack "text/plain"
        -- 6) fallback
        | T.pack "UTF8_STRING" `elem` targets = T.pack "UTF8_STRING"
        -- default fallback
        | otherwise = T.pack "text/plain;charset=utf-8"

    findImageMime :: [Text] -> Maybe Text
    findImageMime [] = Nothing
    findImageMime (t : ts)
        | T.pack "image/" `isPrefixOf` t = Just t
        | otherwise = findImageMime ts

-- Unwrap result from readCreateProcessWithExitCode
-- args:
-- server : DisplayServer
-- cm : Get / Set method of clipboard
-- result : process return value
-- retf : return statement when process failed
-- rets : return statement when process succeeded
unwrapResult ::
    forall a.
    DisplayServer ->
    ClipMethod ->
    Either IOException (ExitCode, ByteString, ByteString) ->
    IO a ->
    (ByteString -> IO a) ->
    IO a
unwrapResult server cm result retf rets =
    case result of
        Left ex -> do
            putStrLn $
                "Error " ++ show cm ++ " " ++ show server ++ " clipboard: " ++ show ex
            retf
        Right (exitCode, stdout, _) ->
            case exitCode of
                ExitSuccess -> rets stdout
                -- NOTE:
                -- xclip/wl-copy exited with 1 when history is empty
                -- thus we should not handle this on copy side
                ExitFailure _ -> retf

-- Return (raw_data, mime) from Wayland/X11 clipboard.
getClip :: DisplayServer -> IO (ByteString, Text)
getClip server = do
    mime <- getMime server
    let p = case server of
            Wayland -> proc "wl-paste" ["-t", T.unpack mime]
            X11 -> proc "xclip" ["-selection", "clipboard", "-o", "-t", T.unpack mime]
    result <- try @IOException $ readCreateProcessWithExitCode p B.empty
    unwrapResult
        server
        Get
        result
        (return (B.empty, T.empty))
        (\stdout -> return (stdout, mime))

-- Write data to Wayland/X11 clipboard.
setClip :: DisplayServer -> ByteString -> Text -> IO ()
setClip server rawData mime = do
    let chosenMime =
            if server == Wayland && isTextMime mime
                then T.pack "text/plain;charset=utf-8"
                else mime
    let p = case server of
            Wayland -> proc "wl-copy" ["-t", T.unpack chosenMime]
            X11 -> proc "xclip" ["-selection", "clipboard", "-t", T.unpack chosenMime]
    result <-
        try @IOException $
            readCreateProcessWithExitCode p rawData
    unwrapResult
        server
        Set
        result
        (return ())
        (\_ -> return ())

{-----------------------------------------------------------------------------
-                  Wayland Clipboard (wl-copy / wl-paste)
-----------------------------------------------------------------------------}

-- Get the list of MIME types from the Wayland clipboard.
getWlTargets :: IO [Text]
getWlTargets = getTargets Wayland

-- Return (raw_data, mime) from Wayland clipboard.
getWlClip :: IO (ByteString, Text)
getWlClip = getClip Wayland

-- Write data to Wayland clipboard.
-- If it's text, use text/plain;charset=utf-8.
-- Otherwise use the original MIME (e.g., image/png).
setWlClip :: ByteString -> Text -> IO ()
setWlClip = setClip Wayland

{-----------------------------------------------------------------------------
-                  X11 Clipboard (xclip)
-----------------------------------------------------------------------------}

-- Get the list of MIME types from the X11 clipboard.
getX11Targets :: IO [Text]
getX11Targets = getTargets X11

-- Return (raw_data, mime) from Wayland clipboard.
getX11Clip :: IO (ByteString, Text)
getX11Clip = getClip X11

-- Write data to X11 clipboard.
-- NOTE:
-- If you copy an image, and then run 'xclip -o' (without '-t'), you'll likely
-- get an error 'cannot convert CLIPBOARD selection to target STRING' because
-- no text target is provided for an image. Use 'xclip -o -t image/png' instead.
setX11Clip :: ByteString -> Text -> IO ()
setX11Clip = setClip X11

{-----------------------------------------------------------------------------
-                            Main Loop
-----------------------------------------------------------------------------}

loop :: (ByteString, Text) -> (ByteString, Text) -> IO ()
loop (lastWlData, lastWlMime) (lastXData, lastXMime) = do
    -- clipnotify will wake up on any clipboard change
    -- FIXME:
    -- this method should block
    -- thus wait for return
    _ <- callCommand "clipnotify"

    -- Read both clipboards
    (wlRaw, wlMime) <- getWlClip
    (xRaw, xMime) <- getX11Clip

    -- Skip processing if both clipboards are empty
    when (wlRaw == B.empty && xRaw == B.empty) $ do
        loop (lastWlData, lastWlMime) (lastXData, lastXMime)

    -- Normalize text data to reduce duplicates
    let wlNorm =
            if isTextMime wlMime && wlRaw /= B.empty
                then normalize wlRaw
                else wlRaw

    let xNorm =
            if isTextMime xMime && xRaw /= B.empty
                then normalize xRaw
                else xRaw

    let wlChanged = wlNorm /= B.empty && wlNorm /= lastWlData
        xChanged = xNorm /= B.empty && xNorm /= lastXData

    case (wlChanged, xChanged) of
        (True, False) -> do
            -- Wayland changed
            when (wlNorm /= lastXData) $ do
                putStrLn $ "[Wayland -> X11] MIME=" ++ T.unpack wlMime
                setX11Clip wlNorm wlMime
            loop (wlNorm, wlMime) (wlNorm, wlMime)
        (False, True) -> do
            -- X11 changed
            when (xNorm /= lastWlData) $ do
                putStrLn $ "[X11 -> Wayland] MIME=" ++ T.unpack xMime
                setWlClip xNorm xMime
            loop (xNorm, xMime) (xNorm, xMime)
        (True, True) -> do
            -- Both changed - pick Wayland priority
            putStrLn $
                "[Conflict] Both changed. Preferring Wayland -> X11 (MIME="
                    ++ T.unpack wlMime
                    ++ ")"
            when (wlNorm /= lastXData) $ do
                setX11Clip wlNorm wlMime
            loop (wlNorm, wlMime) (wlNorm, wlMime)
        (False, False) -> do
            let wlNonEmpty = wlNorm /= B.empty
                xNonEmpty = xNorm /= B.empty
            case (wlNonEmpty, xNonEmpty) of
                (True, _) -> loop (wlNorm, wlMime) (wlNorm, wlMime)
                (_, True) -> loop (xNorm, xMime) (xNorm, xMime)
                _ -> loop (lastWlData, lastWlMime) (lastXData, lastXMime)

run :: IO ()
run = do
    putStrLn "Starting Wayland ↔ X11 clipboard sync..."
    -- Initialize with current clipboard contents to avoid initial sync
    loop (B.empty, T.empty) (B.empty, T.empty)

main :: IO ()
main = run
