# =========================
# SAFE MODE INIT
# =========================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "SilentlyContinue"

# =========================
# PATHS
# =========================
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AppDir = Join-Path $script:Root "app"
$script:DataDir = Join-Path $script:Root "zData"
$script:UserDataDir = Join-Path $script:Root "zUserData"
$script:AssetsDir = Join-Path $script:DataDir "portable\assets"

# =========================
# STATE
# =========================
$script:DownloadInProgress = $false
$script:CurrentProgress = 0

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

try {
    $iconPath = Join-Path $script:AssetsDir "icon.ico"
    if (Test-Path $iconPath) {
        $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
    }
} catch {}

# =========================
# FIND GAME EXE
# =========================
function Find-Exe($name) {
    foreach ($p in @($script:Root, $script:AppDir)) {
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
    $state = @{ RA = $false; TD = $false; D2K = $false }
    
    if (Find-Exe "RedAlert.exe") { $state.RA = $true }
    if (Find-Exe "TiberianDawn.exe") { $state.TD = $true }
    if (Find-Exe "Dune2000.exe") { $state.D2K = $true }
    
    if (Test-Path (Join-Path $script:AppDir "mods\ra")) { $state.RA = $true }
    if (Test-Path (Join-Path $script:AppDir "mods\cnc")) { $state.TD = $true }
    if (Test-Path (Join-Path $script:AppDir "mods\d2k")) { $state.D2K = $true }
    
    return $state
}

# =========================
# PORTABLE MODE SETUP
# =========================
function Enable-PortableMode {
    param([string]$TargetMode = "UserData")
    
    $supportDir = Join-Path $script:AppDir "Support"
    $targetDir = if ($TargetMode -eq "Portable") { $script:DataDir } else { $script:UserDataDir }
    
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
# PROGRESS BAR UPDATE
# =========================
function Update-ProgressBar {
    param([int]$Percent, [string]$Label)
    
    $script:CurrentProgress = [Math]::Min([int]$Percent, 100)
    
    if ($script:ProgressBar) {
        $script:ProgressBar.Value = $script:CurrentProgress
    }
    
    if ($script:ProgressLabel) {
        $script:ProgressLabel.Text = $Label
    }
    
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

# =========================
# DOWNLOAD WITH PROPER ASYNC
# =========================
function Download-OpenRA {
    try {
        Update-ProgressBar 0 "Fetching latest release from GitHub..."
        Start-Sleep -Milliseconds 500
        
        $repo = "OpenRA/OpenRA"
        $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
        
        $rel = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -TimeoutSec 15 | ConvertFrom-Json
        
        if (-not $rel) {
            Update-ProgressBar 0 "ERROR: Could not reach GitHub"
            return $false
        }
        
        # Find portable Windows ZIP
        $asset = $null
        foreach ($a in $rel.assets) {
            $name = $a.name
            if ($name -like "*x64-winportable*" -or ($name -like "*win*portable*")) {
                $asset = $a
                break
            }
        }
        
        if (-not $asset) {
            Update-ProgressBar 0 "ERROR: No Windows portable release found"
            return $false
        }
        
        Update-ProgressBar 20 "Found release: $($asset.name)"
        Start-Sleep -Milliseconds 500
        
        $zip = Join-Path $env:TEMP "openra_latest.zip"
        $tmpExtract = Join-Path $env:TEMP "openra_tmp_$(Get-Random)"
        
        # Clean old temp files
        if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue }
        
        # DOWNLOAD
        Update-ProgressBar 25 "Downloading $($asset.name)..."
        
        $script:DownloadInProgress = $true
        
        $wc = New-Object System.Net.WebClient
        $downloadCompleted = $false
        $downloadError = $false
        
        $wc.add_DownloadProgressChanged({
            $percent = [Math]::Min($_.ProgressPercentage, 99)
            Update-ProgressBar ([int]$percent) "Downloading... $percent%"
        })
        
        $wc.add_DownloadFileCompleted({
            $script:DownloadInProgress = $false
            $downloadCompleted = $true
            if ($_.Error) { $downloadError = $true }
        })
        
        $wc.DownloadFileAsync($asset.browser_download_url, $zip)
        
        # Wait for download
        $maxWait = 0
        while ($script:DownloadInProgress -and $maxWait -lt 1800) {
            Start-Sleep -Milliseconds 100
            $maxWait++
            [System.Windows.Forms.Application]::DoEvents()
        }
        
        if (-not (Test-Path $zip) -or $downloadError) {
            Update-ProgressBar 0 "ERROR: Download failed"
            return $false
        }
        
        Update-ProgressBar 80 "Extracting files..."
        Start-Sleep -Milliseconds 300
        
        # EXTRACT
        Expand-Archive -Path $zip -DestinationPath $tmpExtract -Force -ErrorAction Stop
        
        Update-ProgressBar 85 "Preparing installation..."
        
        # BACKUP
        if (!(Test-Path $script:AppDir)) {
            New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        }
        
        # Remove old app (but keep Support symlink)
        $oldAppBackup = Join-Path $env:TEMP "openra_backup_$(Get-Random)"
        if (Test-Path $script:AppDir) {
            Move-Item $script:AppDir $oldAppBackup -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        }
        
        # COPY NEW VERSION
        Copy-Item "$tmpExtract\*" $script:AppDir -Recurse -Force -ErrorAction Stop
        
        Update-ProgressBar 95 "Finalizing..."
        
        # Clean temp
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $oldAppBackup) { Remove-Item $oldAppBackup -Recurse -Force -ErrorAction SilentlyContinue }
        
        Update-ProgressBar 100 "Installation complete!"
        Start-Sleep -Milliseconds 1000
        Update-ProgressBar 0 "Ready"
        
        return $true
    }
    catch {
        Update-ProgressBar 0 "ERROR: $_"
        return $false
    }
}

# =========================
# SMART REPAIR
# =========================
function Smart-Repair {
    try {
        Update-ProgressBar 10 "Checking installed games..."
        Start-Sleep -Milliseconds 300
        
        $state = Get-ContentState
        $missing = 0
        if (-not $state.RA) { $missing++ }
        if (-not $state.TD) { $missing++ }
        if (-not $state.D2K) { $missing++ }
        
        if ($missing -eq 0) {
            Update-ProgressBar 100 "All games installed!"
            Start-Sleep -Milliseconds 1000
            Update-ProgressBar 0 "Ready"
            return $true
        }
        
        Update-ProgressBar 20 "Missing $missing game(s) - Installing..."
        Start-Sleep -Milliseconds 500
        
        Download-OpenRA
        return $true
    }
    catch {
        Update-ProgressBar 0 "Repair failed: $_"
        return $false
    }
}

# =========================
# LAYOUT
# =========================
$mainPanel = New-Object Windows.Forms.Panel
$mainPanel.Size = New-Object Drawing.Size(1100, 570)
$mainPanel.Location = New-Object Drawing.Point(0, 0)
$mainPanel.BackColor = [Drawing.Color]::FromArgb(20,20,20)
$form.Controls.Add($mainPanel)

$sidebar = New-Object Windows.Forms.Panel
$sidebar.Size = New-Object Drawing.Size(200, 570)
$sidebar.Location = New-Object Drawing.Point(0, 0)
$sidebar.BackColor = [Drawing.Color]::FromArgb(30,30,30)
$mainPanel.Controls.Add($sidebar)

$contentArea = New-Object Windows.Forms.Panel
$contentArea.Size = New-Object Drawing.Size(900, 570)
$contentArea.Location = New-Object Drawing.Point(200, 0)
$contentArea.BackColor = [Drawing.Color]::FromArgb(20,20,20)
$contentArea.AutoScroll = $true
$mainPanel.Controls.Add($contentArea)

$progressPanel = New-Object Windows.Forms.Panel
$progressPanel.Size = New-Object Drawing.Size(1100, 80)
$progressPanel.Location = New-Object Drawing.Point(0, 570)
$progressPanel.BackColor = [Drawing.Color]::FromArgb(25,25,25)
$progressPanel.BorderStyle = "FixedSingle"
$form.Controls.Add($progressPanel)

# Progress Bar
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
# BUTTON STYLES (FIXED)
# =========================
function Make-SidebarBtn {
    param([string]$Text, [int]$Y, [scriptblock]$ClickAction)
    
    $btn = New-Object Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object Drawing.Size(180, 45)
    $btn.Location = New-Object Drawing.Point(10, $Y)
    $btn.BackColor = [Drawing.Color]::FromArgb(50,50,50)
    $btn.ForeColor = "White"
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor = "Hand"
    $btn.Font = New-Object Drawing.Font("Segoe UI", 9)
    $btn.Tag = @{ NormalY = $Y; IsAnimating = $false }
    
    $hoverColor = [Drawing.Color]::FromArgb(70,70,70)
    $normalColor = [Drawing.Color]::FromArgb(50,50,50)
    $activeColor = [Drawing.Color]::FromArgb(76, 110, 45)
    
    $btn.Add_MouseEnter({
        if (-not $this.Tag.IsAnimating) {
            $this.BackColor = $hoverColor
        }
    })
    
    $btn.Add_MouseLeave({
        if (-not $this.Tag.IsAnimating) {
            $this.BackColor = $normalColor
        }
    })
    
    $btn.Add_Click({
        $this.Tag.IsAnimating = $true
        $this.BackColor = $activeColor
        $this.Size = New-Object Drawing.Size(260, 80)
        $this.Location = New-Object Drawing.Point(-30, $this.Tag.NormalY - 17)
        $this.Font = New-Object Drawing.Font("Segoe UI", 12, "Bold")
        $form.Refresh()
        
        Start-Sleep -Milliseconds 100
        
        & $ClickAction
        
        Start-Sleep -Milliseconds 100
        
        $this.BackColor = $normalColor
        $this.Size = New-Object Drawing.Size(180, 45)
        $this.Location = New-Object Drawing.Point(10, $this.Tag.NormalY)
        $this.Font = New-Object Drawing.Font("Segoe UI", 9)
        $this.Tag.IsAnimating = $false
        $form.Refresh()
    })
    
    return $btn
}

function Make-QuitBtn {
    param([int]$Y)
    
    $btn = New-Object Windows.Forms.Button
    $btn.Text = "QUIT"
    $btn.Size = New-Object Drawing.Size(180, 45)
    $btn.Location = New-Object Drawing.Point(10, $Y)
    $btn.BackColor = [Drawing.Color]::FromArgb(139, 0, 0)
    $btn.ForeColor = "White"
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor = "Hand"
    $btn.Font = New-Object Drawing.Font("Segoe UI", 9)
    
    $btn.Add_Click({ $form.Close() })
    return $btn
}

# =========================
# GAME PAGE
# =========================
function Show-GamePage {
    param([string]$GameName, [string]$GameExe, [string]$GameCode)
    
    $contentArea.Controls.Clear()
    
    $state = Get-ContentState
    $installed = if ($GameCode -eq "RA") { $state.RA }
                elseif ($GameCode -eq "TD") { $state.TD }
                else { $state.D2K }
    
    $title = New-Object Windows.Forms.Label
    $title.Text = $GameName
    $title.Size = New-Object Drawing.Size(800, 70)
    $title.Location = New-Object Drawing.Point(40, 30)
    $title.ForeColor = [Drawing.Color]::FromArgb(153, 204, 0)
    $title.Font = New-Object Drawing.Font("Segoe UI", 36, "Bold")
    $contentArea.Controls.Add($title)
    
    $status = New-Object Windows.Forms.Label
    $status.Size = New-Object Drawing.Size(400, 35)
    $status.Location = New-Object Drawing.Point(40, 110)
    $status.Font = New-Object Drawing.Font("Segoe UI", 12)
    
    if ($installed) {
        $status.Text = "✓ Game installed and ready"
        $status.ForeColor = [Drawing.Color]::LimeGreen
    } else {
        $status.Text = "✗ Game not installed"
        $status.ForeColor = [Drawing.Color]::OrangeRed
    }
    
    $contentArea.Controls.Add($status)
    
    if ($installed) {
        # PLAY BUTTON
        $playBtn = New-Object Windows.Forms.Button
        $playBtn.Text = "PLAY"
        $playBtn.Size = New-Object Drawing.Size(280, 70)
        $playBtn.Location = New-Object Drawing.Point(40, 200)
        $playBtn.BackColor = [Drawing.Color]::FromArgb(76, 110, 45)
        $playBtn.ForeColor = "White"
        $playBtn.FlatStyle = "Flat"
        $playBtn.FlatAppearance.BorderSize = 0
        $playBtn.Font = New-Object Drawing.Font("Segoe UI", 14, "Bold")
        $playBtn.Cursor = "Hand"
        $playBtn.Tag = @{ IsAnimating = $false }
        
        $playBtn.Add_Click({
            if (-not $this.Tag.IsAnimating) {
                $this.Tag.IsAnimating = $true
                $this.BackColor = [Drawing.Color]::FromArgb(100, 150, 60)
                $this.Size = New-Object Drawing.Size(380, 100)
                $this.Location = New-Object Drawing.Point(-10, 165)
                $this.Font = New-Object Drawing.Font("Segoe UI", 18, "Bold")
                $form.Refresh()
                
                Launch $GameExe "UserData"
                
                Start-Sleep -Milliseconds 500
                
                $this.BackColor = [Drawing.Color]::FromArgb(76, 110, 45)
                $this.Size = New-Object Drawing.Size(280, 70)
                $this.Location = New-Object Drawing.Point(40, 200)
                $this.Font = New-Object Drawing.Font("Segoe UI", 14, "Bold")
                $this.Tag.IsAnimating = $false
                $form.Refresh()
            }
        })
        
        $contentArea.Controls.Add($playBtn)
        
        # PLAY PORTABLE BUTTON
        $portableBtn = New-Object Windows.Forms.Button
        $portableBtn.Text = "PLAY PORTABLE"
        $portableBtn.Size = New-Object Drawing.Size(280, 70)
        $portableBtn.Location = New-Object Drawing.Point(40, 310)
        $portableBtn.BackColor = [Drawing.Color]::FromArgb(76, 110, 45)
        $portableBtn.ForeColor = "White"
        $portableBtn.FlatStyle = "Flat"
        $portableBtn.FlatAppearance.BorderSize = 0
        $portableBtn.Font = New-Object Drawing.Font("Segoe UI", 14, "Bold")
        $portableBtn.Cursor = "Hand"
        $portableBtn.Tag = @{ IsAnimating = $false }
        
        $portableBtn.Add_Click({
            if (-not $this.Tag.IsAnimating) {
                $this.Tag.IsAnimating = $true
                $this.BackColor = [Drawing.Color]::FromArgb(100, 150, 60)
                $this.Size = New-Object Drawing.Size(380, 100)
                $this.Location = New-Object Drawing.Point(-10, 275)
                $this.Font = New-Object Drawing.Font("Segoe UI", 18, "Bold")
                $form.Refresh()
                
                Launch $GameExe "Portable"
                
                Start-Sleep -Milliseconds 500
                
                $this.BackColor = [Drawing.Color]::FromArgb(76, 110, 45)
                $this.Size = New-Object Drawing.Size(280, 70)
                $this.Location = New-Object Drawing.Point(40, 310)
                $this.Font = New-Object Drawing.Font("Segoe UI", 14, "Bold")
                $this.Tag.IsAnimating = $false
                $form.Refresh()
            }
        })
        
        $contentArea.Controls.Add($portableBtn)
        
        $info = New-Object Windows.Forms.Label
        $info.Text = "PLAY: Save to zUserData (standard mode)`nPLAY PORTABLE: Save to zData (isolated sandbox)"
        $info.Size = New-Object Drawing.Size(700, 100)
        $info.Location = New-Object Drawing.Point(40, 420)
        $info.ForeColor = [Drawing.Color]::Gray
        $info.Font = New-Object Drawing.Font("Segoe UI", 10)
        $info.AutoSize = $false
        $contentArea.Controls.Add($info)
        
    } else {
        $installBtn = New-Object Windows.Forms.Button
        $installBtn.Text = "INSTALL GAME"
        $installBtn.Size = New-Object Drawing.Size(280, 80)
        $installBtn.Location = New-Object Drawing.Point(40, 200)
        $installBtn.BackColor = [Drawing.Color]::FromArgb(76, 110, 45)
        $installBtn.ForeColor = "White"
        $installBtn.FlatStyle = "Flat"
        $installBtn.FlatAppearance.BorderSize = 0
        $installBtn.Font = New-Object Drawing.Font("Segoe UI", 13, "Bold")
        $installBtn.Cursor = "Hand"
        $installBtn.Tag = @{ IsAnimating = $false }
        
        $installBtn.Add_Click({
            if (-not $this.Tag.IsAnimating) {
                $this.Tag.IsAnimating = $true
                $this.BackColor = [Drawing.Color]::FromArgb(100, 150, 60)
                $this.Size = New-Object Drawing.Size(380, 120)
                $this.Location = New-Object Drawing.Point(-10, 160)
                $this.Font = New-Object Drawing.Font("Segoe UI", 16, "Bold")
                $form.Refresh()
                
                Download-OpenRA
                Show-GamePage $GameName $GameExe $GameCode
                
                $this.Tag.IsAnimating = $false
            }
        })
        
        $contentArea.Controls.Add($installBtn)
    }
}

# =========================
# CREATE SIDEBAR BUTTONS
# =========================
$sidebar.Controls.Add((Make-SidebarBtn "Red Alert" 15 { Show-GamePage "Red Alert" "RedAlert.exe" "RA" }))
$sidebar.Controls.Add((Make-SidebarBtn "Tiberian Dawn" 70 { Show-GamePage "Tiberian Dawn" "TiberianDawn.exe" "TD" }))
$sidebar.Controls.Add((Make-SidebarBtn "Dune 2000" 125 { Show-GamePage "Dune 2000" "Dune2000.exe" "D2K" }))

$sidebar.Controls.Add((Make-SidebarBtn "Download/Update" 200 {
    Update-ProgressBar 0 "Preparing download..."
    Start-Sleep -Milliseconds 500
    Download-OpenRA
}))

$sidebar.Controls.Add((Make-SidebarBtn "Smart Repair" 255 {
    Update-ProgressBar 0 "Starting repair..."
    Start-Sleep -Milliseconds 500
    Smart-Repair
}))

$sidebar.Controls.Add((Make-SidebarBtn "Check Status" 310 {
    $state = Get-ContentState
    $msg = "RED ALERT: $(if ($state.RA) { 'YES' } else { 'NO' })`nTIBERIAN DAWN: $(if ($state.TD) { 'YES' } else { 'NO' })`nDUNE 2000: $(if ($state.D2K) { 'YES' } else { 'NO' })"
    [System.Windows.Forms.MessageBox]::Show($msg, "Installation Status", 0, 64) | Out-Null
}))

$sidebar.Controls.Add((Make-QuitBtn 495))

# =========================
# STARTUP
# =========================
$form.Add_Load({
    Show-GamePage "Red Alert" "RedAlert.exe" "RA"
})

$form.ShowDialog()
