{.link: r"C:\Program Files (x86)\Windows Kits\10\Lib\10.0.19041.0\um\x86\windowscodecs.lib".}

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
  {.pragma: dllexp, cdecl, stdcall, exportc, dynlib.}
else:
  {.pragma: dllexp, importc.}


type
  kailleraInfos = object
    appName, gameList: cstring
    gameCallback: proc(game: cstring, player, numplayers: cint): cint {.stdcall, gcsafe.}
    chatReceivedCallback: proc(nick, text: cstring) {.stdcall.}
    clientDroppedCallback: proc(nick: cstring, playernb: cint) {.stdcall.}
    moreInfosCallback: proc(gamename: cstring) {.stdcall.}

const
  # WSHOST = "192.168.1.102:5000"
  WSHOST = "purple-haze-8917.fly.dev"
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
  mainHWND: HWND

  wsHost: string = WSHOST

  # Threads

  clientThread: Thread[tuple[webSocketMsgChannel: ptr Channel[string],
      clientMsgChannel: ptr Channel[string], outputChannel: ptr Channel[string],
      serverAddress: string]]
  clientKaThread: Thread[ptr Channel[string]]
  gameThread: Thread[tuple[romNameChannel: ptr Channel[string], playerNumber,
      totalPlayers: int]]
  authWebSocketThread: Thread[tuple[webSocketChannel: ptr Channel[string],
      clientMsgChannel: ptr Channel[string], romNameChannel: ptr Channel[string]]]
  webSocketFEThread: Thread[tuple[webSocketChannel: ptr Channel[string],
      clientMsgChannel: ptr Channel[string], romNameChannel: ptr Channel[
          string], userID: string]]
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
  myPing: int
  totalPlayers: int
  loggedIn: bool = false
  startedGame: bool = false

  kInfo: kailleraInfos

  stage: int = 0
  gameCount: int
  frameRecv: int
  frameSend: int
  returnInputSize: bool = false
  gamePlaying: bool = false
  inputSize: int
  sizeOfEinput: int = 0
  inputFrame: int

  gameList: seq[string]

  authID: string

  p: Clipboard


proc NimMain() {.importc, nodecl.}

proc c_strcpy(a: cstring, b: cstring): cstring {.importc: "strcpy",
    header: "<string.h>", noSideEffect.}

proc getTickCount(): int =
  return epochTime().int

proc callGameCallback(
  args: tuple[
    romNameChannel: ptr Channel[string],
    playerNumber, totalPlayers: int
    ]
  ): void {.thread.} =
  {.cast(gcsafe).}:
    var romName: string = args.romNameChannel[].recv
    discard kInfo.gameCallback(romName.cstring, args.playerNumber.cint,
        args.totalPlayers.cint)

proc runClient(
  args: tuple[
    webSocketMsgChannel: ptr Channel[string],
    clientMsgChannel: ptr Channel[string],
    outputChannel: ptr Channel[string],
    serverAddress: string
    ]
  ): void {.thread.} =
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
        break

    for recv in client.messages:
      let msg = recv.data[0..^4]

      if msg.startsWith("PLAYER NUMBER"):
        myPlayerNumber.assign(parseInt($msg[^1]))
        args.webSocketMsgChannel[].send(msg)
      elif msg.startsWith("FRAME DELAY"):
        frameDelay.assign(parseInt(msg[11..^1]))
        args.webSocketMsgChannel[].send(msg)
      elif msg.startsWith("TOTAL PLAYERS"):
        totalPlayers.assign(parseInt($msg[^1]))
        args.webSocketMsgChannel[].send(msg)
      elif msg.startsWith("USER PING"):
        myPing.assign(parseInt(msg[9..^1]))
        args.webSocketMsgChannel[].send(msg)
      elif msg.startsWith("PONG"):
        if not loggedIn:
          loggedIn.assign(true)
      elif msg.startsWith("PING"):
        client.send(c2s, "PONG" & "END")
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

