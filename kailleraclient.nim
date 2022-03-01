# C:\Users\kazon\Downloads\32b\nim-1.6.2\bin\nim c -d:danger --debuginfo:off --d:noMain --noMain:on -l:-static --app:lib --mm:arc --threads:on --tlsEmulation:off --passc:-fpic -d:useLibUiDll kailleraclient.nim
# C:\Users\kazon\Downloads\32b\nim-1.6.2\bin\nim c -d:danger --debuginfo:off --d:noMain --noMain:on -l:-static --app:lib --mm:arc --threads:on --tlsEmulation:off --passc:-fpic -d:useLibUiDll -o:plugin.dll kailleraclient.nim

import std/[times, os, strutils, strformat, sugar, browsers, httpclient]
import asyncdispatch
import asynchttpserver

import winim/lean
import ws
import netty
import stew/[assign2]
import ui
import clipboard

from server import runServer, initServer


when appType == "lib":
  {.pragma: dllexp, stdcall, exportc, dynlib.}
else:
  {.pragma: dllexp, importc.}


type
  kailleraInfos = object
    appName, gameList: cstring
    gameCallback: proc(game: cstring, player, numplayers: cint): cint {.stdcall, gcsafe.}
    chatReceivedCallback: proc(nick, text: cstring) {.stdcall.}
    clientDroppedCallback: proc(nick: cstring, playernb: cint) {.stdcall.}
    moreInfosCallback: proc(gamename: cstring) {.stdcall.}

  AuthState = enum
    notAuth, authSuccess, authFailed

const
  # WS_HOST = "192.168.1.102:5000"
  WS_HOST = "purple-haze-8917.fly.dev"
  HOST = "localhost"
  PORT = 27886
  MAX_INCOMING_BUFFER = 15
  MAX_PLAYERS = 4


var
  # GUI
  mainwin: Window
  wsHostEntry: Entry
  connectButton: Button
  disconnectButton: Button
  clipboardButton: Button
  confirmationCodeValueLabel: Label
  serverURLLabel: Label
  confirmationCodeLabel: Label
  connectedLabel: Label
  box: Box
  group: ui.Group
  inner: Box

  wsHost: string = "purple-haze-8917.fly.dev"

  # Threads

  clientThread: Thread[tuple[clientMsgChannel: ptr Channel[string],
      outputChannel: ptr Channel[string],
      serverAddress: string]]
  clientKaThread: Thread[ptr Channel[string]]
  gameThread: Thread[tuple[romNameChannel: ptr Channel[string], playerNumber,
      totalPlayers: int]]
  webSocketThread: Thread[tuple[webSocketChannel: ptr Channel[string],
      clientMsgChannel: ptr Channel[string], romNameChannel: ptr Channel[string]]]
  serverThread: Thread[void]

  # Thread channels

  webSocketMsg: Channel[string]
  clientMsg: Channel[string]
  outputChannel: Channel[string]
  romNameMsg: Channel[string]

  inputArray: seq[char]
  frameCount: int
  connectionType: int = 1 # 1 ~= LAN
  frameDelay: int
  myPlayerNumber: int
  totalPlayers: int
  loggedIn: bool = false
  startedGame: bool = false

  kInfo: ptr kailleraInfos

  mainHWND: HWND

  stage: int = 0
  gameCount: int
  frameRecv: int
  frameSend: int
  returnInputSize: bool = false
  gamePlaying: bool = false
  inputSize: int
  sizeOfEinput: int = 0
  inputFrame: int

  startAuth: bool = false
  authState: AuthState = AuthState.notAuth
  authID: string

  p: Clipboard


proc NimMain() {.importc, cdecl.}

proc c_strcpy(a: cstring, b: cstring): cstring {.importc: "strcpy",
    header: "<string.h>", noSideEffect.}

proc getTickCount(): int =
  return epochTime().int

proc callGameCallback(args: tuple[romNameChannel: ptr Channel[string],
    playerNumber, totalPlayers: int]): void {.thread.} =
  {.cast(gcsafe).}:
    var romName: string = args.romNameChannel[].recv
    discard kInfo.gameCallback(romName.cstring, args.playerNumber.cint,
        args.totalPlayers.cint)

