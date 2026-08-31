<#
.SYNOPSIS
 Laddar ner och installerar Windows ADK + WinPE-tillägget, bygger en WinPE-arbetskatalog
 och skapar en bootbar USB-sticka med två partitioner.

.DESCRIPTION
 Partition 1 (först på disken): FAT32, etikett WINPE, aktiv, innehåller bootmiljön.
 Partition 2: NTFS, etikett STUFF, monteras som E: och används för drivrutiner,
 images och verktyg.

 MBR + FAT32 gör att stickan bootar på både UEFI och legacy BIOS. Secure Boot
 fungerar eftersom bootfilerna från ADK är signerade av Microsoft.

.PARAMETER WorkRoot
 Arbetskatalog för copype. Skapas om den inte finns, töms om den finns.

.PARAMETER BootPartitionSizeMB
 Storlek på FAT32-bootpartitionen i MB. Standard 12288 (12 GB).

.PARAMETER DataDriveLetter
 Enhetsbokstav för datapartitionen. Standard E.

.PARAMETER SkipAdkInstall
 Hoppa över nedladdning/installation av ADK. Använd när kiten redan är på plats.

.EXAMPLE
 .\New-WinPEStick.ps1

.EXAMPLE
 .\New-WinPEStick.ps1 -BootPartitionSizeMB 8192 -SkipAdkInstall

.NOTES
 Kör som administratör. Testad på Windows 10/11 med PowerShell 5.1.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
 [string]$WorkRoot = 'C:\WinPE_amd64',

 [ValidateSet('amd64', 'arm64', 'x86')]
 [string]$Architecture = 'amd64',

 [ValidateRange(1024, 32000)]
 [int]$BootPartitionSizeMB = 12288,

 [ValidatePattern('^[D-Zd-z]$')]
 [string]$DataDriveLetter = 'E',

 [string]$BootLabel = 'WINPE',
 [string]$DataLabel = 'STUFF',

 [switch]$SkipAdkInstall
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Nedladdningslänkar (Microsoft fwlink, ADK 10.1.26100.2454 - december 2024)
# Verifiera mot https://learn.microsoft.com/windows-hardware/get-started/adk-install
# innan produktionsanvändning - Microsoft byter ut länkarna vid nya releaser.
# ---------------------------------------------------------------------------
$AdkUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980'
$WinPeUrl = 'https://go.microsoft.com/fwlink/?linkid=2289981'

$DownloadDir = Join-Path $env:TEMP 'ADKDownload'

# ---------------------------------------------------------------------------
# Hjälpfunktioner
# ---------------------------------------------------------------------------

