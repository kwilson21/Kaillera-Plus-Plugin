# nim c -d:danger --mm:orc -d:useMalloc --passC:-ffast-math server.nim

import std/[strutils, sequtils, strformat]

import netty
import stew/[assign2]

# include portmap

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

var
  server: Reactor
  game: ref KailleraGame = nil
  isPlaying: bool = false
  controllerDataPacket: string
  pCount: int = 0

let
  connectionType: int = 1

proc sendMsg(connection: Connection, msg: string): void =
  # echo fmt"[sent]{msg}"
  server.send(connection, msg & "END")

proc broadcastMsg(msg: string): void =
  for i in 0..<game.playerCount:
    game.users[i].connection.sendMsg(msg)

proc findPlayer(users: array[0..3, ref KailleraUser],
    userConnection: Connection): ref KailleraUser =
  for i in 0..<users.len:
    if users[i].connection == userConnection:
      return users[i]

proc synced(): bool =
  return (isPlaying and game != nil and all(game.controllerData[
        0..<game.playerCount], proc(x: string): bool = x != ""))

proc sendSyncedInput(): void =
  if synced():
    controllerDataPacket.assign(join(game.controllerData))
    # echo fmt"Sending data {controllerDataPacket=} {game.controllerData=}"
    broadcastMsg("INPUT" & controllerDataPacket)
    game.controllerData.reset

proc resetGame(): void =
  if isPlaying:
    isPlaying = false
  game.controllerData.reset

proc startGame(): void =
  if game != nil and game.playerCount > 0 and not isPlaying and pCount ==
      (4 * game.playerCount):
    echo "Starting game..."

    for i in 0..<game.playerCount:
      let user = game.users[i]

      let ans = ((60 / connectionType) * (user.ping/1000)) + 1

      user.delay = int(ans)

      game.delay = max(game.delay, user.delay)

      user.tempDelay = game.delay - user.delay

      user.totalDelay = game.delay + user.tempDelay + 5

      user.connection.sendMsg(fmt"PLAYER NUMBER: {user.playerNumber + 1}")
      user.connection.sendMsg(fmt"FRAME DELAY: {user.delay}")
      user.connection.sendMsg(fmt"TOTAL PLAYERS: {game.playerCount}")

    broadcastMsg("START GAME")
    isPlaying = true

proc initServer*(): void =
  # var portMapped = mapPort()
  # if not portMapped:
  #   # Can't forward port, server probably won't work :(
  #   discard

  server.assign(newReactor("0.0.0.0", 27886))

proc runServer*(): void {.thread.} =
  echo "Listenting for connections..."
  {.cast(gcsafe).}:
    try:
      while true:
        server.tick()
        for connection in server.newConnections:
          echo "[new] ", connection.address

          var kailleraUser = new(KailleraUser)
          kailleraUser.connection = connection
          kailleraUser.frameCount = 0

          if game == nil:
            kailleraUser.isOwner = true
            kailleraUser.playerNumber.assign(0)

            var kailleraGame = new(KailleraGame)
            kailleraGame.id = 1
            kailleraGame.users[0] = kailleraUser
            kailleraGame.playerCount = 1
            kailleraGame.delay = 1

            game.assign(kailleraGame)
          elif game != nil and game.playerCount < 4:
            kailleraUser.isOwner = false
            inc game.playerCount

            let playerNumber = game.playerCount - 1

            kailleraUser.playerNumber.assign(playerNumber)

            game.users[playerNumber].assign(kailleraUser)

          for i in 0..<4:
            connection.sendMsg("PING")

        for connection in server.deadConnections:
          echo "[dead] ", connection.address
          if isPlaying:
            isPlaying = false
          if game != nil:
            game = nil

        for recv in server.messages:
          let msg = recv.data[0..^4]

          let user = findPlayer(game.users, recv.conn)

          # echo fmt"[msg]{msg}"
          if msg.startsWith("PING"):
            echo "Received ping"
            user.connection.sendMsg("PONG")
          elif msg.startsWith("PONG"):
            user.ping = (user.connection.stats.latencyTs.avg()*1000).int
            inc pCount
          elif msg.startsWith("DROP GAME"):
            resetGame()
          elif msg.startsWith("LEAVE GAME"):
            resetGame()
            if user.isOwner:
              return
            else:
              dec game.playerCount
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
                game.controllerData[user.playerNumber].assign(user.lostInput[0])
                user.lostInput.delete(0)
              else:
                game.controllerData[user.playerNumber].assign(msg[5..^1])

            sendSyncedInput()

    finally:
      # discard removePort()
      discard

when isMainModule:
  initServer()
  runServer()
