<#
.SYNOPSIS
  Install FeteLABS on Windows 10 or 11, removing an old Odoo first.

.DESCRIPTION
  Run from an Administrator PowerShell:

    powershell -ExecutionPolicy Bypass -File install-windows.ps1

  Options:
    -KeepOdoo        install only, leave any Odoo alone
    -Yes             answer yes to every question
    -Source <dir>    install from a local FeteLABS folder instead of downloading it

  Nothing is deleted without a backup and a question first. What it sets up:
    C:\FeteLABS\src            the program
    C:\FeteLABS\venv           its Python packages
    C:\FeteLABS\fetelabs.conf
    C:\FeteLABS\data           uploaded files and sessions
    a "FeteLABS" task that starts it with Windows
    "FeteLABS" on the desktop and in the Start menu, with the Fete Labs icon

  It installs Git, Python 3.12, PostgreSQL 16 and wkhtmltopdf with winget
  (App Installer, built into Windows 10 and 11) when they are missing.
#>
param(
  [switch]$KeepOdoo,
  [switch]$Yes,
  [string]$Source = "",
  [string]$Repo = $(if ($env:FETELABS_REPO) { $env:FETELABS_REPO } else { "https://github.com/FetePass/odoo.git" }),
  [string]$Branch = $(if ($env:FETELABS_BRANCH) { $env:FETELABS_BRANCH } else { "fetelabs-19.0" }),
  [int]$Port = 8069
)

$ErrorActionPreference = "Stop"
$Root    = "C:\FeteLABS"
$Src     = Join-Path $Root "src"
$Venv    = Join-Path $Root "venv"
$Conf    = Join-Path $Root "fetelabs.conf"
$Data    = Join-Path $Root "data"
$Stamp   = Get-Date -Format "yyyyMMdd-HHmm"
$Backup  = Join-Path $env:USERPROFILE "odoo-backup-$Stamp"
$PgDir   = "C:\Program Files\PostgreSQL\16"
$PgBin   = Join-Path $PgDir "bin"
$WkBin   = "C:\Program Files\wkhtmltopdf\bin"

function Say($m)  { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" }
function Ask($q)  {
  if ($Yes) { return $true }
  $r = Read-Host "    $q [y/N]"
  return $r -match '^[Yy]'
}
function NewSecret([int]$n = 20) {
  $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
  $bytes = New-Object byte[] $n
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
              [Environment]::GetEnvironmentVariable("Path", "User")
}
function Winget($id, [string[]]$extra = @()) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is missing. Install 'App Installer' from the Microsoft Store, then run this again."
  }
  Note "Installing $id"
  & winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements @extra | Out-Null
  Refresh-Path
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Run this from PowerShell opened with 'Run as administrator'."
}

# ------------------------------------------------------------- old Odoo

