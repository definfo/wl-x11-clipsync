{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Concurrent.MVar (
    MVar,
    newMVar,
    readMVar,
    swapMVar,
 )
import Control.Exception (IOException, try)
import Control.Monad (forever, when)

import Data.ByteString (ByteString)
import qualified Data.ByteString as B

import Data.Text (Text, isPrefixOf, strip)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)

import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as S

import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO.Unsafe (unsafePerformIO)

import Control.Applicative ((<|>))
import System.Process (callCommand, proc)
import System.Process.ByteString (readCreateProcessWithExitCode)

-- Enable debug pretty print with `CLIPSYNC_DEBUG=1 cabal run`
{-# NOINLINE isDebug #-}
isDebug :: Bool
isDebug = unsafePerformIO $ do
    val <- lookupEnv "CLIPSYNC_DEBUG"
    return (val == Just "1" || val == Just "true")

-- A helper function for printing debug messages.
dbg :: String -> IO ()
dbg msg = when isDebug $ putStrLn msg

{-----------------------------------------------------------------------------
-                           Utility Functions
-----------------------------------------------------------------------------}

data DisplayServer
    = Wayland
    | X11
    deriving (Enum, Show, Eq)

data ClipMethod
    = Get
    | Set
    deriving (Enum)

instance Show ClipMethod where
    show Get = "getting"
    show Set = "setting"

getClipName :: DisplayServer -> ClipMethod -> Text
getClipName Wayland Get = "wl-paste"
getClipName Wayland Set = "wl-copy"
getClipName X11 _ = "xclip"

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
    "text/" `isPrefixOf` text
        || text == "UTF8_STRING"
        || text == "STRING"

-- Get the list of MIME types from the Wayland/X11 clipboard.
getTargets :: DisplayServer -> IO (Set Text)
getTargets server = do
    let p = case server of
            Wayland -> proc "wl-paste" ["-l"]
            X11 -> proc "xclip" ["-selection", "clipboard", "-o", "-t", "TARGETS"]
    result <- try @IOException $ readCreateProcessWithExitCode p B.empty
    case result of
        Left _ -> return S.empty
        Right (exitCode, stdout, _) ->
            case exitCode of
                ExitSuccess -> return $ S.fromList $ T.lines $ decode stdout
                ExitFailure _ -> return S.empty

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
    return $ pickMime targets
  where
    pickMime :: Set Text -> Text
    pickMime targets =
        fromMaybe "text/plain;charset=utf-8" $
            find (`S.member` targets) mimePreferences
                <|> find ("image/" `isPrefixOf`) (S.toList targets)

    mimePreferences :: [Text]
    mimePreferences =
        [ "text/uri-list"
        , "text/html"
        , "text/plain;charset=utf-8"
        , "text/plain"
        , "UTF8_STRING"
        ]

-- Unwrap result from readCreateProcessWithExitCode
-- args:
-- server : DisplayServer
-- cm : Get / Set method of clipboard
-- result : process return value
-- retf : return statement when process failed
-- rets : return statement when process succeeded
unwrapResult ::
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
                then "text/plain;charset=utf-8"
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

-- Represents the last known state of the clipboards.
data ClipStat = ClipStat
    { lastWlData :: ByteString
    , lastWlMime :: Text
    , lastXData :: ByteString
    , lastXMime :: Text
    }
    deriving (Show)

-- Performs a single sync operation.
sync :: MVar ClipStat -> IO ()
sync stateVar = do
    _ <- callCommand "clipnotify"

    oldState <- readMVar stateVar

    (wlRaw, wlMime) <- getWlClip
    (xRaw, xMime) <- getX11Clip

    let wlNorm = if isTextMime wlMime then normalize wlRaw else wlRaw
    let xNorm = if isTextMime xMime then normalize xRaw else xRaw

    let wlChanged = wlNorm /= lastWlData oldState
    let xChanged = xNorm /= lastXData oldState

    -- Based on which clipboard changed, decide on the action and the new state.
    let (newState, syncAction) = case (wlChanged, xChanged) of
            (True, False) ->
                -- Wayland changed, sync to X11.
                let action = do
                        putStrLn $ "[Wayland -> X11] MIME=" ++ T.unpack wlMime
                        setX11Clip wlNorm wlMime
                    state = ClipStat wlNorm wlMime wlNorm wlMime
                in  (state, action)
            (False, True) ->
                -- X11 changed, sync to Wayland.
                let action = do
                        putStrLn $ "[X11 -> Wayland] MIME=" ++ T.unpack xMime
                        setWlClip xNorm xMime
                    state = ClipStat xNorm xMime xNorm xMime
                in  (state, action)
            (True, True) ->
                -- Both changed, prefer Wayland as source of truth.
                -- TODO: add a dbg pretty print here to display states
                let action = do
                        dbg $ "[Debug] Conflict. Old state: " ++ show oldState
                        putStrLn $
                            "[Conflict] Both changed. Preferring Wayland -> X11 (MIME="
                                ++ T.unpack wlMime
                                ++ ")"
                        setX11Clip wlNorm wlMime
                    state = ClipStat wlNorm wlMime wlNorm wlMime
                in  (state, action)
            (False, False) ->
                -- Nothing changed, no sync action needed.
                -- The new state is the current state, which should be the same as the old state.
                (oldState, return ())

    -- Execute the sync action and then update the state.
    syncAction
    _ <- swapMVar stateVar newState
    return ()

run :: IO ()
run = do
    putStrLn "Starting Wayland <---> X11 clipboard sync..."
    -- Initialize with an empty state.
    let initialState = ClipStat B.empty T.empty B.empty T.empty
    stateVar <- newMVar initialState
    -- Loop forever, syncing on each change.
    forever $ sync stateVar

main :: IO ()
main = run
