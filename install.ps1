# Install CosmoGrav for Windows: sets up yt-dlp, ffmpeg and Deno in your user folder and installs the app.
# No admin rights, no security warnings. Safe to run again to repair or update.
#
#   irm https://raw.githubusercontent.com/raetori/ultra-hd-youtube-downloader/main/install.ps1 | iex
#
# Set $env:COSMOGRAV_UPDATE = '1' to skip working tools and stay quiet (the app's "Update now" button does this).
# Set $env:COSMOGRAV_ZIP to a local CosmoGrav-Windows.zip to install that build instead of the latest release (used by CI).
# CosmoGrav-Setup.exe runs this script hidden with COSMOGRAV_GUI=1 and COSMOGRAV_EXE set to itself, so it installs that file.

& {
  $ProgressPreference = 'SilentlyContinue'
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

  $AppName  = 'CosmoGrav'
  $Repo     = 'raetori/ultra-hd-youtube-downloader'
  $Update   = $env:COSMOGRAV_UPDATE -eq '1'
  $Gui      = $env:COSMOGRAV_GUI -eq '1'
  $Base     = Join-Path $env:LOCALAPPDATA 'CosmoGrav'
  $Bin      = Join-Path $Base 'bin'
  $AppDir   = Join-Path $Base 'app'
  $Exe      = Join-Path $AppDir 'CosmoGrav.exe'
  $Tmp      = Join-Path ([IO.Path]::GetTempPath()) ('cosmograv-' + [guid]::NewGuid().ToString('N'))

  function Say($text)  { Write-Host ''; Write-Host $text -ForegroundColor Yellow }
  function Note($text) { Write-Host $text }
  function Fail($text) {
    Write-Host ''
    Write-Host "Setup failed: $text" -ForegroundColor Red
    Write-Host 'Send a screenshot of this window to whoever shared the installer.'
    Write-Host ''
    throw 'CosmoGrav setup failed'
  }

  # Downloads with Windows' built-in curl (fast, shows progress), falling back to PowerShell.
  function Get-File($url, $out) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
      if ($Update -or $Gui) { & $curl -fsSL --retry 3 --connect-timeout 20 -o $out $url 2>$null }
      else { & $curl -fL --retry 3 --connect-timeout 20 --progress-bar -o $out $url }
      if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) { return $true }
    }
    try {
      Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -Headers @{ 'User-Agent' = 'CosmoGrav-Installer' }
      return (Test-Path $out)
    } catch { return $false }
  }

  function Expand-Zip($zip, $dest) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
      & $tar -xf $zip -C $dest 2>$null
      if ($LASTEXITCODE -eq 0) { return $true }
    }
    try { Expand-Archive -Path $zip -DestinationPath $dest -Force; return $true } catch { return $false }
  }

  function Test-Tool($path, $arg) {
    if (-not (Test-Path $path)) { return $false }
    try { & $path $arg *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false }
  }

  function Test-Tools {
    (Test-Tool (Join-Path $Bin 'yt-dlp.exe') '--version') -and
    (Test-Tool (Join-Path $Bin 'ffmpeg.exe') '-version') -and
    (Test-Tool (Join-Path $Bin 'ffprobe.exe') '-version')
  }

  try {
    if (-not $Update -and -not $Gui) {
      Clear-Host
      Write-Host '=============================================='
      Write-Host '   CosmoGrav setup'
      Write-Host '   by Creation of Cosmos - creationofcosmos.com'
      Write-Host '=============================================='
      Write-Host 'This takes 1-3 minutes and only needs to be done once.'
      Write-Host 'Reminder: only download videos you have the rights to use.'
    }

    if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'CosmoGrav needs Windows 10 or 11.' }
    if (-not [Environment]::Is64BitOperatingSystem) { Fail 'CosmoGrav needs 64-bit Windows.' }
    $net = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    if (-not $net -or $net -lt 528040) {
      Fail 'this PC needs a Windows update first (.NET Framework 4.8). Install it from https://dotnet.microsoft.com/download/dotnet-framework/net48 then run this line again.'
    }

    New-Item -ItemType Directory -Force -Path $Bin, $AppDir, $Tmp | Out-Null

    if ($Update -and (Test-Tools)) {
      Note 'Download tools are already set up.'
    } else {
      Say '1/4  Downloading yt-dlp (the download engine)...'
      $ytdlp = Join-Path $Tmp 'yt-dlp.exe'
      if (-not (Get-File 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' $ytdlp)) { Fail "couldn't download yt-dlp. Check your internet connection." }
      Move-Item -Force $ytdlp (Join-Path $Bin 'yt-dlp.exe')
      if (-not (Test-Tool (Join-Path $Bin 'yt-dlp.exe') '--version')) { Fail "yt-dlp downloaded but won't run." }
      Set-Content -Path (Join-Path $Base 'last-update') -Value (Get-Date -Format o)

      Say '2/4  Getting ffmpeg (combines and converts video, about 150 MB)...'
      $zip = Join-Path $Tmp 'ffmpeg.zip'
      # yt-dlp's own ffmpeg builds (on GitHub), with gyan.dev's builds as a backup.
      $got = (Get-File 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' $zip) -or
             (Get-File 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' $zip)
      if (-not $got) { Fail "couldn't download ffmpeg. Check your internet connection." }
      $dir = Join-Path $Tmp 'ffmpeg'
      if (-not (Expand-Zip $zip $dir)) { Fail 'the ffmpeg download was damaged. Run the installer again.' }
      foreach ($tool in 'ffmpeg.exe', 'ffprobe.exe') {
        $found = Get-ChildItem -Path $dir -Recurse -Filter $tool | Select-Object -First 1
        if ($found) { Copy-Item -Force $found.FullName (Join-Path $Bin $tool) }
      }
      if (-not ((Test-Tool (Join-Path $Bin 'ffmpeg.exe') '-version') -and (Test-Tool (Join-Path $Bin 'ffprobe.exe') '-version'))) {
        Fail "couldn't set up ffmpeg. Check your internet connection and run the installer again."
      }

      Say '3/4  Getting Deno (needed for YouTube)...'
      $denoZip = Join-Path $Tmp 'deno.zip'
      if ((Get-File 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' $denoZip) -and (Expand-Zip $denoZip (Join-Path $Tmp 'deno'))) {
        Copy-Item -Force (Join-Path $Tmp 'deno\deno.exe') (Join-Path $Bin 'deno.exe') -ErrorAction SilentlyContinue
      }
      if (-not (Test-Tool (Join-Path $Bin 'deno.exe') '--version')) { Note 'Warning: Deno did not install. YouTube downloads may be limited to lower quality.' }
    }

    Say '4/4  Installing the app...'
    $appZip = Join-Path $Tmp 'app.zip'
    $newApp = Join-Path $Tmp 'app'
    if ($env:COSMOGRAV_EXE) {
      # Installing from CosmoGrav-Setup.exe: that file is the app.
      New-Item -ItemType Directory -Force -Path $newApp | Out-Null
      Copy-Item -Force $env:COSMOGRAV_EXE (Join-Path $newApp 'CosmoGrav.exe')
      $v = (Get-Item $env:COSMOGRAV_EXE).VersionInfo
      $version = "$($v.FileMajorPart).$($v.FileMinorPart).$($v.FileBuildPart)"
    } elseif ($env:COSMOGRAV_ZIP) {
      Copy-Item -Force $env:COSMOGRAV_ZIP $appZip
      $version = 'local build'
    } else {
      # Windows releases are tagged win-v1.2.3 (the Mac app uses v1.2.3).
      try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=30" -UseBasicParsing -Headers @{ 'User-Agent' = 'CosmoGrav-Installer' }
      } catch { Fail "couldn't reach GitHub to find the latest version. Check your internet connection." }
      $release = $releases | Where-Object { $_.tag_name -like 'win-v*' -and -not $_.draft -and -not $_.prerelease } |
        Sort-Object { [version]($_.tag_name.Substring(5)) } -Descending | Select-Object -First 1
      if (-not $release) { Fail 'no Windows version has been published yet.' }
      $version = $release.tag_name.Substring(5)
      if (-not (Get-File "https://github.com/$Repo/releases/download/$($release.tag_name)/CosmoGrav-Windows.zip" $appZip)) {
        Fail "couldn't download the app. Check your internet connection."
      }
    }
    if (-not $env:COSMOGRAV_EXE -and -not (Expand-Zip $appZip $newApp)) { Fail 'the app download was damaged. Run the installer again.' }
    $newExe = Get-ChildItem -Path $newApp -Recurse -Filter 'CosmoGrav.exe' | Select-Object -First 1
    if (-not $newExe) { Fail 'the app download was incomplete. Run the installer again.' }

    # Close a running copy, then swap in the new version.
    Get-Process -Name 'CosmoGrav' -ErrorAction SilentlyContinue | Where-Object { "$($_.Id)" -ne $env:COSMOGRAV_SETUP_PID } |
      Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    Get-ChildItem -Path $AppDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Force -Recurse (Join-Path $newExe.DirectoryName '*') $AppDir
    if (-not (Test-Path $Exe)) { Fail "couldn't copy the app into $AppDir." }
    Get-ChildItem -Path $Base -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    # Start menu and desktop shortcuts.
    $shell = New-Object -ComObject WScript.Shell
    $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"
    $desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
    $links = @($startMenu)
    if (-not $Update -or (Test-Path $desktop)) { $links += $desktop }
    foreach ($path in $links) {
      $link = $shell.CreateShortcut($path)
      $link.TargetPath = $Exe
      $link.WorkingDirectory = $AppDir
      $link.IconLocation = "$Exe,0"
      $link.Description = 'Download videos as Premiere-ready MP4 files'
      $link.Save()
    }

    # An entry in Settings > Apps so CosmoGrav can be removed like any other app.
    $uninstall = Join-Path $Base 'uninstall.ps1'
    @'
$ErrorActionPreference = 'SilentlyContinue'
Get-Process -Name 'CosmoGrav' | Stop-Process -Force
Start-Sleep -Milliseconds 800
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'CosmoGrav.lnk') -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'CosmoGrav.lnk') -Force
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CosmoGrav' -Recurse -Force
Remove-Item (Join-Path $env:LOCALAPPDATA 'CosmoGrav') -Recurse -Force
Write-Host 'CosmoGrav was removed. Your downloaded videos were not touched.'
Start-Sleep -Seconds 3
'@ | Set-Content -Path $uninstall -Encoding UTF8
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CosmoGrav'
    New-Item -Path $key -Force | Out-Null
    $size = [int]((Get-ChildItem -Path $Base -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB)
    $values = @{
      DisplayName = 'CosmoGrav'; Publisher = 'Creation of Cosmos'; DisplayIcon = "$Exe,0"; InstallLocation = $Base
      URLInfoAbout = 'https://www.creationofcosmos.com'; UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstall`""
    }
    if ($version -ne 'local build') { $values.DisplayVersion = $version }
    foreach ($name in $values.Keys) { Set-ItemProperty -Path $key -Name $name -Value $values[$name] }
    Set-ItemProperty -Path $key -Name 'NoModify' -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name 'NoRepair' -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name 'EstimatedSize' -Value $size -Type DWord

    Say 'All set!'
    if (-not $Update -and -not $Gui) {
      Note 'CosmoGrav is in your Start menu and on your desktop.'
      Note 'Tip: right-click its taskbar icon > Pin to taskbar.'
      Note ''
      Note 'Opening it now... You can close this window.'
    }
    # The app must not inherit the setup's settings (its Update now button runs this script again).
    Remove-Item Env:COSMOGRAV_EXE, Env:COSMOGRAV_GUI, Env:COSMOGRAV_SETUP_PID -ErrorAction SilentlyContinue
    if ($env:COSMOGRAV_NO_LAUNCH -ne '1') { Start-Process -FilePath $Exe -WorkingDirectory $AppDir }
  } catch {
    if ($_.Exception.Message -ne 'CosmoGrav setup failed') {
      Write-Host ''
      Write-Host "Setup failed: $($_.Exception.Message)" -ForegroundColor Red
      Write-Host 'Send a screenshot of this window to whoever shared the installer.'
    }
    $global:LASTEXITCODE = 1
  } finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  }
}
