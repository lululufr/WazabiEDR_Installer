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
        Height="640" Width="900"
        WindowStartupLocation="CenterScreen"
        Background="#0b0e07"
        Foreground="#f1f3ea"
        FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="CardBorder" TargetType="Border">
            <Setter Property="Background" Value="#14180e"/>
            <Setter Property="BorderBrush" Value="#2c331f"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="8"/>
        </Style>
    </Window.Resources>
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Hero header -->
        <Grid Grid.Row="0" Margin="0,0,0,18">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Width="56" Height="56" CornerRadius="12"
                    Background="#1d2213" BorderBrush="#2c331f" BorderThickness="1"
                    Margin="0,0,16,0">
                <Canvas Width="40" Height="40" HorizontalAlignment="Center" VerticalAlignment="Center">
                    <!-- Symbole W : 3 traits clairs + 1 trait accent -->
                    <Polyline Points="6,12 14,30 20,18 26,30" Stroke="#f1f3ea"
                              StrokeThickness="4" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Polyline Points="26,30 34,12" Stroke="#84bb38"
                              StrokeThickness="4" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                </Canvas>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="WAZABI" FontSize="22" FontWeight="Bold" Foreground="#f1f3ea"/>
                    <TextBlock Text="." FontSize="22" FontWeight="Bold" Foreground="#84bb38"/>
                    <Border Background="#1f2c12" CornerRadius="10" Padding="8,2" Margin="12,4,0,0">
                        <TextBlock Text="Installation en cours" FontSize="11" Foreground="#84bb38"/>
                    </Border>
                </StackPanel>
                <TextBlock Name="StatusText"
                           Text="Reprise apres redemarrage, deploiement du driver et de l agent..."
                           FontSize="13" Foreground="#9aa188" Margin="0,4,0,0"/>
            </StackPanel>
        </Grid>

        <ProgressBar Grid.Row="1" Name="Progress" Height="4" IsIndeterminate="True"
                     Background="#1d2213" Foreground="#84bb38" BorderThickness="0"
                     Margin="0,0,0,18"/>

        <!-- Cartes services -->
        <Grid Grid.Row="2" Margin="0,0,0,18">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Style="{StaticResource CardBorder}"
                    Padding="14" Margin="0,0,6,0">
                <StackPanel>
                    <TextBlock Text="Driver kernel" FontSize="11" Foreground="#9aa188"/>
                    <TextBlock Name="DriverStatus" Text="Non installe"
                               FontSize="18" FontWeight="Bold" Foreground="#f05252" Margin="0,6,0,0"/>
                </StackPanel>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource CardBorder}"
                    Padding="14" Margin="6,0,0,0">
                <StackPanel>
                    <TextBlock Text="Service agent" FontSize="11" Foreground="#9aa188"/>
                    <TextBlock Name="AgentStatus" Text="Non installe"
                               FontSize="18" FontWeight="Bold" Foreground="#f05252" Margin="0,6,0,0"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- Log tail -->
        <Border Grid.Row="3" Style="{StaticResource CardBorder}" Background="#0b0e07">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Background="#14180e" BorderBrush="#2c331f"
                        BorderThickness="0,0,0,1" CornerRadius="8,8,0,0" Padding="12,8">
                    <TextBlock Text="install.log" FontFamily="Consolas" FontSize="11"
                               Foreground="#9aa188"/>
                </Border>
                <TextBox Grid.Row="1" Name="LogBox" Background="Transparent" Foreground="#cbd5b0"
                         FontFamily="Consolas" FontSize="11" IsReadOnly="True"
                         BorderThickness="0" Padding="12" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
            </Grid>
        </Border>

        <!-- Footer -->
        <Grid Grid.Row="4" Margin="0,18,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Name="HintText"
                       Text="Si l agent n apparait pas dans la console sous 1 min, cherche les lignes [WazabiEDR] error dans le log."
                       FontSize="11" Foreground="#9aa188" VerticalAlignment="Center" TextWrapping="Wrap"
                       Margin="0,0,12,0"/>
            <Button Grid.Column="1" Name="CloseBtn" Content="Fermer"
                    Width="110" Height="34" IsEnabled="False"
                    Background="#1d2213" Foreground="#f1f3ea"
                    BorderBrush="#2c331f" BorderThickness="1" Padding="0"
                    FontWeight="SemiBold"/>
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

function Get-StatusLabel {
    param([string]$RawStatus)
    switch ($RawStatus) {
        'Running'         { return 'En cours' }
        'Stopped'         { return 'Arrete' }
        'StartPending'    { return 'Demarrage...' }
        'StopPending'     { return 'Arret...' }
        'Paused'          { return 'En pause' }
        default           { return $RawStatus }
    }
}

function Update-ServiceStatus {
    # Palette alignee sur frontend/src/index.css :
    # accent = #84bb38, warn = #f59e0b, danger = #f05252.
    $drvSvc = Get-Service -Name $DriverService -ErrorAction SilentlyContinue
    if ($drvSvc) {
        $driverStatus.Text = Get-StatusLabel $drvSvc.Status.ToString()
        if ($drvSvc.Status -eq 'Running') {
            $driverStatus.Foreground = '#84bb38'
        } else {
            $driverStatus.Foreground = '#f59e0b'
        }
    } else {
        $driverStatus.Text = "Non installe"
        $driverStatus.Foreground = '#f05252'
    }

    $agtSvc = Get-Service -Name $AgentService -ErrorAction SilentlyContinue
    if ($agtSvc) {
        $agentStatus.Text = Get-StatusLabel $agtSvc.Status.ToString()
        if ($agtSvc.Status -eq 'Running') {
            $agentStatus.Foreground = '#84bb38'
            $script:installComplete = $true
        } else {
            $agentStatus.Foreground = '#f59e0b'
        }
    } else {
        $agentStatus.Text = "Non installe"
        $agentStatus.Foreground = '#f05252'
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
        $statusText.Text = "Installation terminee. L agent s enrole aupres du serveur."
        $hintText.Text   = "L endpoint apparaitra dans la console sous ~30 secondes."
        $progress.IsIndeterminate = $false
        $progress.Value = 100
        $progress.Foreground = '#84bb38'
        $closeBtn.IsEnabled = $true
        # Self-clean : retire la task pour ne plus se relancer aux
        # prochains logons.
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $timer.Stop()
    }
    elseif ($script:installError) {
        $statusText.Text = "L installation a rencontre des erreurs. Voir le log ci-dessus et l event log kernel-PnP."
        $hintText.Text   = "Lance 'sc.exe query WazabiEDR_Driver' dans un PowerShell admin pour voir l etat du driver."
        $progress.IsIndeterminate = $false
        $progress.Value = 100
        $progress.Foreground = '#f05252'
        $closeBtn.IsEnabled = $true
        # On garde la task : si l operateur reboot ou retente,
        # la UI s affichera a nouveau.
    }
})
$timer.Start()

Update-LogTail
Update-ServiceStatus

[void]$window.ShowDialog()
