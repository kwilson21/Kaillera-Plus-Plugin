# nim c -d:danger --mm:orc -d:useMalloc --passC:-ffast-math server.nim

import netty
import std/[strutils, sequtils, strformat]
import stew/[assign2]

type
  KailleraUser = object
    isOwner: bool
    connection: Connection
    ping: int
    delay: int
    playerNumber: int
    lostInput: seq[string]
    totalDelay: int
    tempDelay: int
    frameCount: int

  KailleraGame = object
    id: int
    delay: int
    playerCount: int
    users: array[4, ref KailleraUser]
    spectators: seq[ref KailleraUser]
    controllerData: array[4, string]

proc runServer*(): void {.thread.} =

  var
    server = newReactor("0.0.0.0", 27886)
    games = newSeq[ref KailleraGame]()
    isPlaying: bool = false
    controllerDataPacket: string
    pCount: int = 0
    stopServer: bool = false

  let
    connectionType: int = 1

  proc sendMsg(connection: Connection, msg: string): void =
    # echo fmt"[sent]{msg}"
    server.send(connection, msg & "END")

  proc broadcastMsg(msg: string): void =
    for i in 0..<games[0].playerCount:
      games[0].users[i].connection.sendMsg(msg)

  proc findPlayer(users: array[0..3, ref KailleraUser],
      userConnection: Connection): ref KailleraUser =
    for i in 0..<users.len:
      if users[i].connection == userConnection:
        return users[i]

  proc synced(): bool =
    return (isPlaying and games.len > 0 and all(games[0].controllerData[
          0..<games[0].playerCount], proc(x: string): bool = x != ""))

  proc sendSyncedInput(): void =
    if synced():
      controllerDataPacket.assign(join(games[0].controllerData))
      # echo fmt"Sending data {controllerDataPacket=} {games[0].controllerData=}"
      broadcastMsg("INPUT" & controllerDataPacket)
      games[0].controllerData.assign(@["", "", "", ""])

  proc resetGame(): void =
    if isPlaying:
      isPlaying = false
    games[0].controllerData.assign(@["", "", "", ""])

  proc startGame(): void =
    # if games.len > 0 and games[0].playerCount == 2 and not isPlaying and pCount ==
    #     (4 * games[0].playerCount):
    echo "Starting game..."

    for i in 0..<games[0].playerCount:
      let user = games[0].users[i]

      let ans = ((60 / connectionType) * (user.ping/1000)) + 1

      user.delay = int(ans)

      games[0].delay = max(games[0].delay, user.delay)

      user.tempDelay = games[0].delay - user.delay

      user.totalDelay = games[0].delay + user.tempDelay + 5

      user.connection.sendMsg(fmt"PLAYER NUMBER: {user.playerNumber + 1}")
      user.connection.sendMsg(fmt"FRAME DELAY: {user.delay}")
      user.connection.sendMsg(fmt"TOTAL PLAYERS: {games[0].playerCount}")

    broadcastMsg("START GAME")
    isPlaying = true


  echo "Listenting for connections..."

  while not stopServer:
    server.tick()
    for connection in server.newConnections:
      echo "[new] ", connection.address

      var kailleraUser = new(KailleraUser)
      kailleraUser.connection = connection
      kailleraUser.frameCount = 0

      if games.len == 0:
        kailleraUser.isOwner = true
        kailleraUser.playerNumber.assign(0)

        var playerArray: array[4, ref KailleraUser]

        playerArray[0].assign(kailleraUser)

        var kailleraGame = new(KailleraGame)
        kailleraGame.id = 1
        kailleraGame.users = playerArray
        kailleraGame.playerCount = 1
        kailleraGame.delay = 1

        games.add(kailleraGame)
      elif games.len > 0 and games[0].playerCount < 4:
        kailleraUser.isOwner = false
        inc games[0].playerCount

        let playerNumber = games[0].playerCount - 1

        kailleraUser.playerNumber.assign(playerNumber)

        games[0].users[playerNumber].assign(kailleraUser)

      for i in 0..<4:
        sendMsg(connection, "PING")

    for connection in server.deadConnections:
      echo "[dead] ", connection.address
      if isPlaying:
        isPlaying = false
      if games.len > 0:
        discard games.pop()

    for recv in server.messages:
      let msg = recv.data[0..^4]

      let user = findPlayer(games[0].users, recv.conn)

      # echo fmt"[msg]{msg}"
      if msg.startsWith("PING"):
        echo "Received ping"
        user.connection.sendMsg("PONG")
      elif msg.startsWith("PONG"):
        user.ping = (user.connection.stats.latencyTs.avg()*1000).int
        inc pCount
      elif msg.startsWith("LEAVE GAME"):
        resetGame()
        if user.isOwner:
          stopServer = true
          break
        else:
          dec games[0].playerCount
      elif msg.startsWith("START GAME"):
        if user.isOwner:
          startGame()
      elif msg.startsWith("READY TO PLAY"):
        broadcastMsg("ALL READY")
      elif msg.startsWith("INPUT"):
        if user.frameCount < user.totalDelay:
          user.lostInput.add(msg[5..^1])

          broadcastMsg(msg)

          inc user.frameCount
        else:
          if user.lostInput.len > 0:
            games[0].controllerData[user.playerNumber].assign(user.lostInput[0])
            user.lostInput.delete(0)
          else:
            games[0].controllerData[user.playerNumber].assign(msg[5..^1])

        sendSyncedInput()

    # startGame()

when isMainModule:
  runServer()