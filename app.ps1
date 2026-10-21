# =====================================================================
#  R5R Mod Manager 3.2 - Prednoxx
#  R5Reloaded mod system:
#    <game>\mods\<ModFolder>\mod.vdf   mod info
#    <game>\mods\mods.vdf               "ModList" { "<id>" "1|0" }
#  Mods missing from mods.vdf load enabled by default.
#  Mascot: Lumi-tan, sprite by blackbunney (itch.io).
# =====================================================================

$ErrorActionPreference = 'Stop'
$AppName    = 'R5R Mod Manager'
$AppVersion = '3.2'
$SettingsDir = if ($env:R5MM_SETTINGS_DIR) { $env:R5MM_SETTINGS_DIR } else { Join-Path $env:APPDATA 'R5RModManager' }
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$LogFile      = Join-Path $SettingsDir 'error.log'
$AppDir = $null
if ($env:R5MM_SELF) { $AppDir = Split-Path -Parent $env:R5MM_SELF } elseif ($PSScriptRoot) { $AppDir = $PSScriptRoot } else { $AppDir = (Get-Location).Path }
$AssetDir = Join-Path $AppDir 'assets'

$TraceFile = Join-Path $SettingsDir 'startup-trace.log'
[void][IO.Directory]::CreateDirectory($SettingsDir)
[IO.File]::WriteAllText($TraceFile, '')
$TraceClock = [Diagnostics.Stopwatch]::StartNew()
function Trace([string]$Text) {
    if (-not $TraceFile) { return }
    try { Add-Content -LiteralPath $TraceFile -Value ('{0,7} ms  {1}' -f $TraceClock.ElapsedMilliseconds, $Text) } catch {}
}
Trace '--- start'

function Write-Log([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('[' + (Get-Date -Format s) + '] ' + $Text)
    } catch {}
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName Microsoft.VisualBasic

    if (-not ('R5MM.ModItem' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace R5MM {
    public class CatalogCard : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        public string Key { get; set; }
        public string Name { get; set; }
        public string Author { get; set; }
        public string AuthorLabel { get; set; }
        public string Description { get; set; }
        public string Source { get; set; }
        public string Build { get; set; }
        public string Category { get; set; }
        public string Status { get; set; }
        public string Stats { get; set; }
        public bool CanInstall { get; set; }
        public object Entry { get; set; }
        private string previewPath;
        public string PreviewPath {
            get { return previewPath; }
            set { previewPath = value; var handler = PropertyChanged; if (handler != null) handler(this, new PropertyChangedEventArgs("PreviewPath")); }
        }
        public override string ToString() { return Name; }
    }
    public class ModItem : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        void Notify(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }

        public string Folder { get; set; }
        public string FolderName { get; set; }
        public string VdfPath { get; set; }
        public string Name { get; set; }
        public string Id { get; set; }
        public string Version { get; set; }
        public string Author { get; set; }
        public string Description { get; set; }

        string _problem, _problemTitle;
        public string Problem { get { return _problem; } set { _problem = value; Notify("Problem"); Notify("HasProblem"); Notify("Status"); } }
        public string ProblemTitle { get { return _problemTitle; } set { _problemTitle = value; Notify("ProblemTitle"); } }

        bool _enabled;
        public bool Enabled { get { return _enabled; } set { if (_enabled != value) { _enabled = value; Notify("Enabled"); Notify("Status"); } } }

        string _depProblem, _depTitle;
        public string DepProblem { get { return _depProblem; } set { _depProblem = value; Notify("DepProblem"); Notify("HasProblem"); Notify("Status"); } }
        public string DepTitle { get { return _depTitle; } set { _depTitle = value; Notify("DepTitle"); } }

        bool _required;
        public bool IsRequired { get { return _required; } set { _required = value; Notify("IsRequired"); } }
        public string[] ConVars { get; set; }
        public string[] Deps { get; set; }
        public string[] Dependencies { get; set; }

        public bool CanToggle  { get { return !string.IsNullOrEmpty(Id); } }
        public bool HasProblem { get { return !string.IsNullOrEmpty(_problem) || !string.IsNullOrEmpty(_depProblem); } }
        public string Status   { get { return HasProblem ? "Error" : (_enabled ? "Active" : "Inactive"); } }
        public string DisplayName { get { return string.IsNullOrEmpty(Name) ? FolderName : Name; } }
        public string Meta {
            get {
                string s = "";
                if (!string.IsNullOrEmpty(Version)) s = "v" + Version;
                if (!string.IsNullOrEmpty(Author)) s += (s.Length > 0 ? "  \u00B7  " : "") + Author;
                if (s.Length == 0) s = "mods\\" + FolderName;
                return s;
            }
        }
    }

    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogCo { }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
    }

    public static class FolderPicker {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SHCreateItemFromParsingName([MarshalAs(UnmanagedType.LPWStr)] string pszPath, IntPtr pbc, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

        public static string Pick(IntPtr owner, string title, string initial) {
            IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogCo();
            try {
                uint opts; dlg.GetOptions(out opts);
                dlg.SetOptions(opts | 0x20 | 0x40);
                if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);
                if (!string.IsNullOrEmpty(initial) && System.IO.Directory.Exists(initial)) {
                    IShellItem folder; Guid g = typeof(IShellItem).GUID;
                    if (SHCreateItemFromParsingName(initial, IntPtr.Zero, ref g, out folder) == 0) dlg.SetFolder(folder);
                }
                if (dlg.Show(owner) != 0) return "";
                IShellItem result; dlg.GetResult(out result);
                string path; result.GetDisplayName(0x80058000, out path);
                return path ?? "";
            } finally { Marshal.ReleaseComObject(dlg); }
        }
    }
}
'@
    }
} catch {
    Write-Log ('Startup: ' + $_.Exception.ToString())
    [void][System.Windows.MessageBox]::Show("R5R Mod Manager failed to start.`r`n`r`n" + $_.Exception.Message, $AppName)
    return
}

# ================================================================ state
$script:GameDir       = $null
$script:ModsDir       = $null
$script:ModListPath   = $null
$script:ModState      = [ordered]@{}
$script:ModListRoot   = 'ModList'
$script:Mods          = New-Object System.Collections.Generic.List[R5MM.ModItem]
$script:Installs      = New-Object System.Collections.Generic.List[string]
$script:Items         = New-Object System.Collections.ObjectModel.ObservableCollection[R5MM.ModItem]
$script:Presets       = [ordered]@{}
$script:ActivePreset  = ''
$script:Theme         = 'aero_day'
$script:Loading       = $false
$script:Started       = $false
$script:WasRunning    = $false
$script:DlgResult     = $false
$script:DlgFrame      = $null
$script:PendingDrop   = $null
$script:ScanPS        = $null
$script:ScanHandle    = $null
$script:ConVarCache   = @{}
$script:FixEnable     = New-Object System.Collections.Generic.List[object]
$script:FixMissing    = New-Object System.Collections.Generic.List[object]
$script:DlQueue       = New-Object System.Collections.Queue
$script:DlJob         = $null
$script:DetSourceUrl  = $null

# Stock mods shipped with R5Reloaded (official scripts repo: defaults/mods/<Folder>).
$StockRepo = 'Mauler125/r5_flowstate'
$Catalog = @(
    @{ Id = 'Flowstate';   Folder = 'Flowstate';   Name = 'R5R Mod: Flowstate'; Required = $true  }
    @{ Id = 'SDK.Core';    Folder = 'sdk_core';    Name = 'SDK core mod';       Required = $true  }
    @{ Id = 'Karma';       Folder = 'Karma';       Name = 'Karma Assets';       Required = $false }
    @{ Id = 'kralstuff';   Folder = 'Kralstuff';   Name = 'KralStuff';          Required = $false }
    @{ Id = 'movementgym'; Folder = 'movementgym'; Name = 'movementgym';        Required = $false }
)

# ================================================================ themes
# Light = white glass, dark text.  Dark = tinted glass, light text.
$Themes = [ordered]@{
    obsidian   = @{ Name = 'Obsidian'; Dark = $true; Tint = '171614'; Tint2 = '11110F'; Flat = $true; Obsidian = $true }
    aero_day   = @{ Name = 'Aero Day';   Dark = $false; Tint = 'FFFFFF'; Tint2 = 'E9F4FC'; Flat = $false }
    aero_night = @{ Name = 'Aero Night'; Dark = $true;  Tint = '1E1238'; Tint2 = '140C28'; Flat = $false }
    aqua       = @{ Name = 'Aqua';       Dark = $false; Tint = 'FFFFFF'; Tint2 = 'E4F7F8'; Flat = $false }
    aurora     = @{ Name = 'Aurora';     Dark = $true;  Tint = '0D2A22'; Tint2 = '081C17'; Flat = $false }
    eco        = @{ Name = 'Eco';        Dark = $false; Tint = 'FFFFFF'; Tint2 = 'EAF6E6'; Flat = $false }
    metro      = @{ Name = 'Metro';      Dark = $false; Tint = 'FFFFFF'; Tint2 = 'F4F8FB'; Flat = $true  }
    sunburst   = @{ Name = 'Sunburst';   Dark = $true;  Tint = '2B230A'; Tint2 = '1D1706'; Flat = $false }
    sweetheart = @{ Name = 'Sweetheart'; Dark = $true;  Tint = '3A1240'; Tint2 = '260A2B'; Flat = $false }
    win11      = @{ Name = 'Windows 11'; Dark = $false; Tint = 'FFFFFF'; Tint2 = 'FFFFFF'; Flat = $true; Win11 = $true }
}