proc runClient(
  args: tuple[clientMsgChannel: ptr Channel[string],
  outputChannel: ptr Channel[string],
  serverAddress: string
  ]): void =
  var
    client: Reactor
    c2s: Connection

  client.assign(newReactor()) # create connection
  c2s.assign(client.connect(args.serverAddress, PORT)) # connect to server
  client.punchThrough(args.serverAddress, PORT)

  client.send(c2s, "PING" & "END")

  while true:
    client.tick()

    var (gotMsg, cMsg) = args.clientMsgChannel[].tryRecv
    if gotMsg:
      client.send(c2s, cMsg & "END")
      if cMsg == "DROP":
        client.disconnect(c2s)
        return

    for recv in client.messages:
      let msg = recv.data[0..^4]

      if msg.startsWith("FRAME DELAY"):
        frameDelay.assign(parseInt($msg[^1]))
      elif msg.startsWith("PONG"):
        if not loggedIn:
          loggedIn.assign(true)
      elif msg.startsWith("PING"):
        client.send(c2s, "PONG" & "END")
      elif msg.startsWith("PLAYER NUMBER"):
        myPlayerNumber.assign(parseInt($msg[^1]))
      elif msg.startsWith("START GAME"):
        if startedGame:
          continue
        stage.assign(0)
        sizeOfEInput.assign(0)
        startedGame.assign(true)
        gameThread.createThread(callGameCallback, (
            romNameChannel: addr romNameMsg, playerNumber: myPlayerNumber,
                totalPlayers: totalPlayers))
      elif msg.startsWith("ALL READY"):
        gamePlaying.assign(true)
      elif msg.startsWith("TOTAL PLAYERS"):
        totalPlayers.assign(parseInt($msg[^1]))
      elif msg.startsWith("INPUT"):
        args.outputChannel[].send(msg[5..^1])
        frameCount += connectionType

proc gameInit(): void =
  var
    i: int
    w: int

  stage.assign(1)
  gameCount.assign(60)
  frameRecv.assign(0)
  frameSend.assign(0)

  returnInputSize.assign(false)
  gamePlaying.assign(false)
  sizeOfEinput.assign(inputSize * totalPlayers)
  inputFrame.assign((frameDelay + 1) * connectionType - 1)

  frameCount.assign(0)

  clientMsg.send("READY TO PLAY")

  var gameHandle: HWND = GetWindow(mainHWND, GW_HWNDPREV)

  if gameHandle != 0 and gameHandle != mainHWND:
    SetWindowPos(gameHandle, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE)
  else:
    SetWindowPos(mainHwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE)

  i.assign(getTickCount())
  w.assign(0)
  while not gamePlaying:
    if GetAsyncKeyState(27) == -32767:
      sizeOfEinput.assign(-1)
    if gameCount == 0 or sizeOfEInput == -1:
      msgBoxError(mainwin, "gameInit()", "Never received ready signal. Game Ended!")
      # MessageBox(0, "Never received ready signal. Game Ended!", "gameInit()", 0)
      sizeOfEinput.assign(-1)
      return
    if getTickCount() - i >= 1:
      inc w
      i.assign(getTickCount())
      dec gameCount
    if w == 5:
      w.assign(0)
      clientMsg.send("READY TO PLAY")

    sleep(1)

proc clientKeepAlive(clientMsg: ptr Channel[string]): void =
  while true:
    if not gamePlaying and loggedIn:
      clientMsg[].send("KEEP ALIVE")
    sleep(8000)

proc getWanIP(): string =
  let client = newHttpClient()
  var url = client.getContent("http://api.ipify.org/")
  return url.strip()

proc stopGame(): void =
  if startedGame:
    startedGame = false
    sizeOfEinput = -1
    gamePlaying = false
    sleep(20)

proc onConnected() =
  group.title = "Logout"

  serverURLLabel.hide
  wsHostEntry.hide
  connectButton.hide
  confirmationCodeLabel.hide
  confirmationCodeValueLabel.hide
  clipboardButton.hide

  connectedLabel.show
  disconnectButton.show

proc onDisconnected() =
  group.title = "Login"

  connectedLabel.hide
  disconnectButton.hide
  confirmationCodeLabel.hide
  confirmationCodeValueLabel.hide
  clipboardButton.hide

  serverURLLabel.show
  wsHostEntry.show
  connectButton.enable
  connectButton.show

