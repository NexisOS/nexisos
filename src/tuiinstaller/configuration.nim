## Generation zero: the TOML the installer writes to the target.
##
## This is the whole point of the installer. Everything before it collects
## answers; this turns them into the declaration that the machine will describe
## itself with from now on. The file it writes is an ordinary configuration —
## not a special installer-flavoured one — so the first thing a user does after
## booting is edit a file they can already read.
##
## Rendering is a pure function of `InstallConfig`, so `--dry-run` can print
## the exact bytes that would be written without a target disk existing.

import std/[strutils]
import ./state

const Header = """
# /etc/nexis/system.toml
#
# Written by the NexisOS installer. This is generation 1's declaration and
# nothing else describes this machine — edit it and run:
#
#     nexis rebuild switch
#
# Every rebuild produces a generation you can roll back to, so editing this
# file is not a risk. `nexis rollback` undoes it.
"""

func tomlString(s: string): string =
  ## Basic TOML string escaping. The validated fields cannot contain these,
  ## but the timezone and locale are free text and this is the boundary where
  ## a stray quote would silently produce an unparseable system config.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    else: result.add c
  result.add "\""

func renderSystemToml*(cfg: InstallConfig): string =
  result = Header
  result.add "\n[system]\n"
  result.add "hostname = " & tomlString(cfg.hostname) & "\n"
  result.add "timezone = " & tomlString(cfg.timezone) & "\n"
  result.add "locale   = " & tomlString(cfg.locale) & "\n"

  result.add "\n[system.profile]\n"
  result.add "name = " & tomlString($cfg.profile) & "\n"

  result.add "\n# Packages are declared, never installed. `nexis add firefox`\n"
  result.add "# edits this list and rebuilds; there is no `nexis install`.\n"
  result.add "[system.packages]\n"
  result.add "include = [\"base\"]\n"

  result.add "\n[users." & cfg.username & "]\n"
  result.add "groups = [\"wheel\"]\n"
  result.add "shell  = \"/usr/bin/bash\"\n"
  result.add "packages = []\n"

  result.add "\n[security]\n"
  result.add "selinux = \"permissive\"  # enforcing once policy ships\n"

  result.add "\n[boot]\n"
  result.add "scheme = " & tomlString(if cfg.scheme == psEfiGpt: "efi"
                                      else: "bios") & "\n"
  result.add "disk   = " & tomlString(cfg.disk) & "\n"

func configPreviewLines*(cfg: InstallConfig): seq[string] =
  ## The rendered TOML minus comments and blank runs, for the review page.
  ## Showing the actual file is what closes the loop between "I answered five
  ## questions" and "this is now the thing that defines my machine".
  var lastBlank = false
  for raw in renderSystemToml(cfg).splitLines():
    let line = raw.strip(leading = false)
    if line.startsWith("#"): continue
    if line.len == 0:
      if lastBlank: continue
      lastBlank = true
    else:
      lastBlank = false
    result.add line
  while result.len > 0 and result[0].len == 0:
    result.delete(0)

proc writeSystemToml*(path: string, cfg: InstallConfig) =
  writeFile(path, renderSystemToml(cfg))