# Windows 11 theme follows the system light/dark setting and accent color.
function Get-SystemDark {
    try { return ((Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { return $false }
}
function Get-SystemAccent {
    try {
        $abgr = [int64](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor -band 0xFFFFFFFF
        return @([int]($abgr -band 0xFF), [int](($abgr -shr 8) -band 0xFF), [int](($abgr -shr 16) -band 0xFF))
    } catch { return @(0, 120, 212) }
}
function Mix-Hex($Rgb, [int[]]$Target, [double]$Amount) {
    $o = ''
    for ($i = 0; $i -lt 3; $i++) { $o += ('{0:X2}' -f [int][Math]::Round($Rgb[$i] + ($Target[$i] - $Rgb[$i]) * $Amount)) }
    return $o
}

# ================================================================ UI definition
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="R5R Mod Manager" Width="1280" Height="780" MinWidth="1120" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBg}"
        FontFamily="{DynamicResource UiFont}" FontSize="13" Foreground="{DynamicResource Text}"
        AllowDrop="True" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">

  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="44" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <LinearGradientBrush x:Key="Gloss" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#80FFFFFF" Offset="0"/>
      <GradientStop Color="#26FFFFFF" Offset="0.5"/>
      <GradientStop Color="#00FFFFFF" Offset="0.51"/>
      <GradientStop Color="#00FFFFFF" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="PanelGloss" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#59FFFFFF" Offset="0"/>
      <GradientStop Color="#00FFFFFF" Offset="1"/>
    </LinearGradientBrush>
    <SolidColorBrush x:Key="Warn" Color="#E89A1C"/>
    <SolidColorBrush x:Key="WarnBg" Color="#2EE89A1C"/>
    <SolidColorBrush x:Key="Danger" Color="#D8333A"/>

    <!-- glass panel -->
    <ControlTemplate x:Key="Glass" TargetType="ContentControl">
      <Grid>
        <Border Background="{DynamicResource PanelEdge}" CornerRadius="{DynamicResource Radius}" Margin="-1">
          <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.28" Color="#000000"/></Border.Effect>
        </Border>
        <Border Background="{DynamicResource PanelBg}" BorderBrush="{DynamicResource PanelBorder}" BorderThickness="1" CornerRadius="{DynamicResource Radius}"/>
        <Border Height="46" VerticalAlignment="Top" Margin="1" CornerRadius="{DynamicResource Radius}"
                Background="{StaticResource PanelGloss}" Opacity="{DynamicResource GlossOpacity}" IsHitTestVisible="False"/>
        <ContentPresenter Margin="{TemplateBinding Padding}"/>
      </Grid>
    </ControlTemplate>

    <!-- glossy button -->
    <ControlTemplate x:Key="BtnT" TargetType="Button">
      <Grid>
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="1" CornerRadius="{DynamicResource RadiusSmall}"/>
        <Border x:Name="Gl" Margin="1" CornerRadius="{DynamicResource RadiusSmall}" Background="{StaticResource Gloss}"
                Opacity="{DynamicResource GlossOpacity}" IsHitTestVisible="False"/>
        <Border x:Name="Shade" Margin="1" CornerRadius="{DynamicResource RadiusSmall}" Background="#000000" Opacity="0" IsHitTestVisible="False"/>
        <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="Shade" Property="Opacity" Value="0.14"/><Setter TargetName="Gl" Property="Opacity" Value="0.4"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Template" Value="{StaticResource BtnT}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BtnBorder}"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource BtnHoverBg}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource BtnHoverBorder}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{DynamicResource AccentBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource AccentBorder}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource AccentBg}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource Text}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{DynamicResource DangerText}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#22D8333A"/>
          <Setter Property="BorderBrush" Value="{StaticResource Danger}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Width" Value="32"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <!-- caption buttons -->
    <Style x:Key="Cap" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="{DynamicResource TitleText}"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource TitleHover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CapClose" TargetType="Button" BasedOn="{StaticResource Cap}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#E0D8333A"/><Setter Property="Foreground" Value="White"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- title bar pill button (theme picker) -->
    <Style x:Key="TitlePill" TargetType="Button">
      <Setter Property="Height" Value="26"/>
      <Setter Property="Foreground" Value="{DynamicResource TitleText}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{DynamicResource PillBg}" BorderBrush="{DynamicResource PillBorder}" BorderThickness="1" CornerRadius="13" Padding="12,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource PillHover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- pill switch -->
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="42" Height="22" Background="Transparent">
              <Border x:Name="Track" CornerRadius="11" Background="{DynamicResource TrackOff}" BorderBrush="{DynamicResource TrackOffBorder}" BorderThickness="1"/>
              <Border x:Name="TrackGl" CornerRadius="10" Margin="1" Background="{StaticResource Gloss}" Opacity="{DynamicResource GlossOpacity}"/>
              <Ellipse x:Name="Knob" Width="16" Height="16" Margin="3,0" HorizontalAlignment="Left" Fill="White" Stroke="#668A9AAA" StrokeThickness="1">
                <Ellipse.Effect><DropShadowEffect BlurRadius="3" ShadowDepth="1" Opacity="0.3"/></Ellipse.Effect>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource AccentStrong}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{DynamicResource AccentBg}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource AccentBorder}"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Stroke" Value="#990A9C78"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
                <Setter TargetName="Track" Property="Background" Value="{DynamicResource TrackOff}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource TrackOffBorder}"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Center"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- slim scrollbar -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource TextFaint}" Opacity="0.55" CornerRadius="4" Margin="1,2"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- mod row -->
    <Style x:Key="ModRow" TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Row" Background="Transparent" BorderBrush="Transparent" BorderThickness="1"
                    CornerRadius="{DynamicResource RadiusSmall}" Height="54" Margin="6,1">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="66"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="104"/>
                </Grid.ColumnDefinitions>
                <CheckBox x:Name="Sw" Style="{StaticResource Toggle}" IsChecked="{Binding Enabled, Mode=TwoWay}"
                          IsEnabled="{Binding CanToggle}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <TextBlock x:Name="Lock" Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="{DynamicResource AccentStrong}"
                           HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" ToolTip="Required by R5Reloaded"/>
                <StackPanel x:Name="Txt" Grid.Column="1" VerticalAlignment="Center" Margin="0,0,10,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="{Binding DisplayName}" FontSize="14.5" FontWeight="SemiBold" Foreground="{DynamicResource Text}" TextTrimming="CharacterEllipsis"/>
                    <Border x:Name="ReqChip" CornerRadius="8" Padding="7,1" Margin="8,1,0,0" VerticalAlignment="Center" Visibility="Collapsed"
                            BorderBrush="{DynamicResource AccentStrong}" BorderThickness="1">
                      <TextBlock Text="Required" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource AccentStrong}"/>
                    </Border>
                  </StackPanel>
                  <TextBlock Text="{Binding Meta}" FontSize="12" Foreground="{DynamicResource TextDim}" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <Border x:Name="Tag" Grid.Column="2" Height="22" MinWidth="70" HorizontalAlignment="Center" CornerRadius="11"
                        Background="{DynamicResource TagOffBg}" Padding="10,0">
                  <TextBlock x:Name="TagText" Text="{Binding Status}" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource TagOffText}"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Row" Property="Background" Value="{DynamicResource RowHover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Row" Property="Background" Value="{DynamicResource RowSel}"/>
                <Setter TargetName="Row" Property="BorderBrush" Value="{DynamicResource RowSelBorder}"/>
              </Trigger>
              <DataTrigger Binding="{Binding Enabled}" Value="False"><Setter TargetName="Txt" Property="Opacity" Value="0.6"/></DataTrigger>
              <DataTrigger Binding="{Binding IsRequired}" Value="True">
                <Setter TargetName="Sw" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="Lock" Property="Visibility" Value="Visible"/>
                <Setter TargetName="ReqChip" Property="Visibility" Value="Visible"/>
              </DataTrigger>
              <DataTrigger Binding="{Binding Status}" Value="Active">
                <Setter TargetName="Tag" Property="Background" Value="{DynamicResource AccentBg}"/>
                <Setter TargetName="TagText" Property="Foreground" Value="{DynamicResource AccentText}"/>
              </DataTrigger>
              <DataTrigger Binding="{Binding Status}" Value="Error">
                <Setter TargetName="Tag" Property="Background" Value="{StaticResource Warn}"/>
                <Setter TargetName="TagText" Property="Foreground" Value="#3A2400"/>
              </DataTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- menus -->
    <Style x:Key="MenuS" TargetType="ContextMenu">
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="{DynamicResource MenuBg}" BorderBrush="{DynamicResource BtnBorder}" BorderThickness="1"
                    CornerRadius="{DynamicResource RadiusSmall}" Padding="4" MinWidth="220">
              <Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.3"/></Border.Effect>
              <ItemsPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MenuItemS" TargetType="MenuItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="{DynamicResource RadiusSmall}" Padding="10,7">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource RowSel}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource RowSelBorder}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MenuSep" TargetType="Separator">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Separator"><Border Height="1" Margin="6,4" Background="{DynamicResource Divider}"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="{DynamicResource TextFaint}"/>
    </Style>
    <Style x:Key="Heading" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <!-- store resources -->
  </Window.Resources>

  <Grid x:Name="Root">
    <!-- wallpaper -->
    <Image x:Name="Wallpaper" Stretch="UniformToFill" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    <Rectangle Fill="{DynamicResource WallShade}"/>

    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="44"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="220"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- title bar -->
      <Border x:Name="TitleShade" Grid.ColumnSpan="2" Height="64" VerticalAlignment="Top" IsHitTestVisible="False">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#40000000" Offset="0"/>
            <GradientStop Color="#00000000" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>
      <Border x:Name="TitleGloss" Grid.ColumnSpan="2">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#4DFFFFFF" Offset="0"/>
            <GradientStop Color="#14FFFFFF" Offset="0.5"/>
            <GradientStop Color="#00FFFFFF" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>
      <StackPanel Grid.ColumnSpan="2" Orientation="Horizontal" Margin="14,0,0,0" VerticalAlignment="Center">
        <Image x:Name="TitleIcon" Width="24" Height="24" Margin="0,0,10,0"/>
        <TextBlock x:Name="TitleLabel" Text="R5R Mod Manager" FontSize="15" Foreground="{DynamicResource TitleText}" VerticalAlignment="Center">
          <TextBlock.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="0" Opacity="0.7" Color="#000000"/></TextBlock.Effect>
        </TextBlock>

      </StackPanel>
      <StackPanel Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
        <Button x:Name="BtnGlobalLaunch" Style="{StaticResource TitlePill}" Content="Launch R5Reloaded" Margin="0,9,12,0"/>
        <Button x:Name="BtnTheme" Style="{StaticResource TitlePill}" Margin="0,9,10,0" VerticalAlignment="Top">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE790;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="ThemeName" Text="Aero Day" FontSize="12.5" VerticalAlignment="Center"/>
            <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="8" VerticalAlignment="Center" Margin="8,1,0,0"/>
          </StackPanel>
        </Button>
        <Button x:Name="BtnMin" Style="{StaticResource Cap}" Content="&#xE921;"/>
        <Button x:Name="BtnMax" Style="{StaticResource Cap}" Content="&#xE922;"/>
        <Button x:Name="BtnClose" Style="{StaticResource CapClose}" Content="&#xE8BB;"/>
      </StackPanel>

      <!-- mascot -->
      <Image x:Name="Mascot" Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Stretch="Uniform" VerticalAlignment="Bottom" HorizontalAlignment="Right"
             Width="320" Margin="0,0,-12,0" IsHitTestVisible="False" RenderOptions.BitmapScalingMode="HighQuality"/>

      <!-- content -->
      <Grid x:Name="LibraryView" Grid.Row="1" Grid.Column="1" Margin="18,18,20,14" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="12"/>
          <ColumnDefinition Width="330"/>
        </Grid.ColumnDefinitions>

        <!-- game folder bar -->
        <ContentControl Grid.ColumnSpan="3" Template="{StaticResource Glass}" Padding="16,0,10,0" Height="50" Margin="0,0,0,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="&#xE8B7;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="{DynamicResource AccentStrong}" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock Text="Game folder" Style="{StaticResource Heading}" FontSize="13.5"/>
            </StackPanel>
            <TextBlock x:Name="GamePath" Grid.Column="1" Text="Not set" FontSize="13" Foreground="{DynamicResource TextDim}"
                       VerticalAlignment="Center" Margin="14,0,12,0" TextTrimming="CharacterEllipsis"/>
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnChange" Style="{StaticResource Btn}" Height="30">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Change"/>
                  <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="8" Margin="8,1,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnRestore" Style="{StaticResource Btn}" Height="30">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE777;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <TextBlock Text="Restore"/>
                  <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="8" Margin="8,1,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnModsFolder" Style="{StaticResource Btn}" Height="30" Margin="0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <TextBlock Text="Mods folder"/>
                </StackPanel>
              </Button>
            </StackPanel>
          </Grid>
        </ContentControl>

        <!-- mod list panel -->
        <ContentControl Grid.Row="1" Grid.Column="0" Template="{StaticResource Glass}" Padding="0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- toolbar -->
            <WrapPanel Margin="12,12,12,0">
              <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                <Button x:Name="BtnInstallZip" Style="{StaticResource BtnAccent}">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE710;" FontFamily="Segoe MDL2 Assets" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Install .zip"/>
                  </StackPanel>
                </Button>
                <Button x:Name="BtnInstallDir" Style="{StaticResource Btn}" Content="Install folder"/>
                <Button x:Name="BtnEnableAll" Style="{StaticResource Btn}" Content="Enable all"/>
                <Button x:Name="BtnDisableAll" Style="{StaticResource Btn}" Content="Disable all"/>
                <Button x:Name="BtnRefresh" Style="{StaticResource IconBtn}" Content="&#xE72C;" ToolTip="Rescan (F5)"/>
              </StackPanel>
              <Grid DockPanel.Dock="Right" Width="190" Height="32">
                <Border Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource InputBorder}" BorderThickness="1" CornerRadius="{DynamicResource RadiusSmall}"/>
                <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{DynamicResource TextFaint}"
                           VerticalAlignment="Center" Margin="10,0,0,0" IsHitTestVisible="False"/>
                <TextBlock x:Name="SearchHint" Text="Search" FontSize="13" Foreground="{DynamicResource TextFaint}"
                           VerticalAlignment="Center" Margin="32,0,0,0" IsHitTestVisible="False"/>
                <TextBox x:Name="SearchBox" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource Text}"
                         CaretBrush="{DynamicResource Text}" SelectionBrush="{DynamicResource Accent}" FontSize="13"
                         VerticalContentAlignment="Center" Margin="28,0,6,0"/>
              </Grid>
            </WrapPanel>

            <!-- presets -->
            <Border Grid.Row="1" Margin="12,10,12,0" Background="{DynamicResource Inset}" CornerRadius="{DynamicResource RadiusSmall}" Padding="10,6">
              <DockPanel LastChildFill="False">
                <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center">
                  <TextBlock Text="&#xE8FD;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="{DynamicResource AccentStrong}" VerticalAlignment="Center" Margin="2,0,10,0"/>
                  <TextBlock Text="Preset" Style="{StaticResource Heading}" FontSize="13"/>
                  <Button x:Name="BtnPreset" Style="{StaticResource Btn}" Height="28" Margin="12,0,6,0" MinWidth="180" HorizontalContentAlignment="Stretch">
                    <DockPanel>
                      <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="8" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="10,1,0,0"/>
                      <TextBlock x:Name="PresetName" Text="None" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="220"/>
                    </DockPanel>
                  </Button>
                  <TextBlock x:Name="PresetModified" Text="Modified" FontSize="12" FontStyle="Italic" Foreground="{DynamicResource TextFaint}" VerticalAlignment="Center" Margin="2,0,0,0" Visibility="Collapsed"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" VerticalAlignment="Center">
                  <Button x:Name="BtnPresetSave" Style="{StaticResource Btn}" Height="28" Content="Save"/>
                  <Button x:Name="BtnPresetNew" Style="{StaticResource Btn}" Height="28" Content="Save as new"/>
                  <Button x:Name="BtnPresetDelete" Style="{StaticResource IconBtn}" Height="28" Width="28" Margin="0" Content="&#xE74D;" ToolTip="Delete preset"/>
                </StackPanel>
              </DockPanel>
            </Border>

            <!-- issues -->
            <Border x:Name="IssueBar" Grid.Row="2" Margin="12,10,12,0" Background="{StaticResource WarnBg}" BorderBrush="{StaticResource Warn}"
                    BorderThickness="1" CornerRadius="{DynamicResource RadiusSmall}" Padding="12,8" Visibility="Collapsed">
              <DockPanel>
                <Button x:Name="BtnFixIssues" DockPanel.Dock="Right" Style="{StaticResource BtnAccent}" Height="28" Margin="10,0,0,0" VerticalAlignment="Center">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE90F;" FontFamily="Segoe MDL2 Assets" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBlock x:Name="FixText" Text="Fix"/>
                  </StackPanel>
                </Button>
                <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="{StaticResource Warn}" VerticalAlignment="Top" Margin="0,2,10,0"/>
                <TextBlock x:Name="IssueText" FontSize="13" Foreground="{DynamicResource Text}" TextWrapping="Wrap" VerticalAlignment="Center" LineHeight="19"/>
              </DockPanel>
            </Border>

            <!-- list header -->
            <Grid Grid.Row="3" Margin="18,12,18,4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="104"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="On" Style="{StaticResource Label}" HorizontalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
                <TextBlock Text="Mod" Style="{StaticResource Label}"/>
                <TextBlock x:Name="CountText" Style="{StaticResource Label}" Margin="12,0,0,0" Text=""/>
              </StackPanel>
              <TextBlock Grid.Column="2" Text="Status" Style="{StaticResource Label}" HorizontalAlignment="Center"/>
            </Grid>
            <Border Grid.Row="3" Height="1" VerticalAlignment="Bottom" Margin="12,0" Background="{DynamicResource Divider}"/>

            <ListBox x:Name="ModList" Grid.Row="4" Background="Transparent" BorderThickness="0" Padding="0,4,0,8"
                     ItemContainerStyle="{StaticResource ModRow}" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     FocusVisualStyle="{x:Null}"/>
            <StackPanel x:Name="EmptyState" Grid.Row="4" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" IsHitTestVisible="False">
              <TextBlock x:Name="EmptyIcon" Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="34" Foreground="{DynamicResource TextFaint}" HorizontalAlignment="Center"/>
              <TextBlock x:Name="EmptyTitle" Text="No mods installed" FontFamily="Segoe UI Light" FontSize="22" Foreground="{DynamicResource TextDim}" HorizontalAlignment="Center" Margin="0,12,0,4"/>
              <TextBlock x:Name="EmptySub" Text="Drop a .zip or mod folder here" FontSize="13" Foreground="{DynamicResource TextFaint}" HorizontalAlignment="Center"/>
            </StackPanel>
          </Grid>
        </ContentControl>

        <!-- details panel -->
        <ContentControl Grid.Row="1" Grid.Column="2" Template="{StaticResource Glass}" Padding="20,18,20,18">
          <Grid>
            <TextBlock x:Name="DetEmpty" Text="No mod selected" FontFamily="Segoe UI Light" FontSize="18" Foreground="{DynamicResource TextFaint}"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <DockPanel x:Name="DetBody" Visibility="Collapsed">
              <StackPanel DockPanel.Dock="Top">
                <TextBlock x:Name="DetName" FontFamily="Segoe UI Light" FontSize="26" Foreground="{DynamicResource Text}" TextWrapping="Wrap" LineHeight="30" Margin="0,0,0,4"/>
                <StackPanel Orientation="Horizontal" Margin="0,4,0,14">
                  <Border x:Name="DetTag" CornerRadius="11" Height="22" Padding="10,0" Background="{DynamicResource AccentBg}">
                    <TextBlock x:Name="DetTagText" Text="Active" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource AccentText}" VerticalAlignment="Center"/>
                  </Border>
                </StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Border Background="{DynamicResource Inset}" CornerRadius="{DynamicResource RadiusSmall}" Padding="12,8">
                    <StackPanel>
                      <TextBlock Text="Version" Style="{StaticResource Label}"/>
                      <TextBlock x:Name="DetVersion" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Background="{DynamicResource Inset}" CornerRadius="{DynamicResource RadiusSmall}" Padding="12,8">
                    <StackPanel>
                      <TextBlock Text="Author" Style="{StaticResource Label}"/>
                      <TextBlock x:Name="DetAuthor" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                  </Border>
                </Grid>
                <TextBlock Text="Mod ID" Style="{StaticResource Label}" Margin="0,14,0,0"/>
                <TextBlock x:Name="DetId" FontSize="13" Foreground="{DynamicResource TextDim}" TextWrapping="Wrap" Margin="0,2,0,0"/>
                <TextBlock Text="Folder" Style="{StaticResource Label}" Margin="0,10,0,0"/>
                <TextBlock x:Name="DetFolder" FontSize="13" Foreground="{DynamicResource TextDim}" TextWrapping="Wrap" Margin="0,2,0,0"/>
                <Border x:Name="DetWarn" Background="{StaticResource WarnBg}" BorderBrush="{StaticResource Warn}" BorderThickness="1"
                        CornerRadius="{DynamicResource RadiusSmall}" Padding="12,9" Margin="0,14,0,0" Visibility="Collapsed">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{StaticResource Warn}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                      <TextBlock x:Name="DetWarnTitle" FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Text}"/>
                    </StackPanel>
                    <TextBlock x:Name="DetWarnText" FontSize="12.5" Foreground="{DynamicResource TextDim}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                  </StackPanel>
                </Border>
                <StackPanel x:Name="DetDepsWrap" Visibility="Collapsed">
                  <TextBlock Text="Requires" Style="{StaticResource Label}" Margin="0,10,0,0"/>
                  <TextBlock x:Name="DetDeps" FontSize="13" Foreground="{DynamicResource TextDim}" TextWrapping="Wrap" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel x:Name="DetSourceWrap" Visibility="Collapsed">
                  <TextBlock Text="Source" Style="{StaticResource Label}" Margin="0,10,0,0"/>
                  <TextBlock Margin="0,2,0,0"><Hyperlink x:Name="DetSource" Foreground="{DynamicResource AccentStrong}"><Run x:Name="DetSourceText" Text="GitHub"/></Hyperlink></TextBlock>
                </StackPanel>
                <TextBlock Text="Description" Style="{StaticResource Label}" Margin="0,14,0,4"/>
              </StackPanel>
              <Grid DockPanel.Dock="Bottom" Margin="0,12,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="BtnOpenMod" Style="{StaticResource Btn}" Margin="0,0,4,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBlock Text="Open folder"/>
                  </StackPanel>
                </Button>
                <Button x:Name="BtnRemove" Grid.Column="1" Style="{StaticResource BtnDanger}" Margin="4,0,0,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBlock Text="Uninstall"/>
                  </StackPanel>
                </Button>
              </Grid>
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <TextBlock x:Name="DetDesc" FontSize="13.5" Foreground="{DynamicResource Text}" TextWrapping="Wrap" LineHeight="20" Margin="0,0,8,0"/>
              </ScrollViewer>
            </DockPanel>
          </Grid>
        </ContentControl>

        <!-- bottom bar -->
        <ContentControl Grid.Row="2" Grid.ColumnSpan="3" Template="{StaticResource Glass}" Padding="16,0,8,0" Height="58" Margin="0,12,0,0">
          <Grid>
            <StackPanel VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="{DynamicResource TextFaint}" VerticalAlignment="Center" Margin="0,0,9,0"/>
                <TextBlock x:Name="StatusText" Text="Ready" FontSize="13" Foreground="{DynamicResource Text}"/>
                <Grid x:Name="DlWrap" Width="160" Height="6" Margin="14,1,0,0" VerticalAlignment="Center" Visibility="Collapsed">
                  <Border Background="{DynamicResource TrackOff}" CornerRadius="3"/>
                  <Border x:Name="DlFill" Background="{DynamicResource AccentBg}" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
                </Grid>
              </StackPanel>
              <TextBlock x:Name="FooterText" Text="v3.1  &#x00B7;  Prednoxx" FontSize="11" Foreground="{DynamicResource TextFaint}" Margin="17,2,0,0"/>
            </StackPanel>
            <Button x:Name="BtnLaunch" Style="{StaticResource BtnAccent}" HorizontalAlignment="Right" Height="42" Width="200" Margin="0">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="LaunchIcon" Text="&#xE768;" FontFamily="Segoe MDL2 Assets" FontSize="15" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock x:Name="LaunchText" Text="Launch" FontSize="17" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </Grid>
        </ContentControl>
      </Grid>
      <!-- sidebar -->
      <!-- store view -->
      <!-- utility view -->
    </Grid>

    <!-- drag overlay -->
    <Grid x:Name="DropLayer" Background="#66000000" Visibility="Collapsed" IsHitTestVisible="False">
      <ContentControl Template="{StaticResource Glass}" Width="460" Height="220" Padding="0">
        <Grid>
          <Rectangle Margin="12" RadiusX="6" RadiusY="6" Stroke="{DynamicResource AccentStrong}" StrokeThickness="2" StrokeDashArray="5 3"/>
          <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
            <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="38" Foreground="{DynamicResource AccentStrong}" HorizontalAlignment="Center"/>
            <TextBlock Text="Drop to install" FontFamily="Segoe UI Light" FontSize="28" Foreground="{DynamicResource Text}" HorizontalAlignment="Center" Margin="0,10,0,2"/>
            <TextBlock Text=".zip archives or mod folders" FontSize="13" Foreground="{DynamicResource TextDim}" HorizontalAlignment="Center"/>
          </StackPanel>
        </Grid>
      </ContentControl>
    </Grid>

    <!-- dialog -->
    <Grid x:Name="DialogLayer" Background="#73000000" Visibility="Collapsed">
      <ContentControl Template="{StaticResource Glass}" Width="460" HorizontalAlignment="Center" VerticalAlignment="Center" Padding="24,20,24,20">
        <StackPanel>
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="DlgIcon" Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="{DynamicResource AccentStrong}" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <TextBlock x:Name="DlgTitle" FontFamily="Segoe UI Light" FontSize="22" Foreground="{DynamicResource Text}" TextWrapping="Wrap" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="DlgMsg" FontSize="13.5" Foreground="{DynamicResource TextDim}" TextWrapping="Wrap" LineHeight="20" Margin="0,12,0,0"/>
          <Grid x:Name="DlgInputWrap" Height="34" Margin="0,14,0,0" Visibility="Collapsed">
            <Border Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource InputBorder}" BorderThickness="1" CornerRadius="{DynamicResource RadiusSmall}"/>
            <TextBox x:Name="DlgInput" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource Text}" CaretBrush="{DynamicResource Text}"
                     SelectionBrush="{DynamicResource Accent}" FontSize="13.5" VerticalContentAlignment="Center" Margin="8,0" MaxLength="40"/>
          </Grid>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
            <Button x:Name="DlgCancel" Style="{StaticResource Btn}" Content="Cancel" MinWidth="96"/>
            <Button x:Name="DlgOk" Style="{StaticResource BtnAccent}" Content="OK" MinWidth="96" Margin="0"/>
          </StackPanel>
        </StackPanel>
      </ContentControl>
    </Grid>
  </Grid>