proc startFEWebsock(webSocketMsgChannel: ptr Channel[string],
    clientMsgChannel: ptr Channel[string],
    romNameChannel: ptr Channel[string],
    userID: string) {.async.} =
  {.cast(gcsafe).}:
    try:
      let webSocket = await newWebSocket(fmt"ws://{wsHost}/ws/{userID}")
      while webSocket.readyState == ws.ReadyState.Open:
        let msg = await webSocket.receiveStrPacket()

        let (gotMsg, wMsg) = webSocketMsgChannel[].tryRecv
        if gotMsg:
          await webSocket.send(wMsg)
          if wMsg == "LOGOUT":
            stopGame()
            authID = ""
            onDisconnected()
            webSocket.close()
            return

        if msg.startsWith("CREATE GAME"):
          romNameChannel[].send(msg[11..^1])
          let wanIP = getWanIP()
          await webSocket.send(fmt"SERVER IP{wanIP}")

          initServer()
          serverThread.createThread(runServer)
          clientThread.createThread(runClient, (webSocketMsgChannel,
              clientMsgChannel, outputChannel.addr, HOST))
          clientKaThread.createThread(clientKeepAlive, clientMsgChannel)
        elif msg.startsWith("LEAVE GAME"):
          stopGame()
          clientMsgChannel[].send("LEAVE GAME")
          clientMsgChannel[].send("DROP")
        elif msg.startsWith("DROP GAME"):
          let nick = msg[9..^1]
          if startedGame:
            clientMsgChannel[].send(fmt"DROP GAME")
          stopGame()
          if kInfo.clientDroppedCallback != nil:
            kInfo.clientDroppedCallback(nick.cstring, myPlayerNumber.cint)
        elif msg.startsWith("START GAME"):
          clientMsgChannel[].send("START GAME")
        elif msg.startsWith("JOIN GAME"):
          let serverIP = msg[9..^1]
          clientThread.createThread(runClient, (webSocketMsgChannel,
              clientMsgChannel, outputChannel.addr, serverIP))
          clientKaThread.createThread(clientKeepAlive, clientMsg.addr)
        elif msg.startsWith("GAME LIST"):
          # var
          #   temp: seq[char]
          #   strSize: int
          #   w: int = 0

          # for i in 0..<65536:
          #   strSize = len(cast[ptr UncheckedArray[char]](cast[int](
          #       kInfo.gameList) + w))
          #   if strSize == 0:
          #     break
          #   temp.assign(collect(for j in w..strSize: kInfo.gameList[j]))
          #   if temp.len <= 1: continue
          #   gameList.add(temp.join.strip)
          #   w = w + strSize + 1

          # let gameStr = gameList.join(",")
          await webSocket.send(fmt"GAME LIST{kInfo.gameList}")
        elif msg.startsWith("ROM NAME"):
          romNameChannel[].send(msg[8..^1])
    except:
      clientMsgChannel[].send("DROP")
      stopGame()
      let eMsg = getCurrentExceptionMsg()
      msgBoxError(mainwin, "Exception", eMsg)
      onDisconnected()
      return

proc runClientWebSocket(args: tuple[webSocketChannel: ptr Channel[string],
    clientMsgChannel: ptr Channel[string], romNameChannel: ptr Channel[
    string], userID: string]): void {.thread.} =
  waitFor startFEWebsock(args.webSocketChannel, args.clientMsgChannel,
      args.romNameChannel, args.userID)

proc startAuthWebsock(webSocketMsgChannel: ptr Channel[string],
    clientMsgChannel: ptr Channel[string],
    romNameChannel: ptr Channel[string]) {.async.} =
  {.cast(gcsafe).}:
    var
      authUrl: string
      userID: string

    try:
      let webSocket = await newWebSocket(fmt"ws://{wsHost}/ws/auth")
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
          elif msg.startsWith("PLAYER NUMBER"):
            myPlayerNumber.assign(parseInt($msg[^1]))
          elif msg.startsWith("FRAME DELAY"):
            frameDelay.assign(parseInt(msg[11..^1]))
            webSocketMsgChannel[].send(msg)
          elif msg.startsWith("TOTAL PLAYERS"):
            totalPlayers.assign(parseInt($msg[^1]))
            webSocketMsgChannel[].send(msg)
          elif msg.startsWith("USER PING"):
            myPing.assign(parseInt(msg[9..^1]))
            webSocketMsgChannel[].send(msg)

        if msg.startsWith("AUTH URL"):
          authUrl.assign(msg[8..^1])
          openDefaultBrowser(authUrl)
        elif msg.startsWith("AUTH ID"):
          authID.assign(msg[7..^1])
          p.writeString(authID)

          confirmationCodeValueLabel.text = authID

          confirmationCodeLabel.show
          confirmationCodeValueLabel.show
          clipboardButton.show
        elif msg.startsWith("USER ID"):
          userID = msg[7..^1]
        elif msg.startsWith("AUTH SUCCESS"):
          onConnected()
          webSocket.close()
          webSocketFEThread.createThread(runClientWebSocket, (
            addr webSocketMsg, addr clientMsg,
            addr romNameMsg, userID))
          return
    except:
      let eMsg = getCurrentExceptionMsg()
      msgBoxError(mainwin, "Exception", eMsg)
      onDisconnected()
      return



proc runAuthWebSocket(args: tuple[webSocketChannel: ptr Channel[string],
    clientMsgChannel: ptr Channel[string], romNameChannel: ptr Channel[
    string]]): void {.thread.} =
  waitFor startAuthWebsock(args.webSocketChannel, args.clientMsgChannel,
      args.romNameChannel)



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
  connectButton = newButton("Connect", proc(
      ) = authWebSocketThread.createThread(runAuthWebSocket, (addr webSocketMsg,
          addr clientMsg, addr romNameMsg)))
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

proc kailleraGetVersion(version: cstring): void {.dllexp, .} =

  let kVersion: cstring = "SSB64 Online v1"

  discard c_strcpy(version, kVersion)

proc kailleraInit(): void {.dllexp.} =
  NimMain()
  init()

proc kailleraShutdown(): void {.dllexp.} =
  DestroyWindow(mainHWND)
  mainwin.destroy

proc kailleraSetInfos(infos: ptr kailleraInfos): void {.dllexp.} =
  kInfo.assign(infos[])

proc kailleraSelectServerDialog(parent: HWND): void {.dllexp.} =
  mainHWND.assign(parent)

  clientMsg.open
  outputChannel.open(maxItems = connectionType * MAX_INCOMING_BUFFER)
  romNameMsg.open
  webSocketMsg.open

  createFrame()

proc kailleraModifyPlayValues(values: pointer, size: cint): cint {.dllexp.} =

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


proc kailleraChatSend(text: cstring): void {.dllexp.} =
  discard

proc kailleraEndGame(): void {.dllexp.} =
  clientMsg.send(fmt"DROP GAMEP1")
  stopGame()
