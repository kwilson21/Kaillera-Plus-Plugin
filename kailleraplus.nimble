# Package

version       = "0.1.0"
author        = "Kazon Wilson"
description   = "Kaillera+ Plugin package"
license       = "GPL-3.0-or-later"
srcDir        = "./"
bin           = @["kailleraclient"]


# Dependencies

requires "nim >= 1.6.2","winim","ws","netty","stew","ui","clipboard"

proc compile() =
  exec "nim c --cc:vcc -d:danger --d:noMain --noMain:on --app:lib --mm:arc --threads:on --tlsEmulation:off -f -o:plugin.dll kailleraclient.nim"

task build_dll, "Compile to dll":
  compile()

task install_pkgs, "Install required packages":
    exec "nimble install -y winim ws netty stew ui https://github.com/yglukhov/clipboard"