function Write-Step {
 param([string]$Message)
 Write-Host ''
 Write-Host ('=' * 72) -ForegroundColor DarkCyan
 Write-Host " $Message" -ForegroundColor Cyan
 Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Write-Info { param([string]$m) Write-Host " $m" -ForegroundColor Gray }
function Write-Ok { param([string]$m) Write-Host " + $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host " ! $m" -ForegroundColor Yellow }

function Get-KitsRoot {
 # ADK-installern är 32-bitars och skriver KitsRoot10 under WOW6432Node på x64.
 # 64-bitars PowerShell ser inte den nyckeln via den vanliga sökvägen, så båda
 # registervyerna måste provas - och därefter standardsökvägarna på disk.
 $keys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
 )

 foreach ($key in $keys) {
  if (Test-Path $key) {
   $root = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).KitsRoot10
   if ($root -and (Test-Path (Join-Path $root 'Assessment and Deployment Kit'))) {
    return $root.TrimEnd('\')
   }
  }
 }

 foreach ($path in @(
  "${env:ProgramFiles(x86)}\Windows Kits\10"
  "$env:ProgramFiles\Windows Kits\10"
 )) {
  if ($path -and (Test-Path (Join-Path $path 'Assessment and Deployment Kit'))) {
   return $path.TrimEnd('\')
  }
 }

 return $null
}

function Get-AdkPaths {
 $kits = Get-KitsRoot
 if (-not $kits) { return $null }
 $adk = Join-Path $kits 'Assessment and Deployment Kit'
 $copype = Join-Path $adk 'Windows Preinstallation Environment\copype.cmd'

 # Sista utväg: leta upp copype.cmd var den än hamnat under ADK-roten.
 if (-not (Test-Path $copype)) {
  $found = Get-ChildItem -Path $adk -Filter 'copype.cmd' -Recurse -ErrorAction SilentlyContinue |
   Select-Object -First 1
  if ($found) { $copype = $found.FullName }
 }

 [pscustomobject]@{
  KitsRoot        = $kits
  Adk             = $adk
  DeploymentTools = Join-Path $adk 'Deployment Tools'
  DandISetEnv     = Join-Path $adk 'Deployment Tools\DandISetEnv.bat'
  WinPeRoot       = Join-Path $adk 'Windows Preinstallation Environment'
  Copype          = $copype
 }
}

function Test-AdkInstalled {
 $p = Get-AdkPaths
 if (-not $p) { return $false }
 return ((Test-Path $p.DandISetEnv) -and (Test-Path $p.Copype))
}

function Write-AdkDiagnostics {
 Write-Warn2 'Kunde inte verifiera ADK-installationen. Kontrollstatus:'

 foreach ($key in @(
  'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
 )) {
  $val = if (Test-Path $key) {
   (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).KitsRoot10
  }
  Write-Info (" {0,-62} {1}" -f $key.Replace('HKLM:\SOFTWARE\', ''), $(if ($val) { $val } else { '<saknas>' }))
 }

 $p = Get-AdkPaths
 if ($p) {
  Write-Info (" {0,-62} {1}" -f 'DandISetEnv.bat', $(if (Test-Path $p.DandISetEnv) { 'OK' } else { 'SAKNAS' }))
  Write-Info (" {0,-62} {1}" -f 'copype.cmd', $(if (Test-Path $p.Copype) { 'OK' } else { 'SAKNAS' }))
  Write-Info " ADK-rot: $($p.Adk)"
 } else {
  Write-Info ' Ingen ADK-rot hittad i registret eller på standardsökvägarna.'
 }

 Write-Info ' Installationsloggar: C:\Users\<du>\AppData\Local\Temp\adk*.log'
}

function Invoke-Download {
 param([string]$Uri, [string]$OutFile, [string]$Description)

 Write-Info "Laddar ner $Description ..."
 $progress = $ProgressPreference
 $ProgressPreference = 'SilentlyContinue' # snabbare Invoke-WebRequest
 try {
  Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
 }
 finally {
  $ProgressPreference = $progress
 }

 if (-not (Test-Path $OutFile)) {
  throw "Nedladdningen av $Description misslyckades."
 }
 $sizeMB = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
 Write-Ok "$Description nedladdad ($sizeMB MB): $OutFile"
}

function Invoke-Installer {
 param([string]$Path, [string[]]$Arguments, [string]$Description)

 Write-Info "Installerar $Description (tyst läge, kan ta flera minuter) ..."
 $proc = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -NoNewWindow

 switch ($proc.ExitCode) {
  0 { Write-Ok "$Description installerad." }
  3010 { Write-Warn2 "$Description installerad - omstart krävs så småningom." }
  default {
   throw "$Description misslyckades med felkod $($proc.ExitCode). Se C:\Windows\Temp\adk*.log"
  }
 }
}

function Get-BootsectPath {
 $p = Get-AdkPaths
 $candidate = Join-Path $p.DeploymentTools "$Architecture\BCDBoot\bootsect.exe"
 if (Test-Path $candidate) { return $candidate }

 $found = Get-ChildItem -Path $p.Adk -Filter 'bootsect.exe' -Recurse -ErrorAction SilentlyContinue |
  Select-Object -First 1
 if ($found) { return $found.FullName }
 return $null
}

# ---------------------------------------------------------------------------
# 1. Installera ADK + WinPE-tillägget
# ---------------------------------------------------------------------------
if ($SkipAdkInstall) {
 Write-Step 'Steg 1/5 - ADK-installation hoppas över'
 if (-not (Test-AdkInstalled)) {
  throw 'ADK eller WinPE-tillägget saknas. Kör utan -SkipAdkInstall.'
 }
 Write-Ok 'Befintlig ADK-installation hittad.'
}
elseif (Test-AdkInstalled) {
 Write-Step 'Steg 1/5 - ADK redan installerat'
 $p = Get-AdkPaths
 Write-Ok "Hittade ADK i: $($p.Adk)"
 Write-Info 'Använder befintlig installation. Kör med -SkipAdkInstall för att slippa kontrollen.'
}
else {
 Write-Step 'Steg 1/5 - Laddar ner och installerar Windows ADK + WinPE'

 New-Item -Path $DownloadDir -ItemType Directory -Force | Out-Null

 $adkSetup = Join-Path $DownloadDir 'adksetup.exe'
 $winpeSetup = Join-Path $DownloadDir 'adkwinpesetup.exe'

 Invoke-Download -Uri $AdkUrl -OutFile $adkSetup -Description 'Windows ADK'
 Invoke-Download -Uri $WinPeUrl -OutFile $winpeSetup -Description 'WinPE-tillägget'

 # Standardsökväg används (ingen /installpath), bara Deployment Tools installeras.
 Invoke-Installer -Path $adkSetup -Description 'Windows ADK' -Arguments @(
  '/quiet'
  '/norestart'
  '/ceip', 'off'
  '/features', 'OptionId.DeploymentTools'
 )

 Invoke-Installer -Path $winpeSetup -Description 'WinPE-tillägget' -Arguments @(
  '/quiet'
  '/norestart'
  '/ceip', 'off'
  '/features', 'OptionId.WindowsPreinstallationEnvironment'
 )

 if (-not (Test-AdkInstalled)) {
  Write-AdkDiagnostics
  throw 'Installationen ser ut att ha gått igenom men copype.cmd hittas inte. Se kontrollstatus ovan.'
 }
}

$Adk = Get-AdkPaths
Write-Info "ADK-rot: $($Adk.Adk)"

# ---------------------------------------------------------------------------
# 2. Bygg WinPE-arbetskatalogen med copype
# ---------------------------------------------------------------------------

Write-Step "Steg 2/5 - Bygger WinPE-arbetskatalog ($WorkRoot)"

if (Test-Path $WorkRoot) {
 Write-Warn2 "$WorkRoot finns redan och tas bort."
 # Avmontera ev. hängande DISM-mount innan katalogen raderas
 $mountDir = Join-Path $WorkRoot 'mount'
 if (Test-Path $mountDir) {
  & dism.exe /Unmount-Image /MountDir:$mountDir /Discard 2>&1 | Out-Null
 }
 Remove-Item -Path $WorkRoot -Recurse -Force
}

# copype måste köra i en miljö där DandISetEnv.bat har satt sökvägarna.
$copypeCmd = 'call "{0}" && call "{1}" {2} "{3}"' -f $Adk.DandISetEnv, $Adk.Copype, $Architecture, $WorkRoot
$output = & $env:ComSpec /c $copypeCmd 2>&1
$output | ForEach-Object { Write-Info $_ }

$MediaRoot = Join-Path $WorkRoot 'media'
if (-not (Test-Path (Join-Path $MediaRoot 'sources\boot.wim'))) {
 throw "copype misslyckades - boot.wim saknas i $MediaRoot"
}
Write-Ok "WinPE-media byggt i $MediaRoot"

# ---------------------------------------------------------------------------
# 3. Vänta på och välj USB-sticka
# ---------------------------------------------------------------------------

Write-Step 'Steg 3/5 - Välj USB-sticka'

Write-Host ''
Write-Host ' Sätt i USB-stickan som ska bli bootbar.' -ForegroundColor White
Write-Host ' ALLT innehåll på den kommer att raderas.' -ForegroundColor Yellow
Write-Host ''
Read-Host ' Tryck Enter när stickan sitter i'

$usbDisks = @()
for ($i = 1; $i -le 10; $i++) {
 $usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Sort-Object Number)
 if ($usbDisks.Count -gt 0) { break }
 Write-Info "Ingen USB-disk hittad, försöker igen ($i/10) ..."
 Start-Sleep -Seconds 3
}

if ($usbDisks.Count -eq 0) {
 throw 'Ingen USB-ansluten disk hittades. Kontrollera att stickan sitter i och kör om skriptet.'
}

Write-Host ''
$usbDisks | Select-Object Number,
 @{ N = 'Modell'; E = { $_.FriendlyName } },
 @{ N = 'Storlek'; E = { '{0:N1} GB' -f ($_.Size / 1GB) } },
 @{ N = 'Partitionsstil'; E = { $_.PartitionStyle } },
 @{ N = 'Serienr'; E = { $_.SerialNumber } } |
 Format-Table -AutoSize | Out-String | Write-Host

$diskNumber = Read-Host ' Ange disknummer som ska raderas och användas'
$disk = $usbDisks | Where-Object { $_.Number -eq [int]$diskNumber }
if (-not $disk) {
 throw "Disk $diskNumber finns inte i listan över USB-diskar. Avbryter."
}

Write-Host ''
Write-Host (' Vald disk: {0} - {1} ({2:N1} GB)' -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB)) -ForegroundColor Yellow
Write-Host ' Allt på denna disk raderas permanent.' -ForegroundColor Red
$confirm = Read-Host ' Skriv RADERA för att fortsätta'

if ($confirm -cne 'RADERA') {
 Write-Host ' Avbrutet av användaren.' -ForegroundColor Yellow
 return
}

# Kontrollera att önskad enhetsbokstav är ledig - eller att den sitter på stickan
# som ändå ska rensas, i vilket fall den frigörs av Clear-Disk.
$letterInUse = Get-Volume -DriveLetter $DataDriveLetter -ErrorAction SilentlyContinue
if ($letterInUse) {
 $owner = $null
 try {
  $owner = Get-Partition -DriveLetter $DataDriveLetter -ErrorAction Stop
 } catch {
  $owner = $null
 }

 if ($owner -and $owner.DiskNumber -eq $disk.Number) {
  Write-Warn2 "${DataDriveLetter}: sitter på den valda stickan och frigörs när disken rensas."
 }
 elseif ($owner) {
  throw ("Enhetsbokstaven {0}: används av disk {1} (partition {2}). " -f $DataDriveLetter, $owner.DiskNumber, $owner.PartitionNumber) +
   "Frigör den eller kör med -DataDriveLetter <bokstav>."
 }
 else {
  throw ("Enhetsbokstaven {0}: är upptagen av en enhet som inte kan rensas " -f $DataDriveLetter) +
   "(optisk enhet, monterad ISO eller nätverksenhet). Frigör den eller kör med -DataDriveLetter <bokstav>."
 }
}

# ---------------------------------------------------------------------------
# 4. Partitionera och formatera
# ---------------------------------------------------------------------------

Write-Step 'Steg 4/5 - Partitionerar och formaterar'

if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }

Write-Info 'Rensar disken ...'
Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false

Start-Sleep -Seconds 2
$disk = Get-Disk -Number $disk.Number

# Clear-Disk behåller partitionsstilen om disken redan var initierad, så
# Initialize-Disk får bara köras när disken faktiskt är RAW.
switch ($disk.PartitionStyle) {
 'RAW' {
  Write-Info 'Initierar som MBR ...'
  Initialize-Disk -Number $disk.Number -PartitionStyle MBR
 }
 'MBR' {
  Write-Info 'Disken är redan MBR - ingen initiering behövs.'
 }
 default {
  Write-Info "Konverterar $($disk.PartitionStyle) till MBR ..."
  try {
   Set-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction Stop
  }
  catch {
   Write-Warn2 'Set-Disk misslyckades - faller tillbaka på diskpart.'
   $dpScript = Join-Path $env:TEMP 'convert-mbr.txt'
   Set-Content -Path $dpScript -Encoding ASCII -Value @(
    "select disk $($disk.Number)"
    'clean'
    'convert mbr'
    'exit'
   )
   & diskpart.exe /s $dpScript | Out-Null
   Remove-Item -Path $dpScript -Force -ErrorAction SilentlyContinue

   $disk = Get-Disk -Number $disk.Number
   if ($disk.PartitionStyle -ne 'MBR') {
    throw "Kunde inte konvertera disk $($disk.Number) till MBR."
   }
  }
 }
}

Start-Sleep -Seconds 2

# Bokstaven kan dröja några sekunder innan den släppt av Explorer/mountmgr.
for ($i = 0; $i -lt 10; $i++) {
 if (-not (Get-Volume -DriveLetter $DataDriveLetter -ErrorAction SilentlyContinue)) { break }
 Write-Info "Väntar på att ${DataDriveLetter}: ska frigöras ..."
 Start-Sleep -Seconds 2
}
if (Get-Volume -DriveLetter $DataDriveLetter -ErrorAction SilentlyContinue) {
 throw "Enhetsbokstaven ${DataDriveLetter}: släpptes inte. Stäng öppna Explorer-fönster mot stickan och kör om."
}

# Partition 1 - bootpartition, FAT32, aktiv, ligger först på disken
Write-Info "Skapar bootpartition ($BootPartitionSizeMB MB, FAT32, aktiv) ..."
$bootPart = New-Partition -DiskNumber $disk.Number `
 -Size ($BootPartitionSizeMB * 1MB) `
 -IsActive `
 -AssignDriveLetter

Start-Sleep -Seconds 2
$bootPart = Get-Partition -DiskNumber $disk.Number -PartitionNumber $bootPart.PartitionNumber
$BootDrive = $bootPart.DriveLetter

Format-Volume -DriveLetter $BootDrive `
 -FileSystem FAT32 `
 -NewFileSystemLabel $BootLabel `
 -Force -Confirm:$false | Out-Null
Write-Ok "Bootpartition klar: ${BootDrive}: ($BootLabel)"

# Partition 2 - datapartition, NTFS, resten av disken
Write-Info "Skapar datapartition (resten av disken, NTFS, ${DataDriveLetter}:) ..."
$dataPart = New-Partition -DiskNumber $disk.Number `
 -UseMaximumSize `
 -DriveLetter $DataDriveLetter

Start-Sleep -Seconds 2

Format-Volume -DriveLetter $DataDriveLetter `
 -FileSystem NTFS `
 -NewFileSystemLabel $DataLabel `
 -Force -Confirm:$false | Out-Null

$dataSizeGB = [math]::Round($dataPart.Size / 1GB, 1)
Write-Ok "Datapartition klar: ${DataDriveLetter}: ($DataLabel, $dataSizeGB GB)"

# ---------------------------------------------------------------------------
# 5. Kopiera WinPE-filerna och förbered datapartitionen
# ---------------------------------------------------------------------------

Write-Step 'Steg 5/5 - Kopierar WinPE-filer till stickan'

Write-Info "Kopierar $MediaRoot -> ${BootDrive}:\ ..."
& robocopy.exe $MediaRoot "${BootDrive}:\" /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null

if ($LASTEXITCODE -ge 8) {
 throw "robocopy misslyckades med felkod $LASTEXITCODE"
}
Write-Ok 'Bootfiler kopierade.'

# Bootsektor för legacy BIOS. UEFI-boot fungerar redan utan detta steg.
$bootsect = Get-BootsectPath
if ($bootsect) {
 Write-Info 'Skriver bootsektor för legacy BIOS ...'
 & $bootsect /nt60 "${BootDrive}:" /mbr | Out-Null
 if ($LASTEXITCODE -eq 0) {
  Write-Ok 'Bootsektor skriven (UEFI + legacy BIOS).'
 } else {
  Write-Warn2 "bootsect returnerade $LASTEXITCODE - UEFI-boot fungerar ändå."
 }
} else {
 Write-Warn2 'bootsect.exe hittades inte - stickan bootar via UEFI men inte legacy BIOS.'
}

# Mappstruktur på datapartitionen
Write-Info "Skapar mappstruktur på ${DataDriveLetter}: ..."
$folders = @('stuff', 'stuff\Drivers', 'stuff\Images', 'stuff\Scripts', 'stuff\Tools', 'stuff\Logs')
foreach ($f in $folders) {
 New-Item -Path (Join-Path "${DataDriveLetter}:\" $f) -ItemType Directory -Force | Out-Null
}
Write-Ok "Mappar skapade under ${DataDriveLetter}:\stuff"

# Hjälpskript som hittar datapartitionen på etikett i stället för enhetsbokstav.
# I WinPE tilldelas bokstäver dynamiskt - E: på den här maskinen är inte
# nödvändigtvis E: när stickan bootas.
$findScript = @"
@echo off
REM Sätter %DATA% till enhetsbokstaven för volymen med etiketten $DataLabel.
set DATA=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
 if exist %%d:\stuff\ (
  vol %%d: 2>nul | find /i "$DataLabel" >nul && set DATA=%%d:
 )
)
if defined DATA (
 echo Datapartition hittad: %DATA%
) else (
 echo Datapartitionen hittades inte.
)
"@
Set-Content -Path "${BootDrive}:\FindData.cmd" -Value $findScript -Encoding ASCII
Write-Ok "Hjälpskript skapat: ${BootDrive}:\FindData.cmd"

# ---------------------------------------------------------------------------
# Sammanfattning
# ---------------------------------------------------------------------------

Write-Step 'Klart'

$bootVol = Get-Volume -DriveLetter $BootDrive
$dataVol = Get-Volume -DriveLetter $DataDriveLetter
Write-Host ''
Write-Host (' {0,-14} {1,-8} {2,-8} {3,10} {4,10}' -f 'Etikett', 'Enhet', 'FS', 'Storlek', 'Ledigt') -ForegroundColor White
Write-Host (' {0,-14} {1,-8} {2,-8} {3,10} {4,10}' -f `
 $bootVol.FileSystemLabel, "$($bootVol.DriveLetter):", $bootVol.FileSystem,
 ('{0:N1} GB' -f ($bootVol.Size / 1GB)), ('{0:N1} GB' -f ($bootVol.SizeRemaining / 1GB)))