</Window>
'@

foreach ($part in @(@('store resources','Resources.xaml'),@('sidebar','Sidebar.xaml'),@('store view','Store.xaml'),@('utility view','Utility.xaml'))) {
    $xaml = $xaml.Replace(('<!-- '+$part[0]+' -->'), [IO.File]::ReadAllText((Join-Path $AppDir ('ui/'+$part[1]))))
}
if ($env:R5MM_DIAGNOSTICS) { $listener=New-Object Diagnostics.TextWriterTraceListener((Join-Path $SettingsDir 'bindings.log')); [void][Diagnostics.PresentationTraceSources]::DataBindingSource.Listeners.Add($listener); [Diagnostics.PresentationTraceSources]::DataBindingSource.Switch.Level='All' }
Trace 'xaml'
try {
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
} catch {
    Write-Log ('XAML: ' + $_.Exception.ToString())
    [void][System.Windows.MessageBox]::Show("R5R Mod Manager failed to load its interface.`r`n`r`n" + $_.Exception.Message, $AppName)
    return
}
foreach ($n in ([regex]::Matches($xaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) {
    $el = $window.FindName($n)
    if ($el) { Set-Variable -Name $n -Value $el -Scope Script }
}
$window.Resources['StoreCardWidth'] = [double]232
$ModList.ItemsSource = $script:Items
$FooterText.Text = 'v' + $AppVersion + '  ' + [char]0x00B7 + '  Prednoxx'

# ================================================================ images / brushes
function Load-Bitmap([string]$Path, [int]$DecodeWidth = 0) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource = New-Object System.Uri($Path)
        if ($DecodeWidth -gt 0) { $bmp.DecodePixelWidth = $DecodeWidth }
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    } catch { Write-Log ('Image ' + $Path + ': ' + $_.Exception.Message); return $null }
}

function C([string]$Hex) { return [System.Windows.Media.ColorConverter]::ConvertFromString('#' + $Hex) }
function B([string]$Hex) { $b = New-Object System.Windows.Media.SolidColorBrush (C $Hex); $b.Freeze(); return $b }
function G([string]$Top, [string]$Bottom) {
    $g = New-Object System.Windows.Media.LinearGradientBrush((C $Top), (C $Bottom), 90.0)
    $g.Freeze(); return $g
}

$icon = Load-Bitmap (Join-Path $AssetDir 'icon.png')
if ($icon) { $window.Icon = $icon; $TitleIcon.Source = $icon } else { $TitleIcon.Visibility = 'Collapsed' }
$lumi = Load-Bitmap (Join-Path $AssetDir 'lumi.png')
if ($lumi) { $Mascot.Source = $lumi }