proc startWebsock(webSocketMsgChannel: ptr Channel[string],
    clientMsgChannel: ptr Channel[string],
    romNameChannel: ptr Channel[string]) {.async.} =
  {.cast(gcsafe).}:
    var
      userID: string
      webSocket: WebSocket
      authUrl: string

    while not startAuth:
      sleep(1)

    try:
      webSocket = await newWebSocket(fmt"ws://{wsHost}/ws/auth")
      await webSocket.send("START AUTH")
      connectButton.disable
      while webSocket.readyState == ws.ReadyState.Open:
        let msg = await webSocket.receiveStrPacket()

        let (gotMsg, wMsg) = webSocketMsgChannel[].tryRecv
        if gotMsg:
          await webSocket.send(wMsg)
          if wMsg == "LOGOUT":
            disconnectButton.hide
            webSocket.close()
            return

        if msg.startsWith("AUTH URL"):
          authUrl.assign(msg[8..^1])
          openDefaultBrowser(authUrl)
        elif msg.startsWith("AUTH ID"):
          authID.assign(msg[7..^1])

          confirmationCodeValueLabel.text = authID

          confirmationCodeLabel.show
          confirmationCodeValueLabel.show
          clipboardButton.show
        elif msg.startsWith("USER ID"):
          userID = msg[7..^1]
        elif msg.startsWith("AUTH SUCCESS"):
          authState = AuthState.authSuccess
          onConnected()
          webSocket.close()
          startAuth = false
          break
    except:
      authState = AuthState.authFailed
      let eMsg = getCurrentExceptionMsg()
      msgBoxError(mainwin, "Exception", eMsg)
      # MessageBox(0, eMsg, "Exception", 0)
      return

    try:
      webSocket = await newWebSocket(fmt"ws://{wsHost}/ws/{userID}")
      while webSocket.readyState == ws.ReadyState.Open:
        let msg = await webSocket.receiveStrPacket()

        let (gotMsg, wMsg) = webSocketMsgChannel[].tryRecv
        if gotMsg:
          await webSocket.send(wMsg)
          if wMsg == "LOGOUT":
            webSocket.close()
            stopGame()
            onDisconnected()
            authID = ""
            return

        if msg.startsWith("CREATE GAME"):
          romNameChannel[].send(msg[11..^1])
          let wanIP = getWanIP()
          await webSocket.send(fmt"SERVER IP{wanIP}")

          initServer()
          serverThread.createThread(runServer)
          clientThread.createThread(runClient, (clientMsg.addr,
              outputChannel.addr, HOST))
          clientKaThread.createThread(clientKeepAlive, clientMsg.addr)
        elif msg.startsWith("LEAVE GAME"):
          stopGame()
          clientMsgChannel[].send("LEAVE GAME")
        elif msg.startsWith("DROP GAME"):
          let nick = msg[9..^1]
          stopGame()
          if kInfo.clientDroppedCallback != nil:
            kInfo.clientDroppedCallback(nick.cstring, myPlayerNumber.cint)
          clientMsgChannel[].send("DROP GAME")
        elif msg.startsWith("START GAME"):
          clientMsgChannel[].send("START GAME")
        elif msg.startsWith("JOIN GAME"):
          let serverIP = msg[9..^1]
          clientThread.createThread(runClient, (clientMsg.addr,
              outputChannel.addr, serverIP))
          clientKaThread.createThread(clientKeepAlive, clientMsg.addr)
        elif msg.startsWith("GAME LIST"):
          await webSocket.send(fmt"GAME LIST{kInfo[].gameList}")
        elif msg.startsWith("ROM NAME"):
          romNameChannel[].send(msg[8..^1])
    except:
      stopGame()
      let eMsg = getCurrentExceptionMsg()
      msgBoxError(mainwin, "Exception", eMsg)
      # MessageBox(0, eMsg, "Exception", 0)
      return

proc runWebSocket(args: tuple[webSocketChannel: ptr Channel[string],
    clientMsgChannel: ptr Channel[string], romNameChannel: ptr Channel[
    string]]): void {.thread.} =
  waitFor startWebsock(args.webSocketChannel, args.clientMsgChannel,
      args.romNameChannel)