Write-Host (' {0,-14} {1,-8} {2,-8} {3,10} {4,10}' -f `
 $dataVol.FileSystemLabel, "$($dataVol.DriveLetter):", $dataVol.FileSystem,
 ('{0:N1} GB' -f ($dataVol.Size / 1GB)), ('{0:N1} GB' -f ($dataVol.SizeRemaining / 1GB)))

Write-Host ''
Write-Host ' Nästa steg:' -ForegroundColor White
Write-Host " Lägg drivrutiner i ${DataDriveLetter}:\stuff\Drivers" -ForegroundColor Gray
Write-Host " Lägg images i ${DataDriveLetter}:\stuff\Images" -ForegroundColor Gray
Write-Host " Arbetskatalog $WorkRoot" -ForegroundColor Gray
Write-Host ''
Write-Host ' Injicera drivrutiner i boot.wim och kopiera om:' -ForegroundColor White
Write-Host " Dism /Mount-Image /ImageFile:$MediaRoot\sources\boot.wim /Index:1 /MountDir:$WorkRoot\mount" -ForegroundColor DarkGray
Write-Host " Dism /Image:$WorkRoot\mount /Add-Driver /Driver:C:\drivers /Recurse" -ForegroundColor DarkGray
Write-Host " Dism /Unmount-Image /MountDir:$WorkRoot\mount /Commit" -ForegroundColor DarkGray
Write-Host " Copy-Item $MediaRoot\sources\boot.wim ${BootDrive}:\sources\ -Force" -ForegroundColor DarkGray
Write-Host ''