function Remove-Odoo {
  Say "Looking for Odoo"
  $keys = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
          "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  $apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
          Where-Object { $_.DisplayName -like "Odoo*" }

  $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "odoo*" }
  foreach ($s in $services) {
    if ($s.Status -eq "Running" -and (Ask "Stop the service $($s.Name)?")) { Stop-Service $s.Name -Force }
  }

  if (-not $apps) { Note "No Odoo installed through its Windows installer." }
  foreach ($app in $apps) {
    $loc = $app.InstallLocation
    if (-not $loc -and $app.UninstallString) { $loc = Split-Path ($app.UninstallString.Trim('"')) }
    Note "Found $($app.DisplayName) in $loc"

    # Odoo's installer brings its own PostgreSQL (user openpg). Back up
    # every database in it before anything is removed.
    $dump = Get-ChildItem -Path $loc -Recurse -Filter pg_dump.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dump) {
      $psql = Join-Path $dump.DirectoryName "psql.exe"
      $env:PGPASSWORD = "openpgpwd"
      $dbs = $null
      try {
        $dbs = & $psql -h localhost -U openpg -d postgres -At -c "select datname from pg_database where not datistemplate and datname <> 'postgres'"
      } catch { $dbs = $null }
      if ($LASTEXITCODE -eq 0 -and $dbs) {
        New-Item -ItemType Directory -Force -Path $Backup | Out-Null
        foreach ($db in $dbs) {
          Note "Backing up $db"
          & $dump.FullName -h localhost -U openpg -Fc -f (Join-Path $Backup "$db.dump") $db
        }
      } else {
        Note "Could not read its databases (is its service running?). They stay on disk after uninstalling."
      }
      Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }

    foreach ($store in @("$env:LOCALAPPDATA\OpenERP S.A\Odoo",
                         "$env:WINDIR\System32\config\systemprofile\AppData\Local\OpenERP S.A\Odoo")) {
      if (Test-Path $store) {
        New-Item -ItemType Directory -Force -Path $Backup | Out-Null
        Note "Backing up the uploaded files in $store"
        Compress-Archive -Path $store -DestinationPath (Join-Path $Backup "odoo-files-$(Get-Random).zip") -Force
      }
    }

    if (Ask "Uninstall $($app.DisplayName)?") {
      foreach ($s in $services) { Stop-Service $s.Name -Force -ErrorAction SilentlyContinue }
      $cmd = $app.UninstallString.Trim('"')
      Start-Process -FilePath $cmd -ArgumentList "/S" -Wait
      Note "Uninstalled."
    }
  }
  if (Test-Path $Backup) { Note "Backups are in $Backup" }
}

# ------------------------------------------------------------- FeteLABS

function Install-Prerequisites {
  Say "Installing what FeteLABS needs"
  if (-not (Get-Command git -ErrorAction SilentlyContinue) -and -not $Source) { Winget "Git.Git" }
  $hasPy = $false
  try { $hasPy = ((& py -0p | Out-String) -match '3\.12') } catch { $hasPy = $false }
  if (-not $hasPy) { Winget "Python.Python.3.12" }
  if (-not (Test-Path (Join-Path $WkBin "wkhtmltopdf.exe"))) { Winget "wkhtmltopdf.wkhtmltox" }

  $script:PgSuper = $null
  if (-not (Test-Path (Join-Path $PgBin "psql.exe"))) {
    $script:PgSuper = NewSecret
    Winget "PostgreSQL.PostgreSQL.16" @("--override",
      "--mode unattended --unattendedmodeui none --superpassword $script:PgSuper --serverport 5432")
  } else {
    $sec = Read-Host "    PostgreSQL 16 is already installed. Its 'postgres' password" -AsSecureString
    $script:PgSuper = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  }
  $svc = Get-Service -Name "postgresql*16*" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($svc -and $svc.Status -ne "Running") { Start-Service $svc.Name }
}

function Install-Program {
  Say "Getting FeteLABS"
  New-Item -ItemType Directory -Force -Path $Root, $Data | Out-Null
  if ($Source) {
    if (Test-Path $Src) { Remove-Item -Recurse -Force $Src }
    Copy-Item -Recurse $Source $Src
  } elseif (Test-Path (Join-Path $Src ".git")) {
    & git -C $Src fetch --depth 1 origin $Branch; & git -C $Src reset --hard FETCH_HEAD
  } else {
    & git clone --depth 1 --branch $Branch $Repo $Src
  }
  if (-not (Test-Path (Join-Path $Src "addons\fetelabs_branding\__manifest__.py"))) {
    throw "$Src is not FeteLABS (no fetelabs_branding addon)."
  }

  Say "Installing its Python packages (a few minutes)"
  if (-not (Test-Path (Join-Path $Venv "Scripts\python.exe"))) { & py -3.12 -m venv $Venv }
  $py = Join-Path $Venv "Scripts\python.exe"
  & $py -m pip install -q --upgrade pip wheel
  & $py -m pip install -q -r (Join-Path $Src "requirements.txt") phonenumbers
  if ($LASTEXITCODE -ne 0) { throw "Installing the Python packages failed; see the messages above." }
}

