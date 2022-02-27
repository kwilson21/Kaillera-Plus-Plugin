import nat_traversal/[miniupnpc, natpmp]

var
  u = newMiniupnp()
  npmp = newNatPmp()

u.discoverDelay = 20
discard npmp.init()

proc removePort*(): bool =
  let r = u.deletePortMapping("27886", miniupnpc.UDP)
  return not r.isErr

proc mapPort*(): bool =
  discard u.discover()
  let n = u.selectIGD()
  if n != IGDFound: return false
  # Some devices do not support upnp, so it would fail here
  # when trying to get the external ip address.
  # let res = u.externalIPAddress()
  # if not res.isOk: return false
  # let externalIPAddress = res.value
  let r = u.addPortMapping(externalPort = "27886", protocol = miniupnpc.UDP,
      internalHost = u.lanAddr, internalPort = "27886", desc = "Kaillera+")
  return not r.isErr

proc npmpMapPort*(): bool =
  let r = npmp.addPortMapping(27886, 27886, natpmp.UDP, 3600)
  return not r.isErr

proc npmpRemovePort*(): bool =
  let r = npmp.deletePortMapping(27886, 27886, natpmp.UDP)
  return not r.isErr