function Apply-Theme([string]$Key) {
    if (-not $Themes.Contains($Key)) { $Key = 'aero_day' }
    $t = $Themes[$Key]
    $script:Theme = $Key
    # value: 'AARRGGBB' or 'RRGGBB' = solid, @(top, bottom) = vertical gradient
    $v = [ordered]@{}
    if ($t.Dark) {
        $v.Text = 'F3F6FA'; $v.TextDim = 'C3CCD8'; $v.TextFaint = '8F9AAA'
        $v.PanelBg = @(('D9' + $t.Tint), ('E6' + $t.Tint2)); $v.PanelBorder = '40FFFFFF'; $v.PanelEdge = '66000000'
        $v.Divider = '26FFFFFF'; $v.Inset = '24000000'
        $v.BtnBg = @('4DFFFFFF', '1AFFFFFF'); $v.BtnBorder = '59FFFFFF'
        $v.BtnHoverBg = @('6613C79B', '3313C79B'); $v.BtnHoverBorder = '5EEBC6'
        $v.RowHover = '14FFFFFF'; $v.RowSel = @('4D13C79B', '2E13C79B'); $v.RowSelBorder = '9919D3A6'
        $v.InputBg = '40000000'; $v.InputBorder = '59FFFFFF'
        $v.TrackOff = @('33000000', '1AFFFFFF'); $v.TrackOffBorder = '66FFFFFF'
        $v.TagOffBg = '26FFFFFF'; $v.TagOffText = 'C3CCD8'
        $v.MenuBg = @(('F2' + $t.Tint), ('F7' + $t.Tint2)); $v.WallShade = '1A000000'
        $v.Accent = '2EE0B0'; $v.AccentStrong = '5EEBC6'; $v.DangerText = 'FF7A7A'
    } else {
        $v.Text = '0F1E2E'; $v.TextDim = '42546A'; $v.TextFaint = '6F7E90'
        $v.PanelBg = @(('E6' + $t.Tint), ('D9' + $t.Tint2)); $v.PanelBorder = 'E6FFFFFF'; $v.PanelEdge = '40000000'
        $v.Divider = '1F0F1E2E'; $v.Inset = '0F0F3050'
        $v.BtnBg = @('FFFFFF', 'E3EBF2'); $v.BtnBorder = '93A6B8'
        $v.BtnHoverBg = @('F2FFFB', 'C9F3E6'); $v.BtnHoverBorder = '1FAF88'
        $v.RowHover = '1A13C79B'; $v.RowSel = @('4013C79B', '2613C79B'); $v.RowSelBorder = '8C0FAF88'
        $v.InputBg = 'F7FFFFFF'; $v.InputBorder = '93A6B8'
        $v.TrackOff = @('C9D3DD', 'E9EEF3'); $v.TrackOffBorder = '93A6B8'
        $v.TagOffBg = '170F1E2E'; $v.TagOffText = '4F6074'
        $v.MenuBg = @('FCFFFFFF', 'F2F4F8FB'); $v.WallShade = '00000000'
        $v.Accent = '13C79B'; $v.AccentStrong = '0A9C78'; $v.DangerText = 'C4262E'
    }
    $v.AccentBg = @('6FF2CF', '14C496'); $v.AccentBorder = '0A9C78'; $v.AccentText = '03352A'
    $v.WindowBg = '1E5FB8'; $v.TitleText = 'FFFFFF'; $v.TitleHover = '33FFFFFF'
    $v.PillBg = '26FFFFFF'; $v.PillBorder = '66FFFFFF'; $v.PillHover = '47FFFFFF'
    $font = 'Segoe UI'
    $gloss = '1'; $radius = '8'; $radiusSmall = '4'
    if ($t.Flat) {
        $gloss = '0'; $radius = '0'; $radiusSmall = '0'
        $v.AccentBg = '13C79B'; $v.BtnBg = 'FFFFFF'; $v.PanelBg = 'F2FFFFFF'
    }
    if ($t.Win11) {
        $font = 'Segoe UI Variable Text, Segoe UI'
        $radius = '8'; $radiusSmall = '4'
        $acc = Get-SystemAccent
        if (Get-SystemDark) {
            $a = Mix-Hex $acc @(255, 255, 255) 0.45
            $v.WindowBg = @('202020', '1C1C1C'); $v.Text = 'FFFFFF'; $v.TextDim = 'C8C8C8'; $v.TextFaint = '9D9D9D'
            $v.PanelBg = '2B2B2B'; $v.PanelBorder = '1F000000'; $v.PanelEdge = '00000000'
            $v.Divider = '15FFFFFF'; $v.Inset = '0DFFFFFF'
            $v.BtnBg = '2D2D2D'; $v.BtnBorder = '3A3A3A'; $v.BtnHoverBg = '323232'; $v.BtnHoverBorder = '444444'
            $v.RowHover = '0DFFFFFF'; $v.RowSel = '14FFFFFF'; $v.RowSelBorder = '00000000'
            $v.InputBg = '1F1F1F'; $v.InputBorder = '3A3A3A'
            $v.TrackOff = '1F1F1F'; $v.TrackOffBorder = '9D9D9D'
            $v.TagOffBg = '14FFFFFF'; $v.TagOffText = 'C8C8C8'
            $v.MenuBg = '2C2C2C'; $v.WallShade = '00000000'
            $v.Accent = $a; $v.AccentStrong = $a; $v.AccentBg = $a; $v.AccentBorder = $a; $v.AccentText = '000000'
            $v.DangerText = 'FF99A4'
            $v.TitleText = 'FFFFFF'; $v.TitleHover = '1AFFFFFF'
            $v.PillBg = '0DFFFFFF'; $v.PillBorder = '1AFFFFFF'; $v.PillHover = '1AFFFFFF'
        } else {
            $a = Mix-Hex $acc @(0, 0, 0) 0.15
            $v.WindowBg = @('F3F3F3', 'EEEFF1'); $v.Text = '1B1B1B'; $v.TextDim = '5C5C5C'; $v.TextFaint = '8A8A8A'
            $v.PanelBg = 'FBFBFB'; $v.PanelBorder = 'E5E5E5'; $v.PanelEdge = '0A000000'
            $v.Divider = '0F000000'; $v.Inset = '08000000'
            $v.BtnBg = 'FFFFFF'; $v.BtnBorder = 'D6D6D6'; $v.BtnHoverBg = 'F6F6F6'; $v.BtnHoverBorder = 'C8C8C8'
            $v.RowHover = '08000000'; $v.RowSel = '0F000000'; $v.RowSelBorder = '00000000'
            $v.InputBg = 'FFFFFF'; $v.InputBorder = 'D6D6D6'
            $v.TrackOff = 'F5F5F5'; $v.TrackOffBorder = '8A8A8A'
            $v.TagOffBg = '0F000000'; $v.TagOffText = '5C5C5C'
            $v.MenuBg = 'F9F9F9'; $v.WallShade = '00000000'
            $v.Accent = $a; $v.AccentStrong = $a; $v.AccentBg = $a; $v.AccentBorder = $a; $v.AccentText = 'FFFFFF'
            $v.DangerText = 'C42B1C'
            $v.TitleText = '1B1B1B'; $v.TitleHover = '0F000000'
            $v.PillBg = 'B3FFFFFF'; $v.PillBorder = 'E5E5E5'; $v.PillHover = 'FFFFFF'
        }
    }

    if ($t.Obsidian) {
        $font='Segoe UI'; $gloss='0'; $radius='8'; $radiusSmall='4'
        $v.WindowBg='11110F'; $v.PanelBg='1B1917'; $v.PanelBorder='302D27'; $v.PanelEdge='00000000'
        $v.Text='F4F1E8'; $v.TextDim='B0ADA4'; $v.TextFaint='827F77'; $v.TitleText='F4F1E8'; $v.TitleHover='292722'
        $v.Divider='302D27'; $v.Inset='24211D'; $v.InputBg='11110F'; $v.InputBorder='35312A'
        $v.BtnBg='171613'; $v.BtnBorder='35312A'; $v.BtnHoverBg='2A2721'; $v.BtnHoverBorder='827663'
        $v.RowHover='302B22'; $v.RowSel='373024'; $v.RowSelBorder='9C8D6B'
        $v.MenuBg='1B1917'; $v.WallShade='00000000'; $v.PillBg='171613'; $v.PillBorder='35312A'; $v.PillHover='292722'
        $v.Accent='F0E2B9'; $v.AccentStrong='F0E2B9'; $v.AccentBg='F0E2B9'; $v.AccentBorder='D1BF91'; $v.AccentText='211E17'
        $v.TagOffBg='302B22'; $v.TagOffText='B0ADA4'; $v.TrackOff='24211D'; $v.TrackOffBorder='827F77'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib">')
    foreach ($k in $v.Keys) {
        $val = $v[$k]
        if ($val -is [array]) {
            [void]$sb.Append('<LinearGradientBrush x:Key="' + $k + '" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#' + $val[0] + '" Offset="0"/><GradientStop Color="#' + $val[1] + '" Offset="1"/></LinearGradientBrush>')
        } else {
            [void]$sb.Append('<SolidColorBrush x:Key="' + $k + '" Color="#' + $val + '"/>')
        }
    }
    [void]$sb.Append('<FontFamily x:Key="UiFont">' + $font + '</FontFamily>')
    [void]$sb.Append('<sys:Double x:Key="GlossOpacity">' + $gloss + '</sys:Double>')
    [void]$sb.Append('<CornerRadius x:Key="Radius">' + $radius + '</CornerRadius>')
    [void]$sb.Append('<CornerRadius x:Key="RadiusSmall">' + $radiusSmall + '</CornerRadius>')
    [void]$sb.Append('</ResourceDictionary>')
    $dict = [System.Windows.Markup.XamlReader]::Parse($sb.ToString())
    $window.Resources.MergedDictionaries.Clear()
    $window.Resources.MergedDictionaries.Add($dict)

    $wp = $null
    if (-not $t.Win11) { $wp = Load-Bitmap (Join-Path $AssetDir ('themes\' + $Key + '.jpg')) }
    if ($wp) { $Wallpaper.Source = $wp } else { $Wallpaper.Source = $null }
    if ($t.Win11 -or $t.Obsidian) {
        $TitleShade.Visibility = 'Collapsed'; $TitleGloss.Visibility = 'Collapsed'; $TitleLabel.Effect = $null
    } else {
        $TitleShade.Visibility = 'Visible'; $TitleGloss.Visibility = 'Visible'
        $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
        $fx.BlurRadius = 8; $fx.ShadowDepth = 0; $fx.Opacity = 0.7
        $TitleLabel.Effect = $fx
    }
    $ThemeName.Text = $t.Name
    $StatusDot.Fill = $window.FindResource('TextFaint')
}

# ================================================================ VDF (Valve KeyValues)
function ConvertFrom-Vdf([string]$Text) {
    $tokens = New-Object System.Collections.Generic.List[string]
    $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ($c -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '{' -or $c -eq '}') { $tokens.Add([string]$c); $i++; continue }
        $sb = New-Object System.Text.StringBuilder
        if ($c -eq '"') {
            $i++
            while ($i -lt $n -and $Text[$i] -ne '"') {
                if ($Text[$i] -eq '\' -and ($i + 1) -lt $n -and ($Text[$i + 1] -eq '"' -or $Text[$i + 1] -eq '\')) {
                    [void]$sb.Append($Text[$i + 1]); $i += 2; continue
                }
                [void]$sb.Append($Text[$i]); $i++
            }
            $i++
        } else {
            while ($i -lt $n -and -not [char]::IsWhiteSpace($Text[$i]) -and $Text[$i] -ne '{' -and $Text[$i] -ne '}' -and $Text[$i] -ne '"') {
                [void]$sb.Append($Text[$i]); $i++
            }
            $word = $sb.ToString()
            if ($word.StartsWith('[') -and $word.EndsWith(']')) { continue }
        }
        $tokens.Add('s:' + $sb.ToString())
    }
    $root  = [ordered]@{}
    $stack = New-Object System.Collections.Stack
    $cur   = $root
    $k = 0
    while ($k -lt $tokens.Count) {
        $t = $tokens[$k]
        if ($t -eq '}') { if ($stack.Count -gt 0) { $cur = $stack.Pop() }; $k++; continue }
        if ($t -eq '{') { $k++; continue }
        $key  = $t.Substring(2)
        $next = $null
        if (($k + 1) -lt $tokens.Count) { $next = $tokens[$k + 1] }
        if ($next -eq '{') {
            $child = [ordered]@{}
            $cur[$key] = $child
            $stack.Push($cur); $cur = $child
            $k += 2
        } elseif ($null -ne $next -and $next.StartsWith('s:')) {
            $cur[$key] = $next.Substring(2)
            $k += 2
        } else { $k++ }
    }
    return $root
}

function Get-VdfString($dict, [string]$key) {
    if ($dict.Contains($key) -and -not ($dict[$key] -is [System.Collections.IDictionary])) { return [string]$dict[$key] }
    return ''
}

function Read-ModVdf([string]$Path) {
    $d = ConvertFrom-Vdf ([IO.File]::ReadAllText($Path))
    $m = $d
    foreach ($key in @($d.Keys)) {
        if ($key -eq 'mod' -and $d[$key] -is [System.Collections.IDictionary]) { $m = $d[$key] }
    }
    $cv = @(); $deps = @()
    foreach ($key in @($m.Keys)) {
        if ($key -eq 'ConVars' -and $m[$key] -is [System.Collections.IDictionary]) { $cv = @($m[$key].Keys) }
        if (($key -eq 'Dependencies' -or $key -eq 'RequiredMods') -and $m[$key] -is [System.Collections.IDictionary]) {
            foreach ($dk in @($m[$key].Keys)) { if ([string]$m[$key][$dk] -ne '0') { $deps += $dk } }
        }
    }
    return @{
        Name        = (Get-VdfString $m 'name')
        Id          = (Get-VdfString $m 'id')
        Version     = (Get-VdfString $m 'version')
        Author      = (Get-VdfString $m 'author')
        Description = (Get-VdfString $m 'description')
        ConVars     = [string[]]$cv
        Deps        = [string[]]$deps
    }
}

# ================================================================ mods.vdf
function Load-ModState {
    $script:ModState    = [ordered]@{}
    $script:ModListRoot = 'ModList'
    if ($script:ModListPath -and (Test-Path -LiteralPath $script:ModListPath)) {
        try {
            $d = ConvertFrom-Vdf ([IO.File]::ReadAllText($script:ModListPath))
            foreach ($key in @($d.Keys)) {
                if ($d[$key] -is [System.Collections.IDictionary]) {
                    $script:ModListRoot = $key
                    foreach ($mk in @($d[$key].Keys)) { $script:ModState[$mk] = [string]$d[$key][$mk] }
                    break
                }
            }
        } catch {
            Set-Status 'mods.vdf could not be read' 'warn'
        }
    }
}

function Save-ModState {
    if (-not (Test-Path -LiteralPath $script:ModsDir)) { New-Item -ItemType Directory -Path $script:ModsDir | Out-Null }
    $bak = $script:ModListPath + '.bak'
    if ((Test-Path -LiteralPath $script:ModListPath) -and -not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $script:ModListPath -Destination $bak
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"' + $script:ModListRoot + '"' + "`r`n{`r`n")
    foreach ($key in @($script:ModState.Keys)) {
        [void]$sb.Append("`t`"" + $key + "`"`t`t`"" + $script:ModState[$key] + "`"`r`n")
    }
    [void]$sb.Append("}`r`n")
    [IO.File]::WriteAllText($script:ModListPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

function Test-ModEnabled([string]$Id) {
    if (-not $Id) { return $true }
    if ($script:ModState.Contains($Id)) { return ($script:ModState[$Id] -ne '0') }
    return $true
}

# ================================================================ scanning
function Scan-Mods {
    $result = New-Object System.Collections.Generic.List[R5MM.ModItem]
    if ($script:ModsDir -and (Test-Path -LiteralPath $script:ModsDir)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $script:ModsDir -Directory -ErrorAction SilentlyContinue)) {
            $vdf = Join-Path $d.FullName 'mod.vdf'
            if (-not (Test-Path -LiteralPath $vdf)) {
                $found = @(Get-ChildItem -LiteralPath $d.FullName -Filter 'mod.vdf' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length })
                if ($found.Count -gt 0) { $vdf = $found[0].FullName } else { $vdf = $null }
            }
            $m = New-Object R5MM.ModItem
            $m.Folder = $d.FullName; $m.FolderName = $d.Name; $m.VdfPath = $vdf; $m.Name = $d.Name
            if (-not $vdf) {
                $m.ProblemTitle = 'Missing mod.vdf'
                $m.Problem = 'No mod.vdf in this folder. The game will not load it.'
            } else {
                try {
                    $info = Read-ModVdf $vdf
                    if ($info.Name) { $m.Name = $info.Name }
                    $m.Id = $info.Id; $m.Version = $info.Version; $m.Author = $info.Author; $m.Description = $info.Description
                    $m.ConVars = $info.ConVars; $m.Deps = $info.Deps
                    if (-not $m.Id) { $m.ProblemTitle = 'Missing ID'; $m.Problem = 'mod.vdf has no "id" entry. The mod cannot be switched on or off.' }
                    elseif ($vdf -ne (Join-Path $d.FullName 'mod.vdf')) { $m.ProblemTitle = 'Nested folder'; $m.Problem = 'mod.vdf is inside a subfolder (' + $vdf.Substring($d.FullName.Length + 1) + '). Move its contents up one level.' }
                } catch {
                    $m.ProblemTitle = 'Unreadable mod.vdf'
                    $m.Problem = $_.Exception.Message
                }
            }
            $result.Add($m)
        }
        foreach ($g in @($result | Where-Object { $_.Id } | Group-Object Id | Where-Object { $_.Count -gt 1 })) {
            foreach ($m in $g.Group) {
                if (-not $m.Problem) { $m.ProblemTitle = 'Duplicate ID'; $m.Problem = 'Another installed mod uses the id "' + $m.Id + '". Both switch on and off together.' }
            }
        }
    }
    $sorted = New-Object System.Collections.Generic.List[R5MM.ModItem]
    foreach ($m in @($result | Sort-Object DisplayName)) { $sorted.Add($m) }
    $script:Mods = $sorted
}

# ================================================================ game folder
function Test-GameDir([string]$Dir) {
    if (-not $Dir) { return $false }
    try {
        return ((Test-Path -LiteralPath (Join-Path $Dir 'r5apex.exe')) -or (Test-Path -LiteralPath (Join-Path $Dir 'r5apex_ds.exe')))
    } catch { return $false }
}

# Runs in a background runspace so the window opens immediately.
$ScanScript = @'
$found = New-Object System.Collections.Generic.List[string]
function Test-Dir([string]$Dir) {
    try { return ((Test-Path -LiteralPath (Join-Path $Dir 'r5apex.exe')) -or (Test-Path -LiteralPath (Join-Path $Dir 'r5apex_ds.exe'))) } catch { return $false }
}
function Add-Dir([string]$Dir) {
    if ($Dir -and (Test-Dir $Dir)) {
        $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
        if (-not ($found -contains $full)) { $found.Add($full) }
    }
}
foreach ($p in @(Get-Process -Name r5apex -ErrorAction SilentlyContinue)) { try { Add-Dir (Split-Path -Parent $p.Path) } catch {} }
$bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE,
           [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
           (Join-Path $env:USERPROFILE 'Downloads'))
foreach ($drv in [IO.DriveInfo]::GetDrives()) {
    try {
        if ($drv.DriveType -eq 'Fixed' -and $drv.IsReady) {
            $bases += $drv.RootDirectory.FullName
            $bases += (Join-Path $drv.RootDirectory.FullName 'Games')
        }
    } catch {}
}
foreach ($b in $bases) {
    if (-not $b -or -not (Test-Path -LiteralPath $b)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'r5|apex' })) {
        Add-Dir $d.FullName
        foreach ($exe in @(Get-ChildItem -LiteralPath $d.FullName -Filter 'r5apex.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)) { Add-Dir $exe.DirectoryName }
    }
}
$found.ToArray()
'@

function Start-InstallScan {
    try {
        $script:ScanPS = [powershell]::Create()
        [void]$script:ScanPS.AddScript($ScanScript)
        $script:ScanHandle = $script:ScanPS.BeginInvoke()
        $scanTimer.Start()
    } catch { Write-Log ('Scan: ' + $_.Exception.Message) }
}

function Resolve-GameDir([string]$Picked) {
    $d = $Picked
    for ($up = 0; $up -lt 4 -and $d; $up++) {
        if (Test-GameDir $d) { return $d }
        $d = Split-Path -Parent $d
    }
    $exe = @(Get-ChildItem -LiteralPath $Picked -Filter 'r5apex.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($exe.Count -gt 0) { return $exe[0].DirectoryName }
    return $null
}

# ================================================================ settings
function Load-Settings {
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return }
    try {
        $s = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
        if ($s.Theme) { $script:Theme = [string]$s.Theme }
        if ($s.ActivePreset) { $script:ActivePreset = [string]$s.ActivePreset }
        if ($s.Presets) {
            foreach ($p in $s.Presets.PSObject.Properties) {
                $map = [ordered]@{}
                foreach ($q in $p.Value.PSObject.Properties) { $map[$q.Name] = [string]$q.Value }
                $script:Presets[$p.Name] = $map
            }
        }
        if ($s.ConVarCache) {
            foreach ($p in $s.ConVarCache.PSObject.Properties) { $script:ConVarCache[$p.Name] = [string[]]@($p.Value) }
        }
        if ($s.GameDir) { return [string]$s.GameDir }
    } catch { Write-Log ('Settings: ' + $_.Exception.Message) }
}

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir | Out-Null }
        $data = [ordered]@{
            GameDir      = $script:GameDir
            StoreLayoutVersion = 1
            Theme        = $script:Theme
            ActivePreset = $script:ActivePreset
            Presets      = $script:Presets
            ConVarCache  = $script:ConVarCache
        }
        ($data | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { Write-Log ('Save settings: ' + $_.Exception.Message) }
}

function Set-GameDir([string]$Dir) {
    $script:GameDir     = $Dir
    $script:ModsDir     = Join-Path $Dir 'mods'
    $script:ModListPath = Join-Path $script:ModsDir 'mods.vdf'
    if (-not ($script:Installs -contains $Dir)) { $script:Installs.Insert(0, $Dir) }
    $GamePath.Text = $Dir
    $SettingsGamePath.Text = $Dir
    $SidebarGameStatus.Text = 'R5Reloaded S3 selected'
    Save-Settings
    Reload-All
}

# ================================================================ UI helpers
function Update-UI {
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Set-Status([string]$Text, [string]$Kind = 'info') {
    switch ($Kind) {
        'ok'    { $StatusDot.Fill = $window.FindResource('Accent') }
        'warn'  { $StatusDot.Fill = $window.FindResource('Warn') }
        default { $StatusDot.Fill = $window.FindResource('TextFaint') }
    }
    $StatusText.Text = $Text
    if ($env:R5MM_DIAGNOSTICS) { $listener.Flush() }
}

function Open-Dialog([string]$Title, [string]$Message, [string]$Ok, [string]$Cancel, [string]$Kind, [bool]$WithInput, [string]$InputText) {
    $DlgTitle.Text = $Title
    $DlgMsg.Text = $Message
    if ($Message) { $DlgMsg.Visibility = 'Visible' } else { $DlgMsg.Visibility = 'Collapsed' }
    $DlgOk.Content = $Ok
    if ($Kind -eq 'danger') { $DlgOk.Style = $window.FindResource('BtnDanger') } else { $DlgOk.Style = $window.FindResource('BtnAccent') }
    if ($Cancel) { $DlgCancel.Content = $Cancel; $DlgCancel.Visibility = 'Visible' } else { $DlgCancel.Visibility = 'Collapsed' }
    switch ($Kind) {
        'warn'   { $DlgIcon.Text = [string][char]0xE7BA; $DlgIcon.Foreground = $window.FindResource('Warn') }
        'danger' { $DlgIcon.Text = [string][char]0xE74D; $DlgIcon.Foreground = $window.FindResource('Danger') }
        'input'  { $DlgIcon.Text = [string][char]0xE8FD; $DlgIcon.Foreground = $window.FindResource('AccentStrong') }
        default  { $DlgIcon.Text = [string][char]0xE946; $DlgIcon.Foreground = $window.FindResource('AccentStrong') }
    }
    if ($WithInput) {
        $DlgInputWrap.Visibility = 'Visible'
        $DlgInput.Text = $InputText
    } else { $DlgInputWrap.Visibility = 'Collapsed' }
    $script:DlgResult = $false
    $script:DlgFrame = New-Object System.Windows.Threading.DispatcherFrame
    $DialogLayer.Visibility = 'Visible'
    if ($WithInput) {
        [void]$window.Dispatcher.BeginInvoke([Action]{ [void]$DlgInput.Focus(); $DlgInput.SelectAll() }, [System.Windows.Threading.DispatcherPriority]::Input)
    }
    [System.Windows.Threading.Dispatcher]::PushFrame($script:DlgFrame)
    $DialogLayer.Visibility = 'Collapsed'
    return $script:DlgResult
}

function Show-Dialog([string]$Title, [string]$Message, [string]$Ok = 'OK', [string]$Cancel = '', [string]$Kind = 'info') {
    return (Open-Dialog $Title $Message $Ok $Cancel $Kind $false '')
}

function Show-Input([string]$Title, [string]$Message, [string]$Default = '', [string]$Ok = 'Save') {
    if (Open-Dialog $Title $Message $Ok 'Cancel' 'input' $true $Default) { return $DlgInput.Text.Trim() }
    return $null
}

function Close-Dialog([bool]$Result) {
    $script:DlgResult = $Result
    if ($script:DlgFrame) { $script:DlgFrame.Continue = $false }
}

function Invoke-Safe([scriptblock]$Block) {
    try { & $Block }
    catch {
        $window.Cursor = $null
        Write-Log $_.Exception.ToString()
        [void](Show-Dialog 'Error' $_.Exception.Message 'OK' '' 'warn')
    }
}

function New-MenuItem([object]$Header, [scriptblock]$OnClick, [object]$Tag) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Style = $window.FindResource('MenuItemS')
    $mi.Header = $Header.psobject.BaseObject
    if ($null -ne $Tag) { $mi.Tag = $Tag.psobject.BaseObject }
    $mi.Add_Click($OnClick)
    return $mi
}

function New-Menu([System.Windows.FrameworkElement]$Target) {
    $menu = New-Object System.Windows.Controls.ContextMenu
    $menu.Style = $window.FindResource('MenuS')
    $menu.PlacementTarget = $Target
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $Target.ContextMenu = $menu
    return $menu
}

function New-MenuSeparator {
    $sep = New-Object System.Windows.Controls.Separator
    $sep.Style = $window.FindResource('MenuSep')
    return $sep
}

function New-CheckHeader([string]$Text, [bool]$Checked) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $chk = New-Object System.Windows.Controls.TextBlock
    $chk.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
    $chk.FontSize = 11
    $chk.Width = 22
    $chk.VerticalAlignment = 'Center'
    if ($Checked) { $chk.Text = [string][char]0xE73E }
    $txt = New-Object System.Windows.Controls.TextBlock
    $txt.Text = $Text
    $txt.VerticalAlignment = 'Center'
    [void]$sp.Children.Add($chk)
    [void]$sp.Children.Add($txt)
    return $sp
}

function Update-Count {
    $on = 0
    foreach ($x in $script:Mods) { if ($x.Id -and $x.Enabled) { $on++ } }
    if ($script:Mods.Count -gt 0) { $CountText.Text = [string]::Format('{0} installed  {2}  {1} active', $script:Mods.Count, $on, [char]0x00B7) } else { $CountText.Text = '' }
    Update-PresetLabel
}

function Fill-List {
    $keep = $null
    if ($ModList.SelectedItem) { $keep = $ModList.SelectedItem.Folder }
    $script:Loading = $true
    $script:Items.Clear()
    $filter = $SearchBox.Text.Trim()
    $target = $null
    foreach ($m in $script:Mods) {
        if ($filter) {
            $hay = ($m.Name + ' ' + $m.Id + ' ' + $m.Author + ' ' + $m.FolderName)
            if ($hay.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $script:Items.Add($m)
        if ($keep -and $m.Folder -eq $keep) { $target = $m }
    }
    if (-not $target -and $script:Items.Count -gt 0) { $target = $script:Items[0] }
    if ($target) { $ModList.SelectedItem = $target.psobject.BaseObject } else { $ModList.SelectedItem = $null }
    $script:Loading = $false

    if (-not $script:GameDir) {
        $EmptyIcon.Text = [string][char]0xE8B7
        $EmptyTitle.Text = 'No game folder'
        $EmptySub.Text = 'Choose the R5Reloaded folder with Change'
        $EmptyState.Visibility = 'Visible'
    } elseif ($script:Mods.Count -eq 0) {
        $EmptyIcon.Text = [string][char]0xE896
        $EmptyTitle.Text = 'No mods installed'
        $EmptySub.Text = 'Drop a .zip or mod folder here'
        $EmptyState.Visibility = 'Visible'
    } elseif ($script:Items.Count -eq 0) {
        $EmptyIcon.Text = [string][char]0xE721
        $EmptyTitle.Text = 'No matches'
        $EmptySub.Text = ('Nothing matches "' + $filter + '"')
        $EmptyState.Visibility = 'Visible'
    } else { $EmptyState.Visibility = 'Collapsed' }

    Update-Count
    Show-Details
}

function Show-Details {
    $m = $ModList.SelectedItem
    $has = ($null -ne $m)
    $BtnOpenMod.IsEnabled = $has
    $BtnRemove.IsEnabled  = $has
    if (-not $has) {
        $DetBody.Visibility = 'Collapsed'
        $DetEmpty.Visibility = 'Visible'
        return
    }
    $DetEmpty.Visibility = 'Collapsed'
    $DetBody.Visibility = 'Visible'
    $DetName.Text = $m.DisplayName
    $DetTagText.Text = $m.Status
    switch ($m.Status) {
        'Active' { $DetTag.Background = $window.FindResource('AccentBg'); $DetTagText.Foreground = $window.FindResource('AccentText') }
        'Error'  { $DetTag.Background = $window.FindResource('Warn');     $DetTagText.Foreground = (B '3A2400') }
        default  { $DetTag.Background = $window.FindResource('TagOffBg'); $DetTagText.Foreground = $window.FindResource('TagOffText') }
    }
    if ($m.Version) { $DetVersion.Text = $m.Version } else { $DetVersion.Text = [string][char]0x2014 }
    if ($m.Author)  { $DetAuthor.Text = $m.Author } else { $DetAuthor.Text = [string][char]0x2014 }
    if ($m.Id)      { $DetId.Text = $m.Id } else { $DetId.Text = [string][char]0x2014 }
    $DetFolder.Text = 'mods\' + $m.FolderName
    $prob = $m.Problem; $ptitle = $m.ProblemTitle
    if (-not $prob -and $m.DepProblem) { $prob = $m.DepProblem; $ptitle = $m.DepTitle }
    if ($prob) {
        $DetWarnTitle.Text = $ptitle
        $DetWarnText.Text = $prob
        $DetWarn.Visibility = 'Visible'
    } else { $DetWarn.Visibility = 'Collapsed' }
    $deps = @($m.Dependencies | Where-Object { $_ })
    if ($deps.Count -gt 0) {
        $parts = foreach ($d in $deps) {
            $dm = Get-ModById $d
            $n = Get-DepName $d
            if (-not $dm) { $n + ' (missing)' } elseif (-not $dm.Enabled) { $n + ' (off)' } else { $n }
        }
        $DetDeps.Text = (@($parts) -join ', ')
        $DetDepsWrap.Visibility = 'Visible'
    } else { $DetDepsWrap.Visibility = 'Collapsed' }
    if ($m.Id -and (Find-Catalog $m.Id)) {
        $script:DetSourceUrl = 'https://github.com/' + $StockRepo
        $DetSourceText.Text = 'github.com/' + $StockRepo
        $DetSourceWrap.Visibility = 'Visible'
    } else { $script:DetSourceUrl = $null; $DetSourceWrap.Visibility = 'Collapsed' }
    if ($m.Description) { $DetDesc.Text = $m.Description.Replace('\n', "`n") } else { $DetDesc.Text = [string][char]0x2014 }
}

function Reload-All {
    if ($script:ModScan) { $script:ModScanAgain = $true; return }
    if (-not $script:ModsDir) { Fill-List; return }
    Load-ModState
    Set-Status 'Scanning installed mods'
    $ModList.IsEnabled = $false
    $functions = @('ConvertFrom-Vdf','Get-VdfString','Read-ModVdf','Scan-Mods','Find-Catalog','Analyze-Mods')
    $code = "param(`$Dir,`$Stock,`$Cache) `n`$ErrorActionPreference='Stop'`n"
    foreach ($name in $functions) { $code += "function $name {" + (Get-Item "function:$name").Definition + "}`n" }
    $code += @'
function Trace([string]$Text) {}
$script:ModsDir = $Dir
$Catalog = $Stock
$script:ConVarCache = $Cache
Scan-Mods
Analyze-Mods
[pscustomobject]@{ Mods = $script:Mods; Cache = $script:ConVarCache }
'@
    $ps = [powershell]::Create()
    [void]$ps.AddScript($code).AddArgument($script:ModsDir).AddArgument($Catalog).AddArgument($script:ConVarCache.Clone())
    $script:ModScan = @{ PS=$ps; Handle=$ps.BeginInvoke(); Dir=$script:GameDir }
    $modTimer.Start()
}

$script:ModScan = $null
$script:ModScanAgain = $false
$modTimer = New-Object System.Windows.Threading.DispatcherTimer
$modTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$modTimer.Add_Tick({
    if (-not $script:ModScan -or -not $script:ModScan.Handle.IsCompleted) { return }
    $job = $script:ModScan
    $script:ModScan = $null
    $modTimer.Stop()
    try {
        $result = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.HadErrors) { throw $job.PS.Streams.Error[0] }
        if ($job.Dir -eq $script:GameDir -and -not $script:ModScanAgain) {
            $script:Mods = $result[-1].Mods
            $script:ConVarCache = $result[-1].Cache
            foreach ($m in $script:Mods) { $m.Enabled = (Test-ModEnabled $m.Id) }
            Update-Issues
            Fill-List
            Save-Settings
            Set-Status 'Ready'
            Trace ('mods ready: ' + $script:Mods.Count)
            if (Get-Command Fill-Store -ErrorAction SilentlyContinue) { Fill-Store }
        }
    } catch { Write-Log ('Mod scan: ' + $_); Set-Status 'Mod scan failed. Rescan to retry.' 'warn' }
    finally { $job.PS.Dispose(); $ModList.IsEnabled = $true }
    if ($script:ModScanAgain) { $script:ModScanAgain = $false; Reload-All }
})

function Require-Game {
    if (-not $script:GameDir) {
        [void](Show-Dialog 'No game folder' 'Choose the R5Reloaded folder (the one with r5apex.exe) first.' 'OK' '' 'warn')
        return $false
    }
    return $true
}

function Remove-ToRecycleBin([string]$Path) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}

function Get-Hwnd { return (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle }

function Pick-Folder([string]$Title, [string]$Initial) {
    try {
        $p = [R5MM.FolderPicker]::Pick((Get-Hwnd), $Title, $Initial)
        if ($p) { return $p }
        return $null
    } catch {
        Write-Log ('FolderPicker: ' + $_.Exception.Message)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Title
        if ($Initial) { $dlg.SelectedPath = $Initial }
        if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
        return $null
    }
}

# ================================================================ actions
function Set-ModEnabled([R5MM.ModItem]$Mod) {
    if ($script:ModScan) { Set-Status 'Wait for the mod scan to finish.' 'warn'; return }
    if (-not $Mod.Id) { return }
    $v = '0'; if ($Mod.Enabled) { $v = '1' }
    $script:ModState[$Mod.Id] = $v
    foreach ($x in $script:Mods) { if ($x.Id -eq $Mod.Id) { $x.Enabled = $Mod.Enabled } }
    Save-ModState
    Update-Issues
    Update-Count
    Show-Details
    if ($Mod.Enabled) { Set-Status ('Enabled ' + $Mod.DisplayName) 'ok' } else { Set-Status ('Disabled ' + $Mod.DisplayName) }
}

function Set-AllEnabled([bool]$On) {
    if ($script:ModScan) { Set-Status 'Wait for the mod scan to finish.' 'warn'; return }
    if (-not (Require-Game)) { return }
    foreach ($m in $script:Mods) {
        if (-not $m.Id) { continue }
        if ($m.IsRequired -and -not $On) { continue }
        $m.Enabled = $On; if ($On) { $script:ModState[$m.Id] = '1' } else { $script:ModState[$m.Id] = '0' }
    }
    Save-ModState
    Update-Issues
    Update-Count
    Show-Details
    if ($On) { Set-Status 'All mods enabled' 'ok' } else { Set-Status 'All mods disabled' }
}

# ---- presets
function Get-PresetDiff([string]$Name) {
    if (-not $Name -or -not $script:Presets.Contains($Name)) { return $false }
    $p = $script:Presets[$Name]
    foreach ($m in $script:Mods) {
        if (-not $m.Id) { continue }
        if ($p.Contains($m.Id)) {
            $want = ($p[$m.Id] -ne '0')
            if ($want -ne $m.Enabled) { return $true }
        }
    }
    return $false
}

function Update-PresetLabel {
    if ($script:ActivePreset -and $script:Presets.Contains($script:ActivePreset)) {
        $PresetName.Text = $script:ActivePreset
        $BtnPresetSave.IsEnabled = $true
        $BtnPresetDelete.IsEnabled = $true
        if (Get-PresetDiff $script:ActivePreset) { $PresetModified.Visibility = 'Visible' } else { $PresetModified.Visibility = 'Collapsed' }
    } else {
        $PresetName.Text = 'None'
        $BtnPresetSave.IsEnabled = $false
        $BtnPresetDelete.IsEnabled = $false
        $PresetModified.Visibility = 'Collapsed'
    }
}

function Get-StateSnapshot {
    $map = [ordered]@{}
    foreach ($m in $script:Mods) {
        if ($m.Id -and -not $m.IsRequired) { if ($m.Enabled) { $map[$m.Id] = '1' } else { $map[$m.Id] = '0' } }
    }
    return $map
}

function Apply-Preset([string]$Name) {
    if ($script:ModScan) { Set-Status 'Wait for the mod scan to finish.' 'warn'; return }
    if (-not (Require-Game)) { return }
    if (-not $script:Presets.Contains($Name)) { return }
    $p = $script:Presets[$Name]
    foreach ($m in $script:Mods) {
        if ($m.Id -and -not $m.IsRequired -and $p.Contains($m.Id)) {
            $m.Enabled = ($p[$m.Id] -ne '0')
            $script:ModState[$m.Id] = $p[$m.Id]
        }
    }
    Save-ModState
    Update-Issues
    $script:ActivePreset = $Name
    Save-Settings
    Update-Count
    Show-Details
    Set-Status ('Preset applied: ' + $Name) 'ok'
}

function Save-CurrentPreset {
    if (-not $script:ActivePreset) { Save-NewPreset; return }
    $script:Presets[$script:ActivePreset] = Get-StateSnapshot
    Save-Settings
    Update-PresetLabel
    Set-Status ('Preset saved: ' + $script:ActivePreset) 'ok'
}

function Save-NewPreset {
    if (-not (Require-Game)) { return }
    $name = Show-Input 'New preset' 'Saves which mods are on or off.' '' 'Save'
    if ($null -eq $name) { return }
    if (-not $name) { return }
    if ($script:Presets.Contains($name)) {
        if (-not (Show-Dialog 'Replace preset' ('"' + $name + '" already exists.') 'Replace' 'Cancel' 'warn')) { return }
    }
    $script:Presets[$name] = Get-StateSnapshot
    $script:ActivePreset = $name
    Save-Settings
    Update-PresetLabel
    Set-Status ('Preset saved: ' + $name) 'ok'
}

function Remove-CurrentPreset {
    $name = $script:ActivePreset
    if (-not $name) { return }
    if (-not (Show-Dialog 'Delete preset' ('"' + $name + '" will be deleted. Mods stay as they are.') 'Delete' 'Cancel' 'danger')) { return }
    $script:Presets.Remove($name)
    $script:ActivePreset = ''
    Save-Settings
    Update-PresetLabel
    Set-Status ('Preset deleted: ' + $name)
}

function Show-PresetMenu {
    $menu = New-Menu $BtnPreset
    if ($script:Presets.Count -eq 0) {
        $none = New-MenuItem (New-CheckHeader 'No presets yet' $false) {} $null
        $none.IsEnabled = $false
        [void]$menu.Items.Add($none.psobject.BaseObject)
    } else {
        foreach ($name in @($script:Presets.Keys)) {
            $mi = New-MenuItem (New-CheckHeader $name ($name -eq $script:ActivePreset)) {
                param($s, $e)
                $n = [string]$s.Tag
                Invoke-Safe { Apply-Preset $n }
            } $name
            [void]$menu.Items.Add($mi.psobject.BaseObject)
        }
    }
    [void]$menu.Items.Add((New-MenuSeparator))
    [void]$menu.Items.Add((New-MenuItem (New-CheckHeader 'Save as new preset' $false) { Invoke-Safe { Save-NewPreset } } $null).psobject.BaseObject)
    $menu.IsOpen = $true
}

# ---- themes
function Show-ThemeMenu {
    $menu = New-Menu $BtnTheme
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    foreach ($key in @($Themes.Keys)) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $bd = New-Object System.Windows.Controls.Border
        $bd.Width = 64; $bd.Height = 36; $bd.CornerRadius = New-Object System.Windows.CornerRadius(3)
        $bd.BorderThickness = New-Object System.Windows.Thickness(1)
        $bd.BorderBrush = $window.FindResource('BtnBorder')
        $bd.Margin = New-Object System.Windows.Thickness(0, 0, 12, 0)
        $th = Load-Bitmap (Join-Path $AssetDir ('themes\' + $key + '_thumb.jpg'))
        if ($th) { $ib = New-Object System.Windows.Media.ImageBrush($th); $ib.Stretch = 'UniformToFill'; $bd.Background = $ib }
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = $Themes[$key].Name
        $txt.VerticalAlignment = 'Center'
        $txt.MinWidth = 96
        $chk = New-Object System.Windows.Controls.TextBlock
        $chk.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
        $chk.FontSize = 11
        $chk.VerticalAlignment = 'Center'
        $chk.Foreground = $window.FindResource('AccentStrong')
        if ($key -eq $script:Theme) { $chk.Text = [string][char]0xE73E }
        [void]$sp.Children.Add($bd); [void]$sp.Children.Add($txt); [void]$sp.Children.Add($chk)
        $mi = New-MenuItem $sp {
            param($s, $e)
            $k = [string]$s.Tag
            Invoke-Safe { Apply-Theme $k; Save-Settings; Show-Details }
        } $key
        [void]$menu.Items.Add($mi.psobject.BaseObject)
    }
    $menu.IsOpen = $true
}

# ---- install / uninstall
function Install-Paths([string[]]$Paths, [switch]$MoveStaged) {
    $script:LastInstalledIds = @()
    if (-not (Require-Game)) { return }
    if ($script:ModScan) { Set-Status 'Wait for the mod scan to finish.' 'warn'; return }
    if (-not (Test-Path -LiteralPath $script:ModsDir)) { New-Item -ItemType Directory -Path $script:ModsDir | Out-Null }
    $installed = @()
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    foreach ($p in $Paths) {
        $tmp = $null
        $leaf = Split-Path -Leaf $p
        try {
            if (Test-Path -LiteralPath $p -PathType Container) {
                $src = $p; $fallback = $leaf
                $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
                if ($full.StartsWith($script:ModsDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    [void](Show-Dialog 'Already installed' ($leaf + ' is already in the mods folder.') 'OK' '' 'warn'); continue
                }
            } elseif ($p -match '\.zip$') {
                Set-Status ('Unpacking ' + $leaf)
                Update-UI
                $tmp = Join-Path $env:TEMP ('r5mm_' + [guid]::NewGuid().ToString('N'))
                Expand-ModPackage $p $tmp
                $src = $tmp; $fallback = [IO.Path]::GetFileNameWithoutExtension($p)
            } elseif ($p -match '\.(7z|rar)$') {
                [void](Show-Dialog 'Unsupported archive' ($leaf + "`n`n.7z and .rar archives need to be extracted first. Install the extracted folder instead.") 'OK' '' 'warn')
                continue
            } else {
                [void](Show-Dialog 'Unsupported file' ($leaf + "`n`nOnly .zip archives and folders can be installed.") 'OK' '' 'warn')
                continue
            }

            $vdfs  = @(Get-ChildItem -LiteralPath $src -Filter 'mod.vdf' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length })
            $roots = @()
            foreach ($v in $vdfs) {
                $dir = $v.DirectoryName
                $nested = $false
                foreach ($r in $roots) { if ($dir.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { $nested = $true; break } }
                if (-not $nested) { $roots += $dir }
            }
            if ($roots.Count -eq 0) {
                [void](Show-Dialog 'No mod found' ($leaf + "`n`nNo mod.vdf found. Only mods made for the R5Reloaded mod system can be installed here.") 'OK' '' 'warn')
                continue
            }

            foreach ($r in $roots) {
                $name = Split-Path -Leaf $r
                if ($r.TrimEnd('\') -eq $src.TrimEnd('\')) { $name = $fallback }
                $info = Read-ModVdf (Join-Path $r 'mod.vdf')
                $label = $name; if ($info.Name) { $label = $info.Name }

                $existing = @($script:Mods | Where-Object { $_.FolderName -eq $name -or ($info.Id -and $_.Id -eq $info.Id) })
                if ($existing.Count -gt 0) {
                    $old = $existing[0]
                    $msg = $label + "`n`n"
                    if ($old.Version) { $msg += 'Installed:  v' + $old.Version + "`n" } else { $msg += "Installed:  unknown version`n" }
                    if ($info.Version) { $msg += 'New:  v' + $info.Version + "`n" } else { $msg += "New:  unknown version`n" }
                    $msg += "`nThe installed copy goes to the Recycle Bin."
                    if (-not (Show-Dialog 'Already installed' $msg 'Replace' 'Skip' 'warn')) { continue }

                }

                $dest = Join-Path $script:ModsDir $name
                if ($existing.Count -gt 0) { $dest = $existing[0].Folder }
                Set-Status ('Installing ' + $label)
                Update-UI
                $backups = @()
                try {
                    $replace = @($existing | ForEach-Object { $_.Folder })
                    if ((Test-Path -LiteralPath $dest) -and $replace -notcontains $dest) { $replace += $dest }
                    foreach ($oldPath in $replace) {
                        if (-not (Test-Path -LiteralPath $oldPath)) { continue }
                        $backup = Join-Path $script:GameDir ('.r5mm-backup-' + [guid]::NewGuid().ToString('N'))
                        [IO.Directory]::Move($oldPath, $backup)
                        $backups += @{Original=$oldPath; Backup=$backup}
                    }
                    if ($MoveStaged) { [IO.Directory]::Move($r, $dest) }
                    else { Copy-Item -LiteralPath $r -Destination $dest -Recurse -Force }
                } catch {
                    if (Test-Path -LiteralPath $dest) { Remove-ToRecycleBin $dest }
                    foreach ($backup in $backups) { [IO.Directory]::Move($backup.Backup, $backup.Original) }
                    throw
                }
                foreach ($backup in $backups) {
                    try { Remove-ToRecycleBin $backup.Backup }
                    catch { Write-Log ('Previous mod retained at ' + $backup.Backup) }
                }
                if ($info.Id) { $script:ModState[$info.Id] = '1'; $script:LastInstalledIds += $info.Id }
                $installed += $label
            }
        } catch {
            Write-Log ('Install ' + $p + ': ' + $_.Exception.ToString())
            [void](Show-Dialog 'Install failed' ($leaf + "`n`n" + $_.Exception.Message) 'OK' '' 'warn')
        } finally {
            if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    $window.Cursor = $null
    if ($installed.Count -gt 0) {
        Save-ModState
        Reload-All
        Set-Status ('Installed ' + ($installed -join ', ')) 'ok'
    } else {
        Set-Status 'Nothing installed' 'warn'
    }
}

# ---- dependencies / required mods
function Find-Catalog([string]$Id) {
    foreach ($c in $Catalog) { if ($c.Id -ieq $Id) { return $c } }
    return $null
}

function Get-ModById([string]$Id) {
    if (-not $Id) { return $null }
    foreach ($m in $script:Mods) { if ($m.Id -and $m.Id -ieq $Id) { return $m } }
    return $null
}

function Get-DepName([string]$Id) {
    $m = Get-ModById $Id
    if ($m) { return $m.DisplayName }
    $c = Find-Catalog $Id
    if ($c) { return $c.Name }
    return $Id
}

function Add-Unique($List, $Item) { if (-not $List.Contains($Item)) { $List.Add($Item) } }

# Dependencies come from a mod.vdf "Dependencies" block, or from scripts that use
# ConVars another mod defines in its mod.vdf.
function Analyze-Mods {
    foreach ($m in $script:Mods) {
        $c = $null
        if ($m.Id) { $c = Find-Catalog $m.Id }
        $m.IsRequired = [bool]($c -and $c.Required)
        if ($m.Id -and $m.ConVars -and $m.ConVars.Count -gt 0) { $script:ConVarCache[$m.Id] = [string[]]$m.ConVars }
    }
    $owners = @{}
    foreach ($k in @($script:ConVarCache.Keys)) { foreach ($cv in @($script:ConVarCache[$k])) { if ($cv) { $owners[$cv.ToLowerInvariant()] = $k } } }
    $rx = $null
    if ($owners.Count -gt 0) {
        $alt = (@($owners.Keys) | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $rx = New-Object System.Text.RegularExpressions.Regex(('"(' + $alt + ')"'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromMilliseconds(250))
    }
    foreach ($m in $script:Mods) {
        $deps = New-Object System.Collections.Generic.List[string]
        foreach ($d in @($m.Deps)) { if ($d -and -not $deps.Contains($d)) { $deps.Add($d) } }
        Trace ('  analyze ' + $m.FolderName)
        if ($rx -and -not $m.IsRequired -and (Test-Path -LiteralPath $m.Folder)) {
            Trace '    listing'
            $found = @(Get-ChildItem -LiteralPath $m.Folder -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.nut', '.gnut') -and $_.Length -le 4MB })
            Trace ('    files ' + $found.Count)
            foreach ($f in $found) {
                Trace ('    read ' + $f.Name)
                $txt = $null
                try { $txt = [IO.File]::ReadAllText($f.FullName) } catch { continue }
                Trace ('    match ' + $txt.Length)
                foreach ($mt in $rx.Matches($txt)) {
                    $own = $owners[$mt.Groups[1].Value.ToLowerInvariant()]
                    if ($own -and -not ($m.Id -and $own -ieq $m.Id) -and -not $deps.Contains($own)) { $deps.Add($own) }
                }
            }
        }
        $m.Dependencies = $deps.ToArray()
    }
}

function Update-Issues {
    $lines = New-Object System.Collections.Generic.List[string]
    $script:FixEnable = New-Object System.Collections.Generic.List[object]
    $script:FixMissing = New-Object System.Collections.Generic.List[object]
    foreach ($m in $script:Mods) { $m.DepProblem = $null; $m.DepTitle = $null }
    if (-not $script:GameDir) { $IssueBar.Visibility = 'Collapsed'; return }
    foreach ($c in $Catalog) {
        if (-not $c.Required) { continue }
        $m = Get-ModById $c.Id
        if (-not $m) { $lines.Add($c.Name + ' is not installed. R5Reloaded needs it for its menus and settings.'); Add-Unique $script:FixMissing $c }
        elseif (-not $m.Enabled) { $lines.Add($m.DisplayName + ' is switched off. R5Reloaded needs it for its menus and settings.'); Add-Unique $script:FixEnable $m }
    }
    foreach ($m in $script:Mods) {
        if (-not $m.Enabled -or $m.IsRequired -or -not $m.Dependencies) { continue }
        $off = @(); $missing = @()
        foreach ($d in $m.Dependencies) {
            $dm = Get-ModById $d
            if ($dm) { if (-not $dm.Enabled) { $off += $dm } } else { $missing += $d }
        }
        $msgs = @()
        if ($off.Count -gt 0) {
            $names = ($off | ForEach-Object { $_.DisplayName }) -join ', '
            $msgs += ('Needs ' + $names + ', which is switched off.')
            foreach ($o in $off) { Add-Unique $script:FixEnable $o }
        }
        if ($missing.Count -gt 0) {
            $names = ($missing | ForEach-Object { Get-DepName $_ }) -join ', '
            $msgs += ('Needs ' + $names + ', which is not installed.')
            foreach ($d in $missing) { $c = Find-Catalog $d; if ($c) { Add-Unique $script:FixMissing $c } }
        }
        if ($msgs.Count -gt 0) {
            if ($missing.Count -gt 0) { $m.DepTitle = 'Missing dependency' } else { $m.DepTitle = 'Dependency switched off' }
            $m.DepProblem = ($msgs -join ' ')
            $lines.Add($m.DisplayName + ': ' + ($msgs -join ' '))
        }
    }
    if ($lines.Count -gt 0) {
        $IssueText.Text = ($lines -join "`n")
        $IssueBar.Visibility = 'Visible'
        if (($script:FixEnable.Count + $script:FixMissing.Count) -gt 0) { $BtnFixIssues.Visibility = 'Visible' } else { $BtnFixIssues.Visibility = 'Collapsed' }
        if ($script:FixMissing.Count -gt 0) { $FixText.Text = 'Fix' } else { $FixText.Text = 'Turn on' }
    } else { $IssueBar.Visibility = 'Collapsed' }
}

function Fix-Issues {
    $changed = $false
    foreach ($m in @($script:FixEnable)) { $m.Enabled = $true; $script:ModState[$m.Id] = '1'; $changed = $true }
    if ($changed) { Save-ModState }
    $missing = @($script:FixMissing)
    Update-Issues; Update-Count; Show-Details
    if ($missing.Count -gt 0) { Install-StockMods $missing }
    elseif ($changed) { Set-Status 'Required mods switched on' 'ok' }
}

# ---- recycle bin
function Get-RecycledMods {
    $list = New-Object System.Collections.Generic.List[object]
    if (-not $script:ModsDir) { return $list }
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($it in @($shell.Namespace(10).Items())) {
            if (-not $it.IsFolder) { continue }
            $from = [string]$it.ExtendedProperty('System.Recycle.DeletedFrom')
            if (-not $from -or ($from.TrimEnd('\') -ine $script:ModsDir.TrimEnd('\'))) { continue }
            $date = $null
            try { $date = [datetime]$it.ExtendedProperty('System.Recycle.DateDeleted') } catch {}
            $list.Add([pscustomobject]@{ Name = [string]$it.Name; Item = $it; Date = $date })
        }
    } catch { Write-Log ('Recycle Bin: ' + $_.Exception.Message) }
    $sorted = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($list | Sort-Object Date -Descending)) { $sorted.Add($x) }
    return $sorted
}

function Restore-Recycled($Entry) {
    $target = Join-Path $script:ModsDir $Entry.Name
    if (Test-Path -LiteralPath $target) { throw ($Entry.Name + ' is already in the mods folder.') }
    try { $Entry.Item.InvokeVerb('undelete') } catch {}
    for ($i = 0; $i -lt 40 -and -not (Test-Path -LiteralPath $target); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $target)) {
        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace($script:ModsDir).MoveHere($Entry.Item, 0x14)
        for ($i = 0; $i -lt 60 -and -not (Test-Path -LiteralPath $target); $i++) { Start-Sleep -Milliseconds 100 }
    }
    return (Test-Path -LiteralPath $target)
}

function Restore-ByName([string]$Name) {
    $r = @(Get-RecycledMods) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $r) { [void](Show-Dialog 'Not found' ($Name + ' is no longer in the Recycle Bin.') 'OK' '' 'warn'); return }
    if (Restore-Recycled $r) { Reload-All; Set-Status ('Restored ' + $Name) 'ok' }
    else { [void](Show-Dialog 'Restore failed' ($Name + ' could not be restored from the Recycle Bin.') 'OK' '' 'warn') }
}

# ---- stock mod downloads
function Queue-StockDownload($Entry) {
    $match = $script:StoreItems | Where-Object { $_.Build -eq 'R5Reloaded S3' -and $_.ModId -ieq $Entry.Id } | Select-Object -First 1
    if (-not $match) { Set-Status 'Refresh the catalog before downloading this mod.' 'warn'; return }
    $script:PackageQueue.Enqueue($match)
    $storeTimer.Start()
    if ($script:PackageJob) { return }
    Show-AppView $true
    $StoreSearch.Text = $match.Name
    $StoreBuild.SelectedIndex = 0; $StoreSourceFilter.SelectedIndex = 0; $StoreCategory.SelectedIndex = 0
    Fill-Store
}

function Install-StockMods($Entries) {
    if (-not (Require-Game)) { return }
    $bin = @(Get-RecycledMods)
    $need = @(); $restored = @()
    foreach ($c in @($Entries)) {
        if (Get-ModById $c.Id) { continue }
        $r = $bin | Where-Object { $_.Name -ieq $c.Folder } | Select-Object -First 1
        if ($r -and (Restore-Recycled $r)) { $script:ModState[$c.Id] = '1'; $restored += $c.Name } else { $need += $c }
    }
    if ($restored.Count -gt 0) { Save-ModState; Reload-All; Set-Status ('Restored ' + ($restored -join ', ') + ' from the Recycle Bin') 'ok' }
    if ($need.Count -gt 0) {
        $names = ($need | ForEach-Object { $_.Name }) -join ', '
        $msg = $names + "`n`nDownloads from github.com/" + $StockRepo + ' (official R5Reloaded scripts).'
        if (Show-Dialog 'Download stock mods' $msg 'Download' 'Cancel') { foreach ($c in $need) { Queue-StockDownload $c } }
    }
}

function Show-RestoreMenu {
    if (-not (Require-Game)) { return }
    $menu = New-Menu $BtnRestore
    $h1 = New-MenuItem (New-CheckHeader 'Recycle Bin' $false) {} $null
    $h1.IsEnabled = $false; $h1.FontWeight = [System.Windows.FontWeights]::SemiBold
    [void]$menu.Items.Add($h1.psobject.BaseObject)
    $bin = @(Get-RecycledMods)
    if ($bin.Count -eq 0) {
        $none = New-MenuItem (New-CheckHeader 'Nothing from this mods folder' $false) {} $null
        $none.IsEnabled = $false
        [void]$menu.Items.Add($none.psobject.BaseObject)
    } else {
        foreach ($r in @($bin | Select-Object -First 12)) {
            $label = $r.Name
            if ($r.Date) { $label += '    ' + $r.Date.ToString('g') }
            $mi = New-MenuItem (New-CheckHeader $label $false) {
                param($s, $e)
                $n = [string]$s.Tag
                Invoke-Safe { Restore-ByName $n }
            } $r.Name
            [void]$menu.Items.Add($mi.psobject.BaseObject)
        }
    }
    [void]$menu.Items.Add((New-MenuSeparator))
    $h2 = New-MenuItem (New-CheckHeader 'Stock mods' $false) {} $null
    $h2.IsEnabled = $false; $h2.FontWeight = [System.Windows.FontWeights]::SemiBold
    [void]$menu.Items.Add($h2.psobject.BaseObject)
    foreach ($c in $Catalog) {
        $have = [bool](Get-ModById $c.Id)
        $text = $c.Name
        if ($c.Required) { $text += '  (required)' }
        if (-not $have) { $text += '  ' + [char]0x00B7 + '  Get' }
        $mi = New-MenuItem (New-CheckHeader $text $have) {
            param($s, $e)
            $id = [string]$s.Tag
            Invoke-Safe { Install-StockMods @(Find-Catalog $id) }
        } $c.Id
        if ($have) { $mi.IsEnabled = $false }
        [void]$menu.Items.Add($mi.psobject.BaseObject)
    }
    $menu.IsOpen = $true
}

function Remove-SelectedMod {
    if ($script:ModScan) { Set-Status 'Wait for the mod scan to finish.' 'warn'; return }
    $m = $ModList.SelectedItem
    if (-not $m) { return }
    $msg = 'The mod folder goes to the Recycle Bin.'
    if ($m.IsRequired) { $msg = "R5Reloaded needs this mod for its menus and settings. Without it the game shows errors and blank labels.`n`nThe mod folder goes to the Recycle Bin." }
    if (-not (Show-Dialog ('Uninstall ' + $m.DisplayName) $msg 'Uninstall' 'Cancel' 'danger')) { return }
    Remove-ToRecycleBin $m.Folder
    if ($m.Id) {
        $others = @($script:Mods | Where-Object { $_.Folder -ne $m.Folder -and $_.Id -eq $m.Id })
        if ($others.Count -eq 0 -and $script:ModState.Contains($m.Id)) { $script:ModState.Remove($m.Id); Save-ModState }
    }
    Reload-All
    Set-Status ('Uninstalled ' + $m.DisplayName)
}

# ---- game folder
function Browse-GameDir {
    $picked = Pick-Folder 'Choose the R5Reloaded folder' $script:GameDir
    if (-not $picked) { return }
    $dir = Resolve-GameDir $picked
    if (-not $dir) {
        [void](Show-Dialog 'R5Reloaded not found' ($picked + "`n`nThis folder does not contain r5apex.exe.") 'OK' '' 'warn')
        return
    }
    Set-GameDir $dir
    Set-Status 'Game folder set' 'ok'
}

function Show-ChangeMenu {
    $menu = New-Menu $BtnChange
    foreach ($p in $script:Installs) {
        $mi = New-MenuItem (New-CheckHeader $p ($p -eq $script:GameDir)) {
            param($s, $e)
            $path = [string]$s.Tag
            Invoke-Safe { Set-GameDir $path; Set-Status 'Game folder set' 'ok' }
        } $p
        [void]$menu.Items.Add($mi.psobject.BaseObject)
    }
    if ($script:Installs.Count -gt 0) { [void]$menu.Items.Add((New-MenuSeparator)) }
    [void]$menu.Items.Add((New-MenuItem (New-CheckHeader 'Browse...' $false) { Invoke-Safe { Browse-GameDir } } $null).psobject.BaseObject)
    $menu.IsOpen = $true
}

function Ensure-Shortcut {
    try {
        $ico = Join-Path $AssetDir 'app.ico'
        if (-not $env:R5MM_SELF -or -not (Test-Path -LiteralPath $ico)) { return }
        $lnk = Join-Path $AppDir 'R5R Mod Manager.lnk'
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        if ($sc.TargetPath -eq $env:R5MM_SELF -and $sc.IconLocation -like ($ico + '*')) { return }
        $sc.TargetPath = Join-Path $AppDir 'R5R Mod Manager.exe'
        $sc.WorkingDirectory = $AppDir
        $sc.IconLocation = $ico + ',0'
        $sc.WindowStyle = 1
        $sc.Description = 'R5R Mod Manager'
        $sc.Save()
    } catch { Write-Log ('Shortcut: ' + $_.Exception.Message) }
}

function Test-GameRunning { return [bool](Get-Process -Name r5apex -ErrorAction SilentlyContinue) }

function Launch-Game {
    if (-not (Require-Game)) { return }
    if (Test-GameRunning) { Set-Status 'R5Reloaded is already running' 'warn'; return }
    $exe = Join-Path $script:GameDir 'r5apex.exe'
    if (-not (Test-Path -LiteralPath $exe)) { [void](Show-Dialog 'Launch failed' 'r5apex.exe not found in the game folder.' 'OK' '' 'warn'); return }
    Start-Process -FilePath $exe -WorkingDirectory $script:GameDir
    Set-Status 'Launching R5Reloaded' 'ok'
}

function Open-Folder([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Path + '"') }
}

function Update-MaxGlyph {
    if ($window.WindowState -eq 'Maximized') {
        $BtnMax.Content = [string][char]0xE923
        $Root.Margin = New-Object System.Windows.Thickness(7)
    } else {
        $BtnMax.Content = [string][char]0xE922
        $Root.Margin = New-Object System.Windows.Thickness(0)
    }
}

# ================================================================ events
$BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$BtnMax.Add_Click({ if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' } })
$BtnClose.Add_Click({ $window.Close() })
$window.Add_StateChanged({ Update-MaxGlyph })

$DlgOk.Add_Click({ Close-Dialog $true })
$DlgCancel.Add_Click({ Close-Dialog $false })

$ModList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $cb = $e.OriginalSource
    if ($cb -is [System.Windows.Controls.CheckBox] -and $cb.DataContext -is [R5MM.ModItem]) {
        $mod = $cb.DataContext
        Invoke-Safe { Set-ModEnabled $mod }
    }
})
$ModList.Add_SelectionChanged({ if (-not $script:Loading) { Invoke-Safe { Show-Details } } })

$SearchBox.Add_TextChanged({
    if ($SearchBox.Text) { $SearchHint.Visibility = 'Hidden' } else { $SearchHint.Visibility = 'Visible' }
    Invoke-Safe { Fill-List }
})

$window.Add_PreviewKeyDown({
    param($s, $e)
    if ($DialogLayer.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') { $e.Handled = $true; if ($DlgCancel.Visibility -eq 'Visible') { Close-Dialog $false } else { Close-Dialog $true } }
        elseif ($e.Key -eq 'Return') { $e.Handled = $true; Close-Dialog $true }
        return
    }
    if ($e.Key -eq 'Escape' -and $script:StoreMode) { if ($ImageOverlay.Visibility -eq 'Visible') { $ImageOverlay.Visibility='Collapsed' } else { Close-StoreDetail }; $e.Handled=$true; return }
    if ($e.Key -eq 'F' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        $e.Handled = $true; if ($script:StoreMode) { [void]$StoreSearch.Focus() } else { [void]$SearchBox.Focus() }; return
    }
    if ($e.Key -eq 'F5') { $e.Handled = $true; Invoke-Safe { if ($script:StoreMode) { Start-StoreSync $true } elseif (Require-Game) { Reload-All } }; return }
    if ($e.Key -eq 'Delete' -and -not $script:StoreMode -and -not $SearchBox.IsKeyboardFocusWithin) { $e.Handled = $true; Invoke-Safe { Remove-SelectedMod } }
})

# drag and drop
$window.Add_PreviewDragEnter({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop) -and $DialogLayer.Visibility -ne 'Visible') {
        $e.Effects = [System.Windows.DragDropEffects]::Copy; $DropLayer.Visibility = 'Visible'
    } else { $e.Effects = [System.Windows.DragDropEffects]::None }
    $e.Handled = $true
})
$window.Add_PreviewDragOver({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop) -and $DialogLayer.Visibility -ne 'Visible') {
        $e.Effects = [System.Windows.DragDropEffects]::Copy
    } else { $e.Effects = [System.Windows.DragDropEffects]::None }
    $e.Handled = $true
})
$window.Add_PreviewDragLeave({
    param($s, $e)
    $pt = $e.GetPosition($window)
    if ($pt.X -le 1 -or $pt.Y -le 1 -or $pt.X -ge ($window.ActualWidth - 1) -or $pt.Y -ge ($window.ActualHeight - 1)) { $DropLayer.Visibility = 'Collapsed' }
})
$window.Add_PreviewDrop({
    param($s, $e)
    $DropLayer.Visibility = 'Collapsed'
    $e.Handled = $true
    if ($DialogLayer.Visibility -eq 'Visible') { return }
    $files = [string[]]$e.Data.GetData([System.Windows.DataFormats]::FileDrop)
    if ($files) {
        $script:PendingDrop = $files
        [void]$window.Activate()
        [void]$window.Dispatcher.BeginInvoke([Action]{ Invoke-Safe { Install-Paths $script:PendingDrop } }, [System.Windows.Threading.DispatcherPriority]::Background)
    }
})

$BtnTheme.Add_Click({ Invoke-Safe { Show-ThemeMenu } })
$BtnRestore.Add_Click({ Invoke-Safe { Show-RestoreMenu } })
$BtnFixIssues.Add_Click({ Invoke-Safe { Fix-Issues } })
$DetSource.Add_Click({ if ($script:DetSourceUrl) { Start-Process $script:DetSourceUrl } })
$BtnChange.Add_Click({ Invoke-Safe { Show-ChangeMenu } })
$BtnModsFolder.Add_Click({
    Invoke-Safe {
        if (Require-Game) {
            if (-not (Test-Path -LiteralPath $script:ModsDir)) { New-Item -ItemType Directory -Path $script:ModsDir | Out-Null }
            Open-Folder $script:ModsDir
        }
    }
})
$BtnInstallZip.Add_Click({
    Invoke-Safe {
        if (-not (Require-Game)) { return }
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Install mod (.zip)'
        $dlg.Filter = 'Mod archives (*.zip)|*.zip'
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog($window)) { Install-Paths $dlg.FileNames }
    }
})
$BtnInstallDir.Add_Click({
    Invoke-Safe {
        if (-not (Require-Game)) { return }
        $picked = Pick-Folder 'Install mod folder' $null
        if ($picked) { Install-Paths @($picked) }
    }
})
$BtnEnableAll.Add_Click({ Invoke-Safe { Set-AllEnabled $true } })
$BtnDisableAll.Add_Click({ Invoke-Safe { Set-AllEnabled $false } })
$BtnRefresh.Add_Click({ Invoke-Safe { if (Require-Game) { Reload-All } } })
$BtnPreset.Add_Click({ Invoke-Safe { Show-PresetMenu } })
$BtnPresetSave.Add_Click({ Invoke-Safe { Save-CurrentPreset } })
$BtnPresetNew.Add_Click({ Invoke-Safe { Save-NewPreset } })
$BtnPresetDelete.Add_Click({ Invoke-Safe { Remove-CurrentPreset } })
$BtnOpenMod.Add_Click({ Invoke-Safe { $m = $ModList.SelectedItem; if ($m) { Open-Folder $m.Folder } } })
$BtnRemove.Add_Click({ Invoke-Safe { Remove-SelectedMod } })
$BtnLaunch.Add_Click({ Invoke-Safe { Launch-Game } })

# game process watcher
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(2500)
$timer.Add_Tick({
    try {
        $running = Test-GameRunning
        if ($running -ne $script:WasRunning) {
            $script:WasRunning = $running
            if ($running) {
                $LaunchText.Text = 'Running'; $LaunchIcon.Text = [string][char]0xE7FC
                Set-Status 'R5Reloaded is running. Changes apply on the next launch.' 'warn'
            } else {
                $LaunchText.Text = 'Launch'; $LaunchIcon.Text = [string][char]0xE768
                Set-Status 'Ready'
            }
        }
    } catch {}
})

# background install search
$scanTimer = New-Object System.Windows.Threading.DispatcherTimer
$scanTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$scanTimer.Add_Tick({
    try {
        if (-not $script:ScanHandle -or -not $script:ScanHandle.IsCompleted) { return }
        $scanTimer.Stop()
        $res = @($script:ScanPS.EndInvoke($script:ScanHandle))
        $script:ScanPS.Dispose(); $script:ScanPS = $null; $script:ScanHandle = $null
        foreach ($p in $res) { $ps = [string]$p; if ($ps -and -not ($script:Installs -contains $ps)) { $script:Installs.Add($ps) } }
        $window.Cursor = $null
        if (-not $script:GameDir) {
            if ($script:Installs.Count -gt 0) { Set-GameDir $script:Installs[0] }
            else { Fill-List; Set-Status 'R5Reloaded not found. Set the game folder with Change.' 'warn' }
        }
    } catch {
        $scanTimer.Stop()
        Write-Log ('Scan result: ' + $_.Exception.Message)
    }
})

foreach ($library in @('Catalog.ps1','Packages.ps1','Media.ps1','StoreMedia.ps1','Store.ps1')) {
    . ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $AppDir ('lib/' + $library)))))
}

# ================================================================ start
Trace 'settings'
$savedDir = Load-Settings
if (-not (Read-CatalogJson $SettingsFile).StoreLayoutVersion) { $script:Theme='obsidian' }
Trace 'theme'
Apply-Theme $script:Theme
Trace 'show'
Update-PresetLabel

$window.Add_ContentRendered({
    Trace 'rendered'
    if ($script:Started) { return }
    $script:Started = $true
    Invoke-Safe {
        if ($savedDir -and (Test-GameDir $savedDir)) {
            Set-GameDir $savedDir
        } else {
            Fill-List
            Set-Status 'Looking for R5Reloaded'
            $window.Cursor = [System.Windows.Input.Cursors]::AppStarting
        }
        Read-StoreCache
        Show-AppView $true
        Start-StoreSync
        $storeRefreshTimer.Start()
        Trace 'scan start'
        if (-not $script:GameDir) { Start-InstallScan }
        $timer.Start()
        Trace 'shortcut'
        Ensure-Shortcut
        Trace 'startup done'
    }
})

try {
    [void]$window.ShowDialog()
} catch {
    Write-Log ('Runtime: ' + $_.Exception.ToString())
    [void][System.Windows.MessageBox]::Show($_.Exception.Message, $AppName)
} finally {
    $storeTimer.Stop(); $storeRefreshTimer.Stop(); $mediaTimer.Stop()
    foreach ($job in @($script:StoreJob, $script:PackageJob, $script:MediaJob, $script:DetailJob)) { if ($job) { try { $job.PS.Stop(); $job.PS.Dispose() } catch {} } }
    if ($script:PackageJob) { try { Remove-PackageStage $script:PackageJob.Stage $script:PackageJob.GameDir } catch {} }
    $modTimer.Stop()
    if ($script:ModScan) { try { $script:ModScan.PS.Stop(); $script:ModScan.PS.Dispose() } catch {} }
    $timer.Stop()
    $scanTimer.Stop()
    if ($script:DlJob) { try { $script:DlJob.PS.Stop(); $script:DlJob.PS.Dispose() } catch {} }
    if ($script:ScanPS) { try { $script:ScanPS.Stop(); $script:ScanPS.Dispose() } catch {} }
}