function Configure {
  Say "Setting up the database account"
  $psql = Join-Path $PgBin "psql.exe"
  $env:PGPASSWORD = $script:PgSuper
  $dbPass = NewSecret
  $exists = & $psql -h localhost -U postgres -d postgres -At -c "select 1 from pg_roles where rolname = 'fetelabs'"
  if ($LASTEXITCODE -ne 0) { throw "Could not sign in to PostgreSQL as postgres." }
  if ($exists -eq "1") {
    & $psql -h localhost -U postgres -d postgres -q -c "alter role fetelabs with login createdb password '$dbPass'"
  } else {
    & $psql -h localhost -U postgres -d postgres -q -c "create role fetelabs with login createdb password '$dbPass'"
  }
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

  $master = $null
  if (Test-Path $Conf) {
    $master = ((Get-Content $Conf) | Where-Object { $_ -like "admin_passwd*" }) -replace '^admin_passwd\s*=\s*', ''
  }
  if (-not $master) { $master = NewSecret }
  @"
[options]
; The password the database manager asks for when you create, copy or
; delete a company database. Keep it somewhere safe.
admin_passwd = $master
db_host = localhost
db_port = 5432
db_user = fetelabs
db_password = $dbPass
addons_path = $Src\addons,$Src\odoo\addons
data_dir = $Data
bin_path = $WkBin
http_interface = 127.0.0.1
http_port = $Port
list_db = True
without_demo = True
"@ | Set-Content -Path $Conf -Encoding ASCII
  # Only administrators and the system may read the passwords in it.
  & icacls $Conf /inheritance:r /grant:r "*S-1-5-32-544:F" "*S-1-5-18:F" | Out-Null

  $desktop = [Environment]::GetFolderPath("Desktop")
  "FeteLABS master password: $master`r`n(also in $Conf)" |
    Set-Content -Path (Join-Path $desktop "FeteLABS-master-password.txt")
  $script:Master = $master

  Say "Making it start with Windows"
  $py = Join-Path $Venv "Scripts\pythonw.exe"
  $action  = New-ScheduledTaskAction -Execute $py -Argument "`"$Src\odoo-bin`" -c `"$Conf`"" -WorkingDirectory $Src
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $set     = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 `
               -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $who     = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName "FeteLABS" -Action $action -Trigger $trigger -Settings $set `
    -Principal $who -Force | Out-Null

  $icon = Join-Path $Src "fetelabs\brand\fetelabs.ico"
  $shortcut = "[InternetShortcut]`r`nURL=http://localhost:$Port`r`nIconFile=$icon`r`nIconIndex=0`r`n"
  $startMenu = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
  $publicDesktop = Join-Path $env:PUBLIC "Desktop"
  foreach ($dir in @($startMenu, $publicDesktop)) {
    Set-Content -Path (Join-Path $dir "FeteLABS.url") -Value $shortcut -Encoding ASCII
  }
}

function Start-FeteLABS {
  Say "Starting FeteLABS"
  Stop-ScheduledTask -TaskName "FeteLABS" -ErrorAction SilentlyContinue
  Start-ScheduledTask -TaskName "FeteLABS"
  $url = "http://localhost:$Port/web/database/selector"
  for ($i = 0; $i -lt 90; $i++) {
    try { Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 5 | Out-Null; return }
    catch { Start-Sleep -Seconds 2 }
  }
  throw "FeteLABS did not answer at http://localhost:$Port. Run it by hand to see why:`n  $Venv\Scripts\python.exe $Src\odoo-bin -c $Conf"
}

if (-not $KeepOdoo) { Remove-Odoo }
Install-Prerequisites
Install-Program
Configure
Start-FeteLABS

Say "FeteLABS is running at http://localhost:$Port"
Note "Open it from the FeteLABS icon on the desktop or in the Start menu."
Note "First visit: create your company database. It asks for the master"
Note "password, which is in FeteLABS-master-password.txt on your desktop."
Note "Pick your island as the country, so it sets up the right taxes."
Start-Process "http://localhost:$Port/web/database/manager"
