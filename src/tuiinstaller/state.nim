## Wizard state: the configuration being assembled, and navigation over it.
##
## Every step validates before it will let you leave, and validation reports
## which field is wrong rather than just refusing. An installer that says "no"
## without saying why is the most common way a first-time user gives up.

import ./disk

type
  Step* = enum
    stWelcome = "Welcome"
    stDisk = "Disk"
    stPartition = "Partitioning"
    stSystem = "System"
    stUser = "User"
    stReview = "Review"
    stInstall = "Install"

  PartScheme* = enum
    psEfiGpt = "UEFI (GPT + ESP)"
    psBiosGpt = "BIOS (GPT + boot partition)"

  RootFs* = enum
    rfExt4 = "ext4"
    rfBtrfs = "btrfs"
    rfXfs = "xfs"

  Profile* = enum
    prMinimal = "minimal"
    prDesktop = "desktop"
    prServer = "server"

  InstallConfig* = object
    dryRun*: bool
    disk*: string
    scheme*: PartScheme
    rootFs*: RootFs
    hostname*: string
    username*: string
    timezone*: string
    locale*: string
    profile*: Profile

  Validity* = object
    ok*: bool
    field*: string
    msg*: string

  Wizard* = object
    step*: Step
    done*: set[Step]
    cfg*: InstallConfig
    disks*: seq[Disk]
    sel*: int          ## cursor row within the current step
    editing*: bool     ## a text field on this row has keyboard focus

const StepCount* = ord(high(Step)) + 1

func defaultConfig*(dryRun: bool): InstallConfig =
  ## Defaults are chosen so that only the disk is genuinely unanswerable. A
  ## wizard that blocks on five empty fields teaches people to fear it.
  InstallConfig(
    dryRun: dryRun,
    disk: "",
    scheme: psEfiGpt,
    rootFs: rfExt4,
    hostname: "nexisos",
    username: "nexis",
    timezone: "UTC",
    locale: "en_US.UTF-8",
    profile: prMinimal,
  )

func validHostname*(s: string): bool =
  if s.len == 0 or s.len > 63: return false
  if s[0] == '-' or s[^1] == '-': return false
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-'}: return false
  true

func validUsername*(s: string): bool =
  if s.len == 0 or s.len > 32: return false
  if s[0] notin {'a'..'z', '_'}: return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '-', '_'}: return false
  true

func ok(): Validity = Validity(ok: true)
func bad(field, msg: string): Validity =
  Validity(ok: false, field: field, msg: msg)

func stepValid*(w: Wizard): Validity =
  case w.step
  of stWelcome, stPartition, stReview, stInstall:
    ok()
  of stDisk:
    if w.cfg.disk.len == 0:
      bad("disk", "Choose a disk to install to.")
    else: ok()
  of stSystem:
    if not validHostname(w.cfg.hostname):
      bad("hostname",
          "Hostnames use letters, digits and hyphens, and cannot start or " &
          "end with a hyphen.")
    else: ok()
  of stUser:
    if not validUsername(w.cfg.username):
      bad("username",
          "Usernames start with a lowercase letter or underscore and use " &
          "lowercase letters, digits, hyphens and underscores.")
    else: ok()

## How many selectable rows a step has. Navigation is uniform across steps —
## up and down always move a cursor, left and right always change the value
## under it — so the keys mean the same thing on every page. A wizard where
## Enter means "choose" here and "continue" there is how people mis-click
## through a disk selection.
func rowCount*(w: Wizard): int =
  case w.step
  of stWelcome, stReview, stInstall: 0
  of stDisk: w.disks.len
  of stPartition: 2                  ## scheme, filesystem
  of stSystem: 3                     ## hostname, timezone, locale
  of stUser: 2                       ## username, profile

func clampSel*(w: var Wizard) =
  let n = w.rowCount()
  if n <= 0:
    w.sel = 0
  elif w.sel < 0:
    w.sel = 0
  elif w.sel >= n:
    w.sel = n - 1

func rowIsText*(w: Wizard): bool =
  ## Text rows accept typed characters; option rows accept left/right only.
  case w.step
  of stSystem: true
  of stUser: w.sel == 0
  else: false

func initWizard*(dryRun = false): Wizard =
  Wizard(step: stWelcome, done: {}, cfg: defaultConfig(dryRun),
         disks: sampleDisks(), sel: 0, editing: false)

proc next*(w: var Wizard): bool =
  if not w.stepValid().ok: return false
  if w.step == high(Step): return false
  w.done.incl w.step
  w.step = succ(w.step)
  w.sel = 0
  w.editing = false
  w.clampSel()
  true

proc prev*(w: var Wizard): bool =
  if w.step == low(Step): return false
  w.step = pred(w.step)
  w.done.excl w.step
  w.sel = 0
  w.editing = false
  w.clampSel()
  true

func summaryLines*(cfg: InstallConfig): seq[string] = @[
  "Disk         " & (if cfg.disk.len > 0: cfg.disk else: "(none selected)"),
  "Scheme       " & $cfg.scheme,
  "Filesystem   " & $cfg.rootFs,
  "Hostname     " & cfg.hostname,
  "User         " & cfg.username,
  "Timezone     " & cfg.timezone,
  "Profile      " & $cfg.profile,
  "Mode         " & (if cfg.dryRun: "DRY RUN - nothing will be written"
                     else: "INSTALL - the disk will be erased"),
]

## Per-step guidance. Shown on every page, because the people installing a
## declarative distribution for the first time are exactly the people who do
## not yet know what a generation is.
func stepHint*(s: Step): seq[string] =
  case s
  of stWelcome: @[
    "NexisOS describes your whole system in TOML files under /etc/nexis.",
    "There is no 'install package' command - you edit the declaration and",
    "rebuild. Every rebuild makes a generation you can roll back to.",
    "",
    "This installer writes that first configuration and builds generation 1.",
  ]
  of stDisk: @[
    "Pick the disk NexisOS will be installed to. Everything on it is erased.",
    "",
    "Sizes and models come from the machine. If nothing looks familiar, stop",
    "here - a wrong choice is not recoverable.",
  ]
  of stPartition: @[
    "UEFI is right for anything made in the last decade. Choose BIOS only if",
    "the machine cannot boot UEFI.",
    "",
    "ext4 is the safe default. btrfs adds snapshots and compression, which",
    "overlap with what generations already give you.",
  ]
  of stSystem: @[
    "The hostname names this machine on the network.",
    "",
    "It goes into /etc/nexis/system.toml, so you can change it later by",
    "editing that file and running 'nexis rebuild switch'.",
  ]
  of stUser: @[
    "This account gets sudo access via the wheel group.",
    "",
    "Your packages and dotfiles are declared per user, so this account's",
    "setup travels with the configuration rather than living loose in /home.",
  ]
  of stReview: @[
    "Check every line. The next step erases the disk.",
    "",
    "Press D to see the exact commands that will run, in order, without",
    "running any of them.",
  ]
  of stInstall: @[
    "The installer partitions, formats, writes /etc/nexis, and builds",
    "generation 1 using the same builder that 'nexis rebuild' uses later.",
    "",
    "There is only one code path, so your installed system is not a special",
    "case that drifts from a rebuilt one.",
  ]
