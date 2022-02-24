# C:\Users\kazon\Downloads\32b\nim-1.6.2\bin\nim c -d:danger -d:noSignalHandler --noMain:off -l:-static --app:lib --mm:arc --threads:on --tlsEmulation:off --passC:-ffast-math -d:useMalloc kailleraclient.nim
# C:\Users\kazon\Downloads\32b\nim-1.6.2\bin\nim c -d:danger -d:noSignalHandler --noMain:off -l:-static --app:lib --mm:arc --threads:on --tlsEmulation:off --passC:-ffast-math -d:useMalloc -o:plugin.dll kailleraclient.nim

import winim/lean
import std/[times, os, strutils, strformat, threadpool, sugar, browsers, httpclient]
import netty
import stew/[assign2]
import nimx/[window, layout, button, text_field]
import asyncdispatch, asynchttpserver, ws

from server import runServer

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
  HOST = "localhost"
  # HOST = "192.168.1.102"
  PORT = 27886
  MAX_INCOMING_BUFFER = 15
  MAX_PLAYERS = 4
  CLIENT_ID = 945835705643446272


var
  webSocket: WebSocket

  clientThread: Thread[tuple[clientMsg: ptr Channel[string],
      outputChannel: ptr Channel[string],
      host: string]]
  clientKaThread: Thread[ptr Channel[string]]
  gameThread: Thread[tuple[game: cstring, playerNumber, totalPlayers: int]]
  webSocketThread: Thread[void]
  serverThread: Thread[void]

  webSocketMsgChannel: Channel[string]
  clientMsg: Channel[string]
  outputChannel: Channel[string]

  inputArray: seq[char]

  lastPosFrameRecv: int
  lastPosFrameSend: int

  frameCount: int
  connectionType: int = 1 # 1 ~= LAN
  frameDelay: int
  myPlayerNumber: int
  totalPlayers: int
  startedGame: bool = false

  mainHWND: HWND

  mainWindow: Window

  wsServerIP: string

  kInfo: ptr kailleraInfos

  stage: int = 0
  gameCount: int
  frameRecv: int
  frameSend: int
  returnInputSize: bool = false
  gamePlaying: bool = false
  inputSize: int
  sizeOfEinput: int = 0
  inputFrame: int

  loggedIn: bool = false

  authState: AuthState = AuthState.notAuth

  authID: string


let
  # currentGame: cstring = "SmashRemix1.0.1"
  # currentGame: cstring = "Super Smash Bros. (U) [!]"
  currentGame: cstring = "SmashRemix0.9.4"

proc NimMain() {.importc, cdecl.}

proc c_strcpy(a: cstring, b: cstring): cstring {.importc: "strcpy",
    header: "<string.h>", noSideEffect.}

proc getTickCount(): int =
  return epochTime().int

proc callGameCallback(args: tuple[game: cstring, playerNumber,
    totalPlayers: int]): void {.thread.} =
  {.cast(gcsafe).}:
    discard kInfo.gameCallback(args.game, args.playerNumber.cint,
        args.totalPlayers.cint)

proc recvLoop(
  args: tuple[clientMsg: ptr Channel[string],
  outputChannel: ptr Channel[string],
  host: string
  ]): void =
  # {.cast(gcsafe).}:
    var
      client: Reactor
      c2s: Connection

    client.assign(newReactor()) # create connection
    c2s.assign(client.connect(args.host, PORT)) # connect to server
    client.punchThrough(args.host, PORT)

    client.send(c2s, "PING" & "END")

    # main loop
    while true:
      # must call tick to both read and write
      client.tick()

      let (gotMsg, cMsg) = args.clientMsg[].tryRecv
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
          gameThread.createThread(callGameCallback, (game: currentGame,
              playerNumber: myPlayerNumber, totalPlayers: totalPlayers))
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
  lastPosFrameRecv.assign(0)
  lastPosFrameSend.assign(0)
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
      MessageBox(0,"Never received ready signal. Game Ended!","gameInit()",0)
      # MessageDialog(frame, "Never received ready signal. Game Ended!",
      #     "gameInit()").showModal()
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
  # {.cast(gcsafe).}:
    while true:
      if not gamePlaying and loggedIn:
        clientMsg[].send("KEEP ALIVE")
      sleep(8000)

proc getWanIP(): string =
  let client = newHttpClient()
  var res = client.getContent("http://api.ipify.org/")
  return res.strip()

proc stopGame(): void =
  if startedGame:
    startedGame = false
    sizeOfEinput = -1
    gamePlaying = false
    sleep(20)

