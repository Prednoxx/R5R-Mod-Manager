param([switch]$Live)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('r5mm-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
$script:Passed = 0
function Assert($Condition, [string]$Name) {
    if (-not $Condition) { throw ('FAIL: ' + $Name) }
    $script:Passed++; Write-Output ('PASS: ' + $Name)
}
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert $threw $Name
}
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'app.ps1'), [ref]$null, [ref]$parseErrors)
Assert (-not $parseErrors) 'App syntax'
function Import-AppFunction([string]$Name) {
    $definition = $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true) | Where-Object Name -eq $Name | Select-Object -First 1
    if (-not $definition) { throw ('Function not found: ' + $Name) }
    . ([scriptblock]::Create($definition.Extent.Text.Replace('function '+$Name, 'function script:'+$Name)))
}
foreach ($name in @('ConvertFrom-Vdf','Get-VdfString','Read-ModVdf','Scan-Mods','Find-Catalog','Analyze-Mods','Install-Paths','Save-ModState')) { Import-AppFunction $name }
$text = [IO.File]::ReadAllText((Join-Path $root 'app.ps1'))
$types = [regex]::Match($text, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
Add-Type -TypeDefinition $types.Groups[1].Value
Add-Type -AssemblyName Microsoft.VisualBasic, System.IO.Compression, System.IO.Compression.FileSystem, PresentationFramework
. (Join-Path $root 'lib/Catalog.ps1')
. (Join-Path $root 'lib/Packages.ps1')
function Trace([string]$Text) {}
function Write-Log([string]$Text) {}
function Require-Game { return $true }
function Set-Status([string]$Text, [string]$Kind) {}
function Update-UI {}
function Reload-All {}
function Show-Dialog { return $script:Approve }
function Remove-ToRecycleBin([string]$Path) { [IO.Directory]::Move($Path, (Join-Path $sandbox ('recycled-' + [guid]::NewGuid().ToString('N')))) }
$script:Approve = $true
$script:ModScan = $null
$window = [pscustomobject]@{Cursor=$null}
function Make-Zip([string]$Path, [string[]]$Names, [string]$Content = 'test') {
    $zip = [IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Names) {
            $entry = $zip.CreateEntry($name)
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write($Content) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}
function Make-Mod([string]$Path, [string]$Id, [string]$Version='1.0') {
    [void][IO.Directory]::CreateDirectory($Path)
    [IO.File]::WriteAllText((Join-Path $Path 'mod.vdf'), ('"mod" { "id" "' + $Id + '" "name" "Fixture" "version" "' + $Version + '" }'))
}
try {
    $card=New-Object R5MM.CatalogCard -Property @{Name='Preview';PreviewPath=(Join-Path $root 'assets/icon.png')}
    $image=New-Object Windows.Controls.Image
    $image.DataContext=$card
    [void]$image.SetBinding([Windows.Controls.Image]::SourceProperty,(New-Object Windows.Data.Binding('PreviewPath')))
    $image.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::DataBind)
    Assert ($null -ne $image.Source -and $image.Source.Width -gt 0) 'Catalog card preview binds to a decoded image'
    Assert (Test-CatalogUrl 'https://example.org/mod.zip') 'HTTPS source accepted'
    Assert (-not (Test-CatalogUrl 'http://example.org/mod.zip')) 'HTTP source rejected'
    Assert (-not (Test-CatalogUrl 'https://user:pass@example.org/mod.zip')) 'Embedded credentials rejected'
    $source = [pscustomobject]@{id='fixture';name='Fixture'}
    Assert-Throws { New-CatalogEntry $source ([pscustomobject]@{id='../bad';name='Bad';build='R5Reloaded S3';pageUrl='https://example.org'}) } 'Invalid listing ID rejected'
    Assert-Throws { New-CatalogEntry $source ([pscustomobject]@{id='good';name='Bad';build='R5Reloaded S3';pageUrl='https://example.org';installKind='zip'}) } 'Installable listing requires a mod ID and package URL'
    $jsonPath = Join-Path $sandbox 'atomic.json'
    Write-CatalogJson $jsonPath @{version=1}; Write-CatalogJson $jsonPath @{version=2}
    Assert ((Read-CatalogJson $jsonPath).version -eq 2) 'Atomic cache replacement'
    foreach ($name in @('../escape.txt','..\escape.txt','/absolute.txt','safe/file:stream','CON.txt','safe/trailing.')) {
        $zipPath = Join-Path $sandbox ([guid]::NewGuid().ToString('N')+'.zip')
        Make-Zip $zipPath @($name)
        Assert-Throws { Expand-ModPackage $zipPath (Join-Path $sandbox 'unsafe') } ('Archive rejects ' + $name)
    }
    $zipPath = Join-Path $sandbox 'duplicate.zip'; Make-Zip $zipPath @('same.txt','SAME.txt')
    Assert-Throws { Expand-ModPackage $zipPath (Join-Path $sandbox 'duplicate') } 'Archive rejects duplicate Windows paths'
    $zipPath = Join-Path $sandbox 'valid.zip'; Make-Zip $zipPath @('Wrapped/mod.vdf') '"mod" { "id" "Fixture.Mod" "name" "Fixture" "version" "1.0" }'
    Expand-ModPackage $zipPath (Join-Path $sandbox 'valid')
    Assert (Test-Path (Join-Path $sandbox 'valid/Wrapped/mod.vdf')) 'Wrapped ZIP extraction'
    $savedDownload = (Get-Item function:Save-ModPackage).ScriptBlock
    function Save-ModPackage([string]$Url,[string]$Path,$Progress) { [IO.File]::Copy($zipPath,$Path) }
    $entry = [pscustomobject]@{Build='R5Reloaded S3';InstallKind='zip';ModId='Fixture.Mod';Name='Fixture';Version='1.0';DownloadUrl='https://example.org/mod.zip';Sha256=''}
    $prepared = Prepare-CatalogPackage $entry (Join-Path $sandbox 'stage-valid') @{} $sandbox
    Assert ((Read-ModVdf (Join-Path $prepared.Path 'mod.vdf')).Id -eq 'Fixture.Mod') 'Package preparation validates the mod manifest'
    $entry.ModId = 'Wrong.Id'
    Assert-Throws { Prepare-CatalogPackage $entry (Join-Path $sandbox 'stage-wrong') @{} $sandbox } 'Mismatched package ID rejected'
    $entry.ModId = 'Fixture.Mod'; $entry.Version='2.0'
    Assert-Throws { Prepare-CatalogPackage $entry (Join-Path $sandbox 'stage-version') @{} $sandbox } 'Mismatched package version rejected'
    $entry.Build='Flowstate S21'
    Assert-Throws { Prepare-CatalogPackage $entry (Join-Path $sandbox 'stage-build') @{} $sandbox } 'Wrong game build rejected'
    Set-Item function:Save-ModPackage $savedDownload
    $script:GameDir = Join-Path $sandbox 'game'
    $script:ModsDir = Join-Path $script:GameDir 'mods'
    $script:ModListPath = Join-Path $script:ModsDir 'mods.vdf'
    $script:ModListRoot = 'ModList'; $script:ModState = [ordered]@{}
    Make-Mod (Join-Path $script:ModsDir 'owner') 'Owner.Mod'
    Make-Mod (Join-Path $script:ModsDir 'client') 'Client.Mod'
    [IO.File]::WriteAllText((Join-Path $script:ModsDir 'client/asset.rpak'), ('"needed"' + ('x' * 16MB)))
    Scan-Mods
    $script:ConVarCache = @{'Owner.Mod'=@('needed')}; $Catalog=@()
    Analyze-Mods
    Assert (@(($script:Mods | Where-Object Id -eq 'Client.Mod').Dependencies).Count -eq 0) 'Binary assets excluded from dependency scanning'
    [IO.File]::WriteAllText((Join-Path $script:ModsDir 'client/code.gnut'), 'GetConVarInt("needed")')
    Analyze-Mods
    Assert (($script:Mods | Where-Object Id -eq 'Client.Mod').Dependencies -contains 'Owner.Mod') 'Squirrel dependency detected'
    $stage = Join-Path $script:GameDir '.r5mm-stage-fixture'
    Make-Mod (Join-Path $stage 'Fixture.Mod') 'Fixture.Mod'
    Install-Paths @((Join-Path $stage 'Fixture.Mod')) -MoveStaged
    Assert (Test-Path (Join-Path $script:ModsDir 'Fixture.Mod/mod.vdf')) 'Prepared package installed through existing installer'
    Assert ($script:LastInstalledIds -contains 'Fixture.Mod') 'Successful install reported for receipt tracking'
    Assert ($script:ModState['Fixture.Mod'] -eq '1') 'Installed mod enabled in mods.vdf'
    Scan-Mods
    Make-Mod (Join-Path $stage 'Fixture.Mod') 'Fixture.Mod' '2.0'
    $script:Approve=$false
    Install-Paths @((Join-Path $stage 'Fixture.Mod')) -MoveStaged
    Assert ((Read-ModVdf (Join-Path $script:ModsDir 'Fixture.Mod/mod.vdf')).Version -eq '1.0') 'Replacement decline preserves the installed mod'
    $script:Approve=$true
    Install-Paths @((Join-Path $stage 'Fixture.Mod')) -MoveStaged
    Assert ((Read-ModVdf (Join-Path $script:ModsDir 'Fixture.Mod/mod.vdf')).Version -eq '2.0') 'Confirmed replacement installs the new version'
    Assert (@(Get-ChildItem $sandbox -Directory -Filter 'recycled-*').Count -eq 1) 'Replaced mod retained for recovery'
    Scan-Mods
    Make-Mod (Join-Path $sandbox 'copy-source') 'Fixture.Mod' '3.0'
    function Copy-Item { throw 'Simulated copy failure' }
    Install-Paths @((Join-Path $sandbox 'copy-source'))
    Remove-Item function:Copy-Item
    Assert ((Read-ModVdf (Join-Path $script:ModsDir 'Fixture.Mod/mod.vdf')).Version -eq '2.0') 'Failed replacement rolls back the previous mod'
    Assert-Throws { Remove-PackageStage $sandbox $script:GameDir } 'Staging cleanup cannot escape its parent'
    $feedDir = Join-Path $sandbox 'feeds'; [void][IO.Directory]::CreateDirectory($feedDir)
    Write-CatalogJson (Join-Path $feedDir 'sources.json') @{schemaVersion=1;sources=@(@{id='fixture';name='Fixture';type='feed';path='mods.json'})}
    Write-CatalogJson (Join-Path $feedDir 'mods.json') @{schemaVersion=1;mods=@(@{id='One';name='One';build='Community';pageUrl='https://example.org';installKind='manual'})}
    $feedCache = Join-Path $sandbox 'feed-cache'
    $result = Sync-ModCatalog $feedDir $feedCache $true
    Assert ($result.Items.Count -eq 1) 'Maintained feed indexed'
    [IO.File]::WriteAllText((Join-Path $feedDir 'mods.json'), '{invalid')
    $result = Sync-ModCatalog $feedDir $feedCache $true
    Assert ($result.Items.Count -eq 1 -and $result.Sources[0].State -eq 'Cached') 'Failed refresh preserves last successful listings'
    Write-CatalogJson (Join-Path $feedDir 'mods.json') @{schemaVersion=1;mods=@()}
    $result = Sync-ModCatalog $feedDir $feedCache $true
    Assert ($result.Items.Count -eq 0) 'Removed listings disappear after successful synchronization'
    [IO.File]::WriteAllText((Join-Path $feedDir 'mods.json'), '{invalid')
    $result = Sync-ModCatalog $feedDir (Join-Path $sandbox 'empty-cache') $true
    Assert ($result.Items.Count -eq 0 -and $result.Sources[0].Count -eq 0 -and $result.Sources[0].State -eq 'Unavailable') 'First-source failure reports zero listings'
    if ($Live) {
        $result = Sync-ModCatalog (Join-Path $root 'catalog') (Join-Path $sandbox 'live-cache') $true
        Assert (@($result.Sources | Where-Object State -ne 'Current').Count -eq 0) 'Live source synchronization'
        Assert (@($result.Items | Where-Object Build -eq 'R5Reloaded S3').Count -ge 5) 'Official GitHub mods indexed'
        Assert (@($result.Items | Where-Object Build -eq 'Flowstate S21').Count -gt 0) 'Thunderstore catalog indexed'
        $entry = $result.Items | Where-Object ModId -eq 'movementgym' | Select-Object -First 1
        $prepared = Prepare-CatalogPackage $entry (Join-Path $sandbox 'live-package') @{} (Join-Path $sandbox 'live-cache')
        Assert ((Read-ModVdf (Join-Path $prepared.Path 'mod.vdf')).Id -eq 'movementgym') 'Live pinned GitHub package downloaded and verified'
        Install-Paths @($prepared.Path) -MoveStaged
        Assert ((Test-Path (Join-Path $script:ModsDir 'movementgym/mod.vdf')) -and $script:ModState['movementgym'] -eq '1') 'Live catalog package installed into the isolated game'
    }
    Write-Output ($script:Passed.ToString() + ' checks passed.')
} finally {
    $full = [IO.Path]::GetFullPath($sandbox)
    if ($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -like 'r5mm-tests-*') {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
