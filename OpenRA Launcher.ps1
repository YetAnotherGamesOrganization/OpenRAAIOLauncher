# =========================
# SAFE MODE INIT (NO ERRORS EVER)
# =========================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "SilentlyContinue"

# =========================
# PATHS
# =========================
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Join-Path $root "app"
$data = Join-Path $root "zData"
$userData = Join-Path $root "zUserData"
$assets = Join-Path $data "portable\assets"

# =========================
# WINDOW
# =========================
$form = New-Object Windows.Forms.Form
$form.Text = "OpenRA Launcher"
$form.Size = New-Object Drawing.Size(1100, 650)
$form.StartPosition = "CenterScreen"
$form.BackColor = [Drawing.Color]::FromArgb(20,20,20)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

# =========================
# ICON (SAFE LOAD)
# =========================
try {
    $iconPath = Join-Path $assets "icon.ico"
    if (Test-Path $iconPath) {
        $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
    }
} catch {}

# =========================
# FIND GAME EXE
# =========================
function Find-Exe($name) {
    foreach ($p in @($root,$app)) {
        if (Test-Path $p) {
            $f = Get-ChildItem $p -Recurse -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return $null
}

# =========================
# CONTENT STATE DETECTION
# =========================
function Get-ContentState {
    $state = @{
        RA = $false
        TD = $false
        D2K = $false
    }

    # EXE-based detection
    if (Find-Exe "RedAlert.exe")     { $state.RA = $true }
    if (Find-Exe "TiberianDawn.exe") { $state.TD = $true }
    if (Find-Exe "Dune2000.exe")     { $state.D2K = $true }

    # mod folder detection (OpenRA style)
    if (Test-Path (Join-Path $app "mods\ra"))  { $state.RA = $true }
    if (Test-Path (Join-Path $app "mods\cnc")) { $state.TD = $true }
    if (Test-Path (Join-Path $app "mods\d2k")) { $state.D2K = $true }

    return $state
}

# =========================
# PORTABLE MODE SETUP
# =========================
function Enable-PortableMode {
    param([string]$TargetMode = "UserData")
    
    $supportDir = Join-Path $app "Support"
    $targetDir = if ($TargetMode -eq "Portable") { $data } else { $userData }
    
    try {
        if (!(Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        
        if (Test-Path $supportDir) {
            cmd /c rmdir "$supportDir" 2>$null
        }
        
        cmd /c mklink /J "$supportDir" "$targetDir" 2>$null
    } catch {}
}

# =========================
# SAFE LAUNCH
# =========================
function Launch($exe, $mode) {
    $path = Find-Exe $exe
    if ($path) {
        Enable-PortableMode -TargetMode $mode
        Start-Process $path
    }
}

# =========================
# PROGRESS BAR STATE
# =========================
$script:ProgressValue = 0
$script:IsDownloading = $false

function Set-ProgressBar {
    param([int]$Percent)
    
    $script:ProgressValue = [Math]::Min([int]$Percent, 100)
    
    if ($script:ProgressLabel) {
        $script:ProgressLabel.Text = "Downloading... $($script:ProgressValue)%"
    }
    
    if ($script:ProgressBar) {
        $script:ProgressBar.Value = $script:ProgressValue
    }
    
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

# =========================
# DOWNLOAD ENGINE (WORKING)
# =========================
function Download-File {
    param(
        [string]$url,
        [string]$out
    )
    
    try {
        $wc = New-Object System.Net.WebClient
        
        $progressAction = {
            param($s,$e)
            Set-ProgressBar $e.ProgressPercentage
        }
        
        $wc.DownloadProgressChanged += $progressAction
        $wc.DownloadFileCompleted += {
            $script:IsDownloading = $false
        }
        
        $script:IsDownloading = $true
        $wc.DownloadFileAsync((New-Object Uri $url), $out)
        
        $timeout = 0
        while ($script:IsDownloading -and $timeout -lt 10800) {
            Start-Sleep -Milliseconds 100
            $timeout += 1
            [System.Windows.Forms.Application]::DoEvents()
        }
        
        return (Test-Path $out)
    }
    catch {
        $script:IsDownloading = $false
        return $false
    }
}

# =========================
# INSTALL OPENRA (FIXED)
# =========================
function Install-OpenRA {
    try {
        $script:ProgressLabel.Text = "Fetching latest release..."
        $script:ProgressValue = 0
        $script:ProgressBar.Value = 0
        $form.Refresh()
        
        $repo = "OpenRA/OpenRA"
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -TimeoutSec 10 -ErrorAction Stop
        
        if (-not $rel) {
            $script:ProgressLabel.Text = "Error: Could not reach GitHub"
            $script:ProgressBar.Value = 0
            return $false
        }
        
        $asset = $null
        foreach ($a in $rel.assets) {
            if ($a.name -like "*win*portable*") {
                $asset = $a
                break
            }
        }
        
        if (-not $asset) { 
            $script:ProgressLabel.Text = "Error: No portable release found"
            $script:ProgressBar.Value = 0
            return $false
        }
        
        $zip = Join-Path $env:TEMP "openra.zip"
        $tmp = Join-Path $env:TEMP "openra_extract"
        
        # Remove old files
        if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        
        # Download
        $script:ProgressLabel.Text = "Downloading OpenRA..."
        $script:ProgressValue = 0
        $script:ProgressBar.Value = 0
        $form.Refresh()
        
        $dlSuccess = Download-File -url $asset.browser_download_url -out $zip
        
        if (-not $dlSuccess) {
            $script:ProgressLabel.Text = "Error: Download failed"
            $script:ProgressBar.Value = 0
            return $false
        }
        
        # Extract
        $script:ProgressLabel.Text = "Extracting files..."
        Set-ProgressBar 75
        
        Expand-Archive -Path $zip -DestinationPath $tmp -Force -ErrorAction Stop
        
        # Copy to app
        if (!(Test-Path $app)) { New-Item -ItemType Directory -Path $app -Force | Out-Null }
        
        # Remove old app contents
        Get-ChildItem -Path $app -Recurse -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        
        Copy-Item -Path "$tmp\*" -Destination $app -Recurse -Force -ErrorAction Stop
        
        # Cleanup temp files
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        
        $script:ProgressLabel.Text = "Installation complete!"
        Set-ProgressBar 100
        
        return $true
    }
    catch {
        $script:ProgressLabel.Text = "Error: $_"
        $script:ProgressBar.Value = 0
        return $false
    }
}

# =========================
# SMART REPAIR (FIXED)
# =========================
function Smart-Repair {
    try {
        $script:ProgressLabel.Text = "Checking games..."
        Set-ProgressBar 20
        
        $state = Get-ContentState
        
        $missing = 0
        if (-not $state.RA) { $missing++ }
        if (-not $state.TD) { $missing++ }
        if (-not $state.D2K) { $missing++ }
        
        if ($missing -eq 0) {
            $script:ProgressLabel.Text = "All games present - no repair needed"
            Set-ProgressBar 100
            return $true
        }
        
        $script:ProgressLabel.Text = "Missing $missing game(s) - installing..."
        Install-OpenRA
        
        return $true
    }
    catch {
        $script:ProgressLabel.Text = "Error: Repair failed"
        $script:ProgressBar.Value = 0
        return $false
    }
}

# =========================
# MAIN LAYOUT STRUCTURE
# =========================
$topPanel = New-Object Windows.Forms.Panel
$topPanel.Size = New-Object Drawing.Size(1100, 570)
$topPanel.Location = New-Object Drawing.Point(0, 0)
$topPanel.BackColor = [Drawing.Color]::FromArgb(20,20,20)
$form.Controls.Add($topPanel)

$side = New-Object Windows.Forms.Panel
$side.Size = New-Object Drawing.Size(200, 570)
$side.Location = New-Object Drawing.Point(0, 0)
$side.BackColor = [Drawing.Color]::FromArgb(30,30,30)
$topPanel.Controls.Add($side)

$content = New-Object Windows.Forms.Panel
$content.Size = New-Object Drawing.Size(900, 570)
$content.Location = New-Object Drawing.Point(200, 0)
$content.BackColor = [Drawing.Color]::FromArgb(20,20,20)
$content.AutoScroll = $true
$topPanel.Controls.Add($content)

$progressPanel = New-Object Windows.Forms.Panel
$progressPanel.Size = New-Object Drawing.Size(1100, 80)
$progressPanel.Location = New-Object Drawing.Point(0, 570)
$progressPanel.BackColor = [Drawing.Color]::FromArgb(25,25,25)
$progressPanel.BorderStyle = "FixedSingle"
$form.Controls.Add($progressPanel)

# Standard progress bar
$script:ProgressBar = New-Object Windows.Forms.ProgressBar
$script:ProgressBar.Size = New-Object Drawing.Size(850, 20)
$script:ProgressBar.Location = New-Object Drawing.Point(220, 15)
$script:ProgressBar.Style = "Continuous"
$script:ProgressBar.BackColor = [Drawing.Color]::FromArgb(40, 40, 40)
$script:ProgressBar.ForeColor = [Drawing.Color]::Lime
$progressPanel.Controls.Add($script:ProgressBar)

$script:ProgressLabel = New-Object Windows.Forms.Label
$script:ProgressLabel.Text = "Ready"
$script:ProgressLabel.Size = New-Object Drawing.Size(850, 25)
$script:ProgressLabel.Location = New-Object Drawing.Point(220, 40)
$script:ProgressLabel.ForeColor = [Drawing.Color]::Gray
$script:ProgressLabel.Font = New-Object Drawing.Font("Segoe UI", 10)
$progressPanel.Controls.Add($script:ProgressLabel)

# =========================
# BUTTON STYLES
# =========================
$normalColor = [Drawing.Color]::FromArgb(50,50,50)
$hoverColor = [Drawing.Color]::FromArgb(70,70,70)
$activeColor = [Drawing.Color]::FromArgb(76,110,45)
$quitColor = [Drawing.Color]::FromArgb(139,0,0)

function Btn($text,$y,$action) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object Drawing.Size(180,45)
    $b.Location = New-Object Drawing.Point(10,$y)
    $b.BackColor = $normalColor
    $b.ForeColor = "White"
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = "Hand"
    $b.Font = New-Object Drawing.Font("Segoe UI", 9)

    $b.Add_MouseEnter({ $this.BackColor = $hoverColor })
    $b.Add_MouseLeave({ $this.BackColor = $normalColor })
    $b.Add_MouseDown({
        $this.BackColor = $activeColor
        $this.Size = New-Object Drawing.Size(260, 80)
        $this.Location = New-Object Drawing.Point(-30, $y - 17)
        $this.Font = New-Object Drawing.Font("Segoe UI", 12, "Bold")
    })
    $b.Add_MouseUp({
        $this.BackColor = $hoverColor
        $this.Size = New-Object Drawing.Size(180, 45)
        $this.Location = New-Object Drawing.Point(10, $y)
        $this.Font = New-Object Drawing.Font("Segoe UI", 9)
    })

    $b.Add_Click($action)
    $side.Controls.Add($b)
}

function QuitBtn($text,$y) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object Drawing.Size(180,45)
    $b.Location = New-Object Drawing.Point(10,$y)
    $b.BackColor = $quitColor
    $b.ForeColor = "White"
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = "Hand"
    $b.Font = New-Object Drawing.Font("Segoe UI", 9)

    $b.Add_MouseEnter({ $this.BackColor = [Drawing.Color]::FromArgb(170,0,0) })
    $b.Add_MouseLeave({ $this.BackColor = $quitColor })
    $b.Add_MouseDown({
        $this.BackColor = $activeColor
        $this.Size = New-Object Drawing.Size(260, 80)
        $this.Location = New-Object Drawing.Point(-30, $y - 17)
        $this.Font = New-Object Drawing.Font("Segoe UI", 12, "Bold")
    })
    $b.Add_MouseUp({
        $this.BackColor = [Drawing.Color]::FromArgb(170,0,0)
        $this.Size = New-Object Drawing.Size(180, 45)
        $this.Location = New-Object Drawing.Point(10, $y)
        $this.Font = New-Object Drawing.Font("Segoe UI", 9)
    })

    $b.Add_Click({ $form.Close() })
    $side.Controls.Add($b)
}

# =========================
# SHOW GAME PAGE
# =========================
function Show-GamePage($gameName, $gameExe, $gameCode) {
    $content.Controls.Clear()

    $state = Get-ContentState
    $gameInstalled = if ($gameCode -eq "RA") { $state.RA }
                    elseif ($gameCode -eq "TD") { $state.TD }
                    else { $state.D2K }

    $title = New-Object Windows.Forms.Label
    $title.Text = $gameName
    $title.Size = New-Object Drawing.Size(800, 70)
    $title.Location = New-Object Drawing.Point(40, 30)
    $title.ForeColor = [Drawing.Color]::FromArgb(153, 204, 0)
    $title.Font = New-Object Drawing.Font("Segoe UI", 36, "Bold")
    $content.Controls.Add($title)

    $status = New-Object Windows.Forms.Label
    $status.Size = New-Object Drawing.Size(400, 35)
    $status.Location = New-Object Drawing.Point(40, 110)
    $status.ForeColor = "White"
    $status.Font = New-Object Drawing.Font("Segoe UI", 12)
    
    if ($gameInstalled) {
        $status.Text = "✓ Game installed and ready"
        $status.ForeColor = [Drawing.Color]::LimeGreen
    } else {
        $status.Text = "✗ Game not installed"
        $status.ForeColor = [Drawing.Color]::OrangeRed
    }
    
    $content.Controls.Add($status)

    if ($gameInstalled) {
        $playBtn = New-Object Windows.Forms.Button
        $playBtn.Text = "Play"
        $playBtn.Size = New-Object Drawing.Size(280, 60)
        $playBtn.Location = New-Object Drawing.Point(40, 180)
        $playBtn.BackColor = $normalColor
        $playBtn.ForeColor = "White"
        $playBtn.FlatStyle = "Flat"
        $playBtn.FlatAppearance.BorderSize = 0
        $playBtn.Font = New-Object Drawing.Font("Segoe UI", 14, "Bold")
        $playBtn.Cursor = "Hand"

        $playBtn.Add_MouseEnter({ $this.BackColor = $hoverColor })
        $playBtn.Add_MouseLeave({ $this.BackColor = $normalColor })
        $playBtn.Add_MouseDown({
            $this.BackColor = $activeColor
            $this.Size = New-Object Drawing.Size(380, 90)
            $this.Location = New-Object Drawing.Point(-10, 150)
            $this.Font = New-Object Drawing.Font("Segoe UI", 18, "Bold")
        })
        $playBtn.Add_MouseUp({
            $this.BackColor = $hoverColor
            $this.Size = New-Object Drawing.Size(280, 60)
            $this.Location = New-Object Drawing.Point(40, 180)
            $this.Font = New-Object Drawing.Font("Segoe UI", 14, "Bold")
        })
        $playBtn.Add_Click({ Launch $gameExe "UserData" })
        $content.Controls.Add($playBtn)

        $portableBtn = New-Object Windows.Forms.Button
        $portableBtn.Text = "Play Portable"
        $portableBtn.Size = New-Object Drawing.Size(280, 60)
        $portableBtn.Location = New-Object Drawing.Point(40, 270)
        $portableBtn.BackColor = $normalColor
        $portableBtn.ForeColor = "White"
        $portableBtn.FlatStyle = "Flat"
        $portableBtn.FlatAppearance.BorderSize = 0
        $portableBtn.Font = New-Object Drawing.Font("Segoe UI", 14, "Bold")
        $portableBtn.Cursor = "Hand"

        $portableBtn.Add_MouseEnter({ $this.BackColor = $hoverColor })
        $portableBtn.Add_MouseLeave({ $this.BackColor = $normalColor })
        $portableBtn.Add_MouseDown({
            $this.BackColor = $activeColor
            $this.Size = New-Object Drawing.Size(380, 90)
            $this.Location = New-Object Drawing.Point(-10, 240)
            $this.Font = New-Object Drawing.Font("Segoe UI", 18, "Bold")
        })
        $portableBtn.Add_MouseUp({
            $this.BackColor = $hoverColor
            $this.Size = New-Object Drawing.Size(280, 60)
            $this.Location = New-Object Drawing.Point(40, 270)
            $this.Font = New-Object Drawing.Font("Segoe UI", 14, "Bold")
        })
        $portableBtn.Add_Click({ Launch $gameExe "Portable" })
        $content.Controls.Add($portableBtn)

        $info = New-Object Windows.Forms.Label
        $info.Text = "Play: Standard mode`nPlay Portable: Completely isolated sandbox experience"
        $info.Size = New-Object Drawing.Size(700, 120)
        $info.Location = New-Object Drawing.Point(40, 380)
        $info.ForeColor = [Drawing.Color]::Gray
        $info.Font = New-Object Drawing.Font("Segoe UI", 11)
        $info.AutoSize = $false
        $content.Controls.Add($info)

    } else {
        $installBtn = New-Object Windows.Forms.Button
        $installBtn.Text = "Install Game"
        $installBtn.Size = New-Object Drawing.Size(280, 70)
        $installBtn.Location = New-Object Drawing.Point(40, 180)
        $installBtn.BackColor = [Drawing.Color]::FromArgb(76, 110, 45)
        $installBtn.ForeColor = "White"
        $installBtn.FlatStyle = "Flat"
        $installBtn.FlatAppearance.BorderSize = 0
        $installBtn.Font = New-Object Drawing.Font("Segoe UI", 13, "Bold")
        $installBtn.Cursor = "Hand"

        $installBtn.Add_MouseEnter({ $this.BackColor = [Drawing.Color]::FromArgb(100, 150, 60) })
        $installBtn.Add_MouseLeave({ $this.BackColor = [Drawing.Color]::FromArgb(76, 110, 45) })
        $installBtn.Add_Click({ Show-InstallPage })
        $content.Controls.Add($installBtn)
    }
}

# =========================
# SHOW INSTALL PAGE
# =========================
function Show-InstallPage {
    $content.Controls.Clear()

    $title = New-Object Windows.Forms.Label
    $title.Text = "Install / Update"
    $title.Size = New-Object Drawing.Size(800, 70)
    $title.Location = New-Object Drawing.Point(40, 30)
    $title.ForeColor = [Drawing.Color]::FromArgb(153, 204, 0)
    $title.Font = New-Object Drawing.Font("Segoe UI", 32, "Bold")
    $content.Controls.Add($title)

    $msg = New-Object Windows.Forms.Label
    $msg.Text = "Download the latest release from GitHub"
    $msg.Size = New-Object Drawing.Size(600, 40)
    $msg.Location = New-Object Drawing.Point(40, 110)
    $msg.ForeColor = "White"
    $msg.Font = New-Object Drawing.Font("Segoe UI", 12)
    $content.Controls.Add($msg)

    $dlBtn = New-Object Windows.Forms.Button
    $dlBtn.Text = "Download Latest"
    $dlBtn.Size = New-Object Drawing.Size(280, 70)
    $dlBtn.Location = New-Object Drawing.Point(40, 200)
    $dlBtn.BackColor = [Drawing.Color]::FromArgb(76, 110, 45)
    $dlBtn.ForeColor = "White"
    $dlBtn.FlatStyle = "Flat"
    $dlBtn.FlatAppearance.BorderSize = 0
    $dlBtn.Font = New-Object Drawing.Font("Segoe UI", 13, "Bold")
    $dlBtn.Cursor = "Hand"

    $dlBtn.Add_MouseEnter({ $this.BackColor = [Drawing.Color]::FromArgb(100, 150, 60) })
    $dlBtn.Add_MouseLeave({ $this.BackColor = [Drawing.Color]::FromArgb(76, 110, 45) })

    $dlBtn.Add_Click({
        $dlBtn.Enabled = $false
        $script:ProgressLabel.Text = "Starting download..."
        $script:ProgressValue = 0
        $script:ProgressBar.Value = 0
        $form.Refresh()
        
        Install-OpenRA
        
        $dlBtn.Enabled = $true
    })

    $content.Controls.Add($dlBtn)
}

# =========================
# SIDEBAR BUTTONS
# =========================
Btn "Red Alert" 15 { Show-GamePage "Red Alert" "RedAlert.exe" "RA" }
Btn "Tiberian Dawn" 70 { Show-GamePage "Tiberian Dawn" "TiberianDawn.exe" "TD" }
Btn "Dune 2000" 125 { Show-GamePage "Dune 2000" "Dune2000.exe" "D2K" }

Btn "Install/Update" 200 { Show-InstallPage }

Btn "Smart Repair" 255 {
    $script:ProgressLabel.Text = "Starting repair..."
    $script:ProgressValue = 0
    $script:ProgressBar.Value = 0
    $form.Refresh()
    Smart-Repair
}

Btn "Check Content" 310 {
    $state = Get-ContentState
    $msg = "Red Alert: $(if ($state.RA) { 'YES' } else { 'NO' })`nTiberian Dawn: $(if ($state.TD) { 'YES' } else { 'NO' })`nDune 2000: $(if ($state.D2K) { 'YES' } else { 'NO' })"
    [System.Windows.Forms.MessageBox]::Show($msg, "Installation Status")
}

QuitBtn "Quit" 495

# =========================
# STARTUP
# =========================
$form.Add_Load({ Show-GamePage "Red Alert" "RedAlert.exe" "RA" })

$form.ShowDialog()
