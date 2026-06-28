<#
.SYNOPSIS
    UI WPF qui s affiche au premier logon utilisateur apres le reboot,
    tail le install.log et montre le statut des services en temps reel.

.DESCRIPTION
    Lancee par la scheduled task WazabiEDR-Resume-UI (AtLogOn) registree
    par install-all.ps1 quand un reboot est requis. La task SYSTEM
    AtStartup continue de driver l install en parallele ; cette UI est
    purement informationnelle pour l operateur.

    - tail %ProgramData%\WazabiEDR\install.log toutes les 1s
    - watch sc.exe query WazabiEDR_Driver / WazabiEDR_Agent
    - quand Agent service running : bascule en mode "complete"
      (progress vert) et self-delete la scheduled task
    - si erreur detectee dans le log : bascule en mode "error"
      (progress rouge) mais garde la task au cas ou l operateur
      relance manuellement

.NOTE
    Pur ASCII pour eviter ParserError sur PS 5.1 ANSI default.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$ConfigDir      = Join-Path $env:ProgramData "WazabiEDR"
$LogPath        = Join-Path $ConfigDir "install.log"
$ResumeTaskName = "WazabiEDR-Resume-UI"
$AgentService   = "WazabiEDR_Agent"
$DriverService  = "WazabiEDR_Driver"

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WazabiEDR Installation"
        Height="600" Width="850"
        WindowStartupLocation="CenterScreen"
        Background="#0c0e13"
        Foreground="#e0e0e0">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,15">
            <TextBlock Text="WazabiEDR" FontSize="26" FontWeight="Bold" Foreground="#84cc16"/>
            <TextBlock Name="StatusText"
                       Text="Installation in progress after reboot, please wait..."
                       FontSize="13" Foreground="#94a3b8" Margin="0,5,0,0"/>
        </StackPanel>
        <ProgressBar Grid.Row="1" Name="Progress" Height="6" IsIndeterminate="True"
                     Background="#1f2230" Foreground="#84cc16" Margin="0,0,0,15"/>
        <Grid Grid.Row="2" Margin="0,0,0,15">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#1a1d28" BorderBrush="#1f2230"
                    BorderThickness="1" Padding="12" Margin="0,0,5,0" CornerRadius="4">
                <StackPanel>
                    <TextBlock Text="Driver Service (kernel)" FontSize="11" Foreground="#94a3b8"/>
                    <TextBlock Name="DriverStatus" Text="Not installed"
                               FontSize="16" FontWeight="Bold" Foreground="#ef4444" Margin="0,4,0,0"/>
                </StackPanel>
            </Border>
            <Border Grid.Column="1" Background="#1a1d28" BorderBrush="#1f2230"
                    BorderThickness="1" Padding="12" Margin="5,0,0,0" CornerRadius="4">
                <StackPanel>
                    <TextBlock Text="Agent Service" FontSize="11" Foreground="#94a3b8"/>
                    <TextBlock Name="AgentStatus" Text="Not installed"
                               FontSize="16" FontWeight="Bold" Foreground="#ef4444" Margin="0,4,0,0"/>
                </StackPanel>
            </Border>
        </Grid>
        <Border Grid.Row="3" Background="#0a0c10" BorderBrush="#1f2230"
                BorderThickness="1" CornerRadius="4">
            <TextBox Name="LogBox" Background="Transparent" Foreground="#cbd5e1"
                     FontFamily="Consolas" FontSize="11" IsReadOnly="True"
                     BorderThickness="0" Padding="10" TextWrapping="Wrap"
                     VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
        </Border>
        <Grid Grid.Row="4" Margin="0,15,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Name="HintText"
                       Text="If the agent does not appear in the console within 1 minute, check the log for [WazabiEDR] error lines."
                       FontSize="11" Foreground="#64748b" VerticalAlignment="Center"/>
            <Button Grid.Column="1" Name="CloseBtn" Content="Close"
                    Width="100" Height="32" IsEnabled="False"
                    Background="#1f2230" Foreground="#e0e0e0"
                    BorderBrush="#1f2230" BorderThickness="1" Padding="0"/>
        </Grid>
    </Grid>