proc startWebsock(webSocketMsgChannel: ptr Channel[string], clientMsgChannel: ptr Channel[string]) {.async.} =
  {.cast(gcsafe).}:
    var userID: string
    
    try:
      var webSocket = await newWebSocket("ws://localhost:5000/ws/auth")
      await webSocket.send("START AUTH")
      while webSocket.readyState == Open:
        let msg = await webSocket.receiveStrPacket()

        let (gotMsg, wMsg) = webSocketMsgChannel[].tryRecv
        if gotMsg:
          await webSocket.send(wMsg)
          if wMsg == "LOGOUT":
            webSocket.close()

        if msg.startsWith("AUTH URL"):
          let authUrl = msg[8..^1]
          openDefaultBrowser(authUrl)
        elif msg.startsWith("AUTH ID"):
          authID = msg[7..^1]
          MessageBox(0,authID,"Auth ID",0)
        elif msg.startsWith("USER ID"):
          userID = msg[7..^1]
        elif msg.startsWith("AUTH SUCCESS"):
          authState = AuthState.authSuccess
          webSocket.close()
    except:
      authState = AuthState.authFailed
      let eMsg = getCurrentExceptionMsg()
      MessageBox(0,eMsg,"Exception",0)
      return

    try:
      webSocket = await newWebSocket(fmt"ws://localhost:5000/ws/{userID}")
      while webSocket.readyState == Open:
        let msg = await webSocket.receiveStrPacket()

        let (gotMsg, wMsg) = webSocketMsgChannel[].tryRecv
        if gotMsg:
          await webSocket.send(wMsg)
          if wMsg == "LOGOUT":
            webSocket.close()
        
        if msg.startsWith("CREATE GAME"):
          let host = getWanIP()
          await webSocket.send(fmt"SERVER IP{host}")
          serverThread.createThread(runServer)
          clientThread.createThread(recvLoop, (clientMsg.addr, outputChannel.addr, HOST))
          clientKaThread.createThread(clientKeepAlive, clientMsg.addr)
        elif msg.startsWith("LEAVE GAME"):
          stopGame()
          clientMsgChannel[].send("LEAVE GAME")
        elif msg.startsWith("DROP"):
          stopGame()
          if kInfo.clientDroppedCallback != nil:
            kInfo.clientDroppedCallback(cstring("User"), myPlayerNumber.cint)
        elif msg.startsWith("START GAME"):
          clientMsgChannel[].send("START GAME")
        elif msg.startsWith("JOIN GAME"):
          let host = msg[9..^1]
          clientThread.createThread(recvLoop, (clientMsg.addr, outputChannel.addr, host))
          clientKaThread.createThread(clientKeepAlive, clientMsg.addr)
        elif msg.startsWith("GAME LIST"):
          await webSocket.send(fmt"GAME LIST{kInfo.gameList}")
    except:
      let eMsg = getCurrentExceptionMsg()
      MessageBox(0,eMsg,"Exception",0)
      return

proc runWebSocket(): void {.thread.} =
  waitFor startWebsock(addr webSocketMsgChannel, addr clientMsg)
  
proc createFrame(): void =
  mainWindow = newWindow(newRect(50, 50, 300, 150))
  mainWindow.makeLayout: # DSL follows
    - Label as labelText: # Add a view of type Label to the window. Create a local reference to it named greetingLabel.
        center == super # center point of the label should be equal to center point of superview
        width == 100 # width should be 300 points
        height == 5 # well, this should be obvious now
        text: "Click to login" # property "text" should be set to whatever the label should display
    - Button as disconnectButton: # Add a view of type Button. We're not referring to it so it's anonymous.
        centerX == super # center horizontally
        top == prev.bottom + 5 # the button should be lower than the label by 5 points
        width == 100
        height == 25
        title: "Logout"
        enabled: false
        onAction:
            webSocketMsgChannel.send("LOGOUT")
            connectButton.enable
            disconnectButton.disable
            labelText.text = "Click to login"
    - Button as connectButton: # Add a view of type Button. We're not referring to it so it's anonymous.
        centerX == super # center horizontally
        top == prev.bottom + 5 # the button should be lower than the label by 5 points
        width == 100
        height == 25
        title: "Login"
        onAction:
          webSocketThread.createThread(runWebSocket)
          while authState != AuthState.authSuccess:
            sleep(5)
          if authState != AuthState.authFailed:
            connectButton.disable
            disconnectButton.enable
            labelText.text = "Success!"
          else:
            authState = AuthState.notAuth
            labelText.text = "Click to login"

proc kailleraGetVersion(version: cstring): void {.dllexp,
    extern: "_kailleraGetVersion".} =

  let kVersion: cstring = "SSB64 Online v1"

  discard c_strcpy(version, kVersion)

proc kailleraInit(): void {.dllexp, extern: "_kailleraInit".} =
  NimMain()

proc kailleraShutdown(): void {.dllexp, extern: "_kailleraShutdown".} =
  DestroyWindow(mainHWND)

proc kailleraSetInfos(infos: ptr kailleraInfos): void {.dllexp,
    extern: "_kailleraSetInfos".} =
  kInfo.assign(infos)

proc kailleraSelectServerDialog(parent: HWND): void {.dllexp,
    extern: "_kailleraSelectServerDialog".} =
  mainHWND.assign(parent)

  clientMsg.open
  outputChannel.open(maxItems = connectionType * MAX_INCOMING_BUFFER)

  runApplication:
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
  clientMsg.send(fmt"INPUT{join(inputArray)}")

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
        MessageBox(0,"Game Ended!  Didn't receive a response for 15s.","Game Ended!",0)
        # MessageDialog(frame, "Game Ended!  Didn't receive a response for 15s.",
        #     "Game Ended!").showModal()
        return sizeOfEInput.cint

      sleep(1)
    inputFrame.assign(connectionType)
    returnInputSize.assign(true)

  if returnInputSize:
    let output = outputChannel.recv
    for i in 0..<sizeOfEInput:
      cast[ptr UncheckedArray[char]](values)[i].assign(output[i])

    dec frameCount
    return sizeOfEInput.cint
  return 0.cint


proc kailleraChatSend(text: cstring): void {.dllexp,
    extern: "_kailleraChatSend".} =
  discard

proc kailleraEndGame(): void {.dllexp, extern: "_kailleraEndGame".} =
  webSocketMsgChannel.send("DROP")

