# Usage scenarios run from run.ps1 in its temporary game sandbox.
$usageDir = Join-Path $sandbox 'usage'
[void][IO.Directory]::CreateDirectory($usageDir)
function Import-UsageFunction([string]$File, [string]$Name) {
    $errors = $null
    $source = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $File), [ref]$null, [ref]$errors)
    if ($errors) { throw ('Invalid script: ' + $File) }
    $definition = $source.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true) | Where-Object Name -eq $Name | Select-Object -First 1
    if (-not $definition) { throw ('Function not found: ' + $Name) }
    . ([scriptblock]::Create($definition.Extent.Text.Replace('function '+$Name, 'function script:'+$Name)))
}
foreach ($name in @('Get-StoreCategories','Set-StoreFilters','Get-StoreStatus','Fill-Store','Show-StoreDetails','Start-StoreInstall')) { Import-UsageFunction 'lib/Store.ps1' $name }
foreach ($name in @('Get-StoreEntry','Set-NavActive')) { Import-UsageFunction 'lib/StoreMedia.ps1' $name }
. (Join-Path $root 'lib/Media.ps1')
foreach ($name in @('Fit-StartupWindow','Set-GameDir','Test-GameDir','Resolve-GameDir','Get-ModById','Set-AllEnabled','Get-StateSnapshot','Get-PresetDiff','Apply-Preset','Load-ModState')) { Import-AppFunction $name }
function Test-GameRunning { return $false }
function Save-Settings {}
function Show-Details {}
function Update-Issues {}
function Update-Count {}
function Load-Bitmap { return $null }

$window = New-Object Windows.Window -Property @{Width=1280;Height=780;MinWidth=1120;MinHeight=640}
Fit-StartupWindow $window (New-Object Windows.Rect(0,0,1280,700))
Assert ($window.Height -le 700 -and $window.Top -ge 0 -and ($window.Top+$window.Height) -le 700) 'Startup window keeps its title bar and bottom edge inside the work area'
Assert ($window.Width -le 1280 -and $window.Left -ge 0) 'Startup window fits the available desktop width'

foreach ($name in @('StoreSearch')) { Set-Variable $name (New-Object Windows.Controls.TextBox) -Scope Script }
foreach ($name in @('StoreBuild','StoreSourceFilter','StoreCategory','StoreSort')) { Set-Variable $name (New-Object Windows.Controls.ComboBox) -Scope Script }
foreach ($name in @('StoreCount','StoreEmpty','StoreDetailName','StoreDetailAuthor','StoreDetailCategory','StoreDetailSource','StoreDetailVersion','StoreDetailDownloads','StoreDetailMeta','StoreDetailDependencies','StoreCompatibility','StoreProgressText','DownloadName','DownloadStatus','DownloadHistory','GamePath','SettingsGamePath','SidebarGameStatus')) { Set-Variable $name (New-Object Windows.Controls.TextBlock) -Scope Script }
foreach ($name in @('BtnStoreFavorite','BtnStoreInstall','BtnStoreCancel','BtnDownloadCancel','BtnNavStore','BtnNavLibrary','BtnNavDownloads','BtnNavSettings')) { Set-Variable $name (New-Object Windows.Controls.Button) -Scope Script }
$StoreList = New-Object Windows.Controls.ListBox
$StoreFavoritesOnly = New-Object Windows.Controls.CheckBox
$StoreHero = New-Object Windows.Controls.Image
$StoreProgress = New-Object Windows.Controls.ProgressBar
$DownloadProgress = New-Object Windows.Controls.ProgressBar
$script:Mods = New-Object 'System.Collections.Generic.List[R5MM.ModItem]'
$script:FavoriteKeys = @(); $script:DetailKey = ''; $script:DownloadEvents = @()
$script:StoreCache = Join-Path $usageDir 'cache'
$script:StoreReceipts = [pscustomobject]@{}
$script:GameDir = ''; $script:PackageJob = $null; $script:DlJob = $null
$source = [pscustomobject]@{id='usage';name='Usage fixtures'}
$script:StoreItems = @(foreach ($item in @(
    @{id='City';name='City';category='Gamemode, Map';downloads=10},
    @{id='Coast';name='Coast';category='Map';downloads=20},
    @{id='Knife';name='Knife';category='Model, Weapon';downloads=30}
)) {
    $item.modId=$item.id; $item.author='Publisher'; $item.build='R5Reloaded S3'; $item.installKind='zip'; $item.pageUrl='https://example.org/mod'; $item.downloadUrl='https://example.org/mod.zip'; $item.version='1.0'
    New-CatalogEntry $source ([pscustomobject]$item)
})
[void]$StoreSort.Items.Add('Name'); [void]$StoreSort.Items.Add('Most downloaded'); $StoreSort.SelectedIndex=0
Set-StoreFilters
Assert ($StoreCategory.Items.Contains('Map') -and $StoreCategory.Items.Contains('Gamemode') -and -not $StoreCategory.Items.Contains('Gamemode, Map')) 'Categories expose individual tags from multi-category mods'
$StoreCategory.SelectedItem='Map'; Fill-Store
Assert (@($StoreList.ItemsSource).Count -eq 2) 'Map filter includes mods also tagged with a gamemode'
$StoreSearch.Text='CITY'; Fill-Store
Assert (@($StoreList.ItemsSource).Count -eq 1 -and $StoreList.SelectedItem.Name -eq 'City') 'Search combines with category filters without case sensitivity'
$StoreSearch.Clear(); $StoreCategory.SelectedIndex=0
$script:FavoriteKeys=@('usage:Knife'); $StoreFavoritesOnly.IsChecked=$true; Fill-Store
Assert (@($StoreList.ItemsSource).Count -eq 1 -and $StoreList.SelectedItem.Name -eq 'Knife') 'Favorites restrict the store to saved listings'
$StoreFavoritesOnly.IsChecked=$false; $StoreSort.SelectedItem='Most downloaded'; Fill-Store
Assert ($StoreList.ItemsSource[0].Name -eq 'Knife') 'Most downloaded sorting places the largest count first'
$StoreCategory.SelectedItem='Map'; Set-StoreFilters
Assert ([string]$StoreCategory.SelectedItem -eq 'Map') 'Catalog refresh preserves the selected category'
$script:DetailKey='usage:City'; Show-StoreDetails
Assert ($BtnStoreInstall.Content -eq 'Choose game folder' -and $BtnStoreInstall.IsEnabled) 'First installation offers game-folder selection directly from the store'
$script:BrowseCount=0
function Browse-GameDir { $script:BrowseCount++ }
Start-StoreInstall $script:StoreItems[0]
Assert ($script:BrowseCount -eq 1 -and -not $script:PackageJob) 'Missing game folder opens selection without starting a download'
Remove-Item function:Browse-GameDir
$script:DetailKey=''