proc kailleraGetVersion(version: cstring): void {.dllexp,
    extern: "_kailleraGetVersion".} =

  let kVersion: cstring = "SSB64 Online v1"

  discard c_strcpy(version, kVersion)

proc kailleraInit(): void {.dllexp, extern: "_kailleraInit".} =
  NimMain()

proc kailleraShutdown(): void {.dllexp, extern: "_kailleraShutdown".} =
  DestroyWindow(mainHWND)
  mainwin.destroy

proc kailleraSetInfos(infos: ptr kailleraInfos): void {.dllexp,
    extern: "_kailleraSetInfos".} =
  kInfo.assign(infos)

proc createFrame() =
  p = clipboardWithName(CboardGeneral)

  mainwin = newWindow("Kaillera+", 380, 280, false)
  mainwin.margined = true
  mainwin.onClosing = (proc (): bool = return true)

  box = newVerticalBox(true)
  mainwin.setChild(box)

  group = newGroup("Login", true)
  box.add(group, false)

  inner = newVerticalBox(true)
  group.child = inner

  serverURLLabel = newLabel("Server URL")
  inner.add serverURLLabel
  wsHostEntry = newEntry(wsHost, proc() = wsHost = wsHostEntry.text)
  inner.add wsHostEntry
  connectButton = newButton("Connect", proc() = startAuth = true)
  inner.add connectButton

  confirmationCodeLabel = newLabel("Confirmation Code")
  inner.add confirmationCodeLabel
  confirmationCodeValueLabel = newLabel(authID)
  inner.add confirmationCodeValueLabel
  clipboardButton = newButton("Copy to clipboard", proc() = p.writeString(authID))
  inner.add clipboardButton

  connectedLabel = newLabel("Connected")
  inner.add connectedLabel
  disconnectButton = newButton("Disconnect", proc() = webSocketMsg.send("LOGOUT"))
  inner.add disconnectButton

  onDisconnected()

  show(mainwin)
  mainLoop()

proc kailleraSelectServerDialog(parent: HWND): void {.dllexp,
    extern: "_kailleraSelectServerDialog".} =
  mainHWND.assign(parent)

  clientMsg.open
  outputChannel.open(maxItems = connectionType * MAX_INCOMING_BUFFER)
  romNameMsg.open
  webSocketMsg.open

  webSocketThread.createThread(runWebSocket, (addr webSocketMsg, addr clientMsg,
      addr romNameMsg))

  init()
  createFrame()

proc kailleraModifyPlayValues(values: pointer, size: cint): cint {.dllexp,
    extern: "_kailleraModifyPlayValues".} =

  var
    i: int
    w: int

  if sizeOfEInput == -1:
    sleep(1)
    return sizeOfEInput.cint
  elif stage == 0:
    inputSize.assign(size)
    gameInit()

  inputArray.assign(collect(for i in 0..<size: cast[cstring](values)[i]))

  inc frameSend
  if frameSend == connectionType:
    clientMsg.send(fmt"INPUT{join(inputArray)}")
    frameSend.assign(0)

  inc frameRecv
  if frameRecv == inputFrame:
    frameRecv.assign(0)
    i.assign(getTickCount())
    w.assign(0)
    while frameCount < connectionType:
      if sizeOfEInput == -1:
        return sizeOfEInput.cint
      elif getTickCount() - i >= 1:
        inc w
        i.assign(getTickCount())
        clientMsg.send("KEEP ALIVE")
      elif w == 15 and returnInputSize:
        sizeOfEinput.assign(-1)
        msgBoxError(mainwin, "Game Ended!", "Game Ended!  Didn't receive a response for 15s.")
        # MessageBox(0, "Game Ended!  Didn't receive a response for 15s.",
        #     "Game Ended!", 0)
        return sizeOfEInput.cint

      sleep(1)
    inputFrame.assign(connectionType)
    returnInputSize.assign(true)

  if returnInputSize:
    var output = outputChannel.recv
    for i in 0..<sizeOfEInput:
      cast[ptr UncheckedArray[char]](values)[i].assign(output[i])

    dec frameCount
    return sizeOfEInput.cint
  return 0.cint


proc kailleraChatSend(text: cstring): void {.dllexp,
    extern: "_kailleraChatSend".} =
  discard

proc kailleraEndGame(): void {.dllexp, extern: "_kailleraEndGame".} =
  webSocketMsg.send("DROP")