</Window>
'@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$statusText   = $window.FindName("StatusText")
$progress     = $window.FindName("Progress")
$driverStatus = $window.FindName("DriverStatus")
$agentStatus  = $window.FindName("AgentStatus")
$logBox       = $window.FindName("LogBox")
$closeBtn     = $window.FindName("CloseBtn")
$hintText     = $window.FindName("HintText")

$closeBtn.Add_Click({ $window.Close() })

$script:lastLogPos      = 0
$script:installComplete = $false
$script:installError    = $false

function Update-ServiceStatus {
    $drvSvc = Get-Service -Name $DriverService -ErrorAction SilentlyContinue
    if ($drvSvc) {
        $driverStatus.Text = $drvSvc.Status.ToString()
        if ($drvSvc.Status -eq 'Running') {
            $driverStatus.Foreground = '#22c55e'
        } else {
            $driverStatus.Foreground = '#fbbf24'
        }
    } else {
        $driverStatus.Text = "Not installed"
        $driverStatus.Foreground = '#ef4444'
    }

    $agtSvc = Get-Service -Name $AgentService -ErrorAction SilentlyContinue
    if ($agtSvc) {
        $agentStatus.Text = $agtSvc.Status.ToString()
        if ($agtSvc.Status -eq 'Running') {
            $agentStatus.Foreground = '#22c55e'
            $script:installComplete = $true
        } else {
            $agentStatus.Foreground = '#fbbf24'
        }
    } else {
        $agentStatus.Text = "Not installed"
        $agentStatus.Foreground = '#ef4444'
    }
}

function Update-LogTail {
    if (-not (Test-Path $LogPath)) { return }
    try {
        $content = Get-Content $LogPath -Raw -ErrorAction SilentlyContinue
    } catch {
        return
    }
    if ($null -eq $content -or $content.Length -le $script:lastLogPos) {
        return
    }
    $newText = $content.Substring($script:lastLogPos)
    $logBox.AppendText($newText)
    $script:lastLogPos = $content.Length
    $logBox.CaretIndex = $logBox.Text.Length
    $logBox.ScrollToEnd()

    if ($newText -match '\[install-all\] install complete') {
        $script:installComplete = $true
    }
    # Detection d erreur prudente : ignore les soft-fail (callbacks
    # qui echouent intentionnellement) et les messages info.
    if ($newText -match 'exit code [1-9]') {
        if ($newText -notmatch 'soft-fail') {
            $script:installError = $true
        }
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    Update-LogTail
    Update-ServiceStatus

    if ($script:installComplete) {
        $statusText.Text = "Installation complete. The agent is enrolling with the server."
        $hintText.Text   = "The endpoint should appear in the console within ~30 seconds."
        $progress.IsIndeterminate = $false
        $progress.Value = 100
        $progress.Foreground = '#22c55e'
        $closeBtn.IsEnabled = $true
        # Self-clean : retire la task pour ne plus se relancer aux
        # prochains logons.
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $timer.Stop()
    }
    elseif ($script:installError) {
        $statusText.Text = "Installation encountered errors. Check the log above and the kernel-PnP event log."
        $hintText.Text   = "Run 'sc.exe query WazabiEDR_Driver' in an elevated PowerShell to see the driver state."
        $progress.IsIndeterminate = $false
        $progress.Value = 100
        $progress.Foreground = '#ef4444'
        $closeBtn.IsEnabled = $true
        # On garde la task : si l operateur reboot ou retente,
        # la UI s affichera a nouveau.
    }
})
$timer.Start()

Update-LogTail
Update-ServiceStatus

[void]$window.ShowDialog()