$gameA=Join-Path $usageDir 'game-a'; $gameB=Join-Path $usageDir 'game-b'
[void][IO.Directory]::CreateDirectory($gameA); [void][IO.Directory]::CreateDirectory($gameB)
[IO.File]::WriteAllText((Join-Path $gameA 'r5apex.exe'),'')
[IO.File]::WriteAllText((Join-Path $gameB 'r5apex.exe'),'')
Assert ((Resolve-GameDir (Join-Path $gameA 'mods')) -eq $gameA) 'Selecting a mods subfolder resolves to its game folder'
$script:Installs=New-Object 'System.Collections.Generic.List[string]'
$script:GameDir=$gameA; $script:PackageQueue.Enqueue($script:StoreItems[0])
Set-GameDir $gameA
Assert ($script:PackageQueue.Count -eq 1) 'Selecting the same game preserves queued downloads'
Set-GameDir $gameB
Assert ($script:PackageQueue.Count -eq 0 -and $script:ModsDir -eq (Join-Path $gameB 'mods')) 'Switching games clears downloads queued for the previous game'

foreach ($spec in @(@('Core',$true),@('Practice',$false),@('Cosmetic',$false))) {
    $mod=New-Object R5MM.ModItem -Property @{Id=$spec[0];Name=$spec[0];Enabled=$true;IsRequired=$spec[1]}
    $script:Mods.Add($mod)
}
$script:ModState=[ordered]@{Core='1';Practice='1';Cosmetic='1'}; $script:ModListRoot='ModList'
Set-AllEnabled $false
Assert ($script:Mods[0].Enabled -and -not $script:Mods[1].Enabled -and -not $script:Mods[2].Enabled) 'Disable all preserves required game mods'
$script:Mods[1].Enabled=$true
$script:Presets=[ordered]@{Practice=(Get-StateSnapshot)}
$script:Mods[1].Enabled=$false; $script:Mods[2].Enabled=$true
Assert (Get-PresetDiff 'Practice') 'Preset changes are detected before applying a saved configuration'
Apply-Preset 'Practice'
Assert ($script:Mods[0].Enabled -and $script:Mods[1].Enabled -and -not $script:Mods[2].Enabled -and -not (Get-PresetDiff 'Practice')) 'Preset restores the selected mod combination while preserving required mods'
Load-ModState
Assert ($script:ModState['Practice'] -eq '1' -and $script:ModState['Cosmetic'] -eq '0') 'Preset choices survive saving and reloading mods.vdf'

$localSource=Join-Path $usageDir 'local-mod'; Make-Mod $localSource 'Local.Mod'
function Test-GameRunning { return $true }
Install-Paths @($localSource)
Assert (-not (Test-Path -LiteralPath (Join-Path $script:ModsDir 'local-mod')) -and $script:LastInstalledIds.Count -eq 0) 'Local ZIP and folder installer does not modify a running game'
function Test-GameRunning { return $false }

$cancelAst=$storeAst.FindAll({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Expression.Extent.Text -eq '$BtnStoreCancel' -and $node.Member.Value -eq 'Add_Click'}, $true) | Select-Object -First 1
$cancel=$cancelAst.Arguments[0].ScriptBlock.GetScriptBlock()
$stage=Join-Path $gameB '.r5mm-stage-cancel'; [void][IO.Directory]::CreateDirectory($stage)
$worker=[pscustomobject]@{}
$worker | Add-Member ScriptMethod BeginStop { param($callback,$state) $script:StopRequested=$true }
$worker | Add-Member ScriptMethod EndInvoke { throw 'Cancelled downloads must not publish a package.' }
$worker | Add-Member ScriptMethod Dispose { $script:WorkerDisposed=$true }
$script:PackageJob=@{PS=$worker;Handle=[pscustomobject]@{IsCompleted=$true};Cancelled=$false;Stage=$stage;GameDir=$gameB;Entry=$script:StoreItems[0];Progress=@{Text='Downloading';Bytes=5;Total=10}}
$script:PackageQueue.Enqueue($script:StoreItems[1]); & $cancel
Assert ($script:StopRequested -and $script:PackageJob.Cancelled -and $script:PackageQueue.Count -eq 0) 'Cancellation stops the active worker and clears pending downloads'
& $script:TestStoreTick
Assert ($script:WorkerDisposed -and -not $script:PackageJob -and -not (Test-Path -LiteralPath $stage) -and $DownloadStatus.Text -eq 'Download cancelled') 'Cancelled downloads clean staging and record their final status'

$feedDir=Join-Path $usageDir 'feeds'; $feedCache=Join-Path $usageDir 'feed-cache'
[void][IO.Directory]::CreateDirectory($feedDir)
Write-CatalogJson (Join-Path $feedDir 'sources.json') @{schemaVersion=1;sources=@(@{id='one';name='One';type='feed';path='one.json'},@{id='two';name='Two';type='feed';path='two.json'})}
foreach ($name in @('one','two')) { Write-CatalogJson (Join-Path $feedDir ($name+'.json')) @{schemaVersion=1;mods=@(@{id=$name;name=$name;build='Community';pageUrl='https://example.org';installKind='manual'})} }
[void](Sync-ModCatalog $feedDir $feedCache $true)
[IO.File]::WriteAllText((Join-Path $feedDir 'one.json'),'{invalid')
Write-CatalogJson (Join-Path $feedDir 'two.json') @{schemaVersion=1;mods=@(@{id='new';name='Updated listing';build='Community';pageUrl='https://example.org';installKind='manual'})}
$mixed=Sync-ModCatalog $feedDir $feedCache $true
Assert ($mixed.Items.Name -contains 'one' -and $mixed.Items.Name -contains 'Updated listing' -and $mixed.Sources[0].State -eq 'Cached' -and $mixed.Sources[1].State -eq 'Current') 'One failed source retains cached listings while another source updates'
$cachedEntry=$script:StoreItems[0]; $cachedEntry.IconUrl='https://example.org/icon.png'
$imagePath=Join-Path $script:StoreCache ('images/'+(Get-MediaKey $cachedEntry.IconUrl)+'.img')
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $imagePath)); [IO.File]::Copy((Join-Path $root 'assets/icon.png'),$imagePath)
$detailPath=Join-Path $script:StoreCache ('details/'+(Get-MediaKey ($cachedEntry.Key+':'+$cachedEntry.Version+':'+$cachedEntry.Commit))+'.json')
Write-CatalogJson $detailPath @{Key=$cachedEntry.Key;Body='Cached mod description';Images=@($imagePath);Updated=[DateTime]::UtcNow.ToString('o')}
Assert ((Get-PreviewPath $cachedEntry $script:StoreCache) -eq $imagePath -and (Get-CatalogDetails $cachedEntry $script:StoreCache).Body -eq 'Cached mod description') 'Cached previews and mod details remain available without a source request'

$navPanel=New-Object Windows.Controls.StackPanel; $window.Content=$navPanel
foreach ($button in @($BtnNavStore,$BtnNavLibrary,$BtnNavDownloads,$BtnNavSettings)) { [void]$navPanel.Children.Add($button) }
$window.Resources['RowSel']=[Windows.Media.Brushes]::Red; $window.Resources['WindowBg']=[Windows.Media.Brushes]::Black
Set-NavActive 'store'
$window.Resources['RowSel']=[Windows.Media.Brushes]::Blue
Assert ($BtnNavStore.Background.Color -eq [Windows.Media.Colors]::Blue -and $BtnNavLibrary.Background.Color -eq [Windows.Media.Colors]::Black) 'Active navigation follows theme-resource changes'
