$script:MediaJob = $null
$script:DetailJob = $null
$script:DetailKey = ''
$script:PendingDetail = $null
$script:MediaQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:FavoriteKeys = @((Read-CatalogJson (Join-Path $SettingsDir 'favorites.json')).keys)
$script:DownloadEvents = @()

function Get-StoreEntry {
    if ($script:DetailKey) { return ($script:StoreItems | Where-Object Key -eq $script:DetailKey | Select-Object -First 1) }
    if ($StoreList.SelectedItem) { return $StoreList.SelectedItem.Entry }
}

function Set-NavActive([string]$Name) {
    foreach ($pair in @(@($BtnNavStore,'store'),@($BtnNavLibrary,'library'),@($BtnNavDownloads,'downloads'),@($BtnNavSettings,'settings'))) {
        $pair[0].Background = $window.FindResource($(if($pair[1] -eq $Name){'RowSel'}else{'WindowBg'}))
    }
}

function Show-Utility([string]$Page) {
    $script:StoreMode = $false
    $StoreView.Visibility = 'Collapsed'; $LibraryView.Visibility = 'Collapsed'; $UtilityView.Visibility = 'Visible'
    $SettingsView.Visibility = if ($Page -eq 'settings') { 'Visible' } else { 'Collapsed' }
    $DownloadsView.Visibility = if ($Page -eq 'downloads') { 'Visible' } else { 'Collapsed' }
    $SettingsGamePath.Text = if ($script:GameDir) { $script:GameDir } else { 'Not selected' }
    Set-NavActive $Page
}

function Open-StoreDetail($Entry) {
    if (-not $Entry) { return }
    $script:DetailKey = $Entry.Key
    $StoreBrowse.Visibility = 'Collapsed'; $StoreDetails.Visibility = 'Visible'
    $StoreDetails.ScrollToTop()
    Show-StoreDetails
    $StoreDetailDescription.Text = $Entry.Description
    $StoreGallery.ItemsSource = $null; $StoreGalleryWrap.Visibility = 'Collapsed'
    $script:PendingDetail = $Entry
    Start-DetailFetch
}

function Close-StoreDetail {
    $script:DetailKey = ''
    $StoreBrowse.Visibility = 'Visible'; $StoreDetails.Visibility = 'Collapsed'; $ImageOverlay.Visibility = 'Collapsed'
}

function Start-CatalogImages {
    if ($script:MediaJob) { return }
    $code = "param(`$Code,`$Items,`$Cache,`$Queue) . ([scriptblock]::Create(`$Code)); Sync-CatalogImages `$Items `$Cache `$Queue"
    $library = ''
    foreach ($file in @('Catalog.ps1','Packages.ps1','Media.ps1')) { $library += [IO.File]::ReadAllText((Join-Path $AppDir ('lib/'+$file))) + "`n" }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($code).AddArgument($library).AddArgument($script:StoreItems).AddArgument($script:StoreCache).AddArgument($script:MediaQueue)
    $script:MediaJob = @{PS=$ps;Handle=$ps.BeginInvoke()}
    $mediaTimer.Start()
}

function Start-DetailFetch {
    if ($script:DetailJob -or -not $script:PendingDetail) { return }
    $entry = $script:PendingDetail; $script:PendingDetail = $null
    $library = ''
    foreach ($file in @('Catalog.ps1','Packages.ps1','Media.ps1')) { $library += [IO.File]::ReadAllText((Join-Path $AppDir ('lib/'+$file))) + "`n" }
    $ps = [powershell]::Create()
    [void]$ps.AddScript("param(`$Code,`$Entry,`$Cache) `$ErrorActionPreference='Stop'; . ([scriptblock]::Create(`$Code)); Get-CatalogDetails `$Entry `$Cache").AddArgument($library).AddArgument($entry).AddArgument($script:StoreCache)
    $script:DetailJob = @{PS=$ps;Handle=$ps.BeginInvoke();Key=$entry.Key}
    $mediaTimer.Start()
}

$mediaTimer = New-Object System.Windows.Threading.DispatcherTimer
$mediaTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$mediaTimer.Add_Tick({
    try {
        $item=$null; $changed=$false
        while ($script:MediaQueue.TryDequeue([ref]$item)) {
            foreach ($row in @($StoreList.ItemsSource)) { if ($row.Key -eq $item.Key) { $row.PreviewPath = $item.Path; $changed=$true } }
            if ($item.Key -eq $script:DetailKey) { $StoreHero.Source = Load-Bitmap $item.Path 1200 }
        }
        if ($changed) { $StoreList.Items.Refresh() }
        if ($script:MediaJob -and $script:MediaJob.Handle.IsCompleted) {
            [void]$script:MediaJob.PS.EndInvoke($script:MediaJob.Handle)
            $script:MediaJob.PS.Dispose(); $script:MediaJob=$null
        }
        if ($script:DetailJob -and $script:DetailJob.Handle.IsCompleted) {
            $job=$script:DetailJob; $script:DetailJob=$null
            try {
                $result=@($job.PS.EndInvoke($job.Handle))
                if (-not $job.PS.HadErrors -and $result.Count -gt 0 -and $job.Key -eq $script:DetailKey) {
                    $details=$result[-1]
                    $StoreDetailDescription.Text = $details.Body
                    $images=@(foreach ($path in @($details.Images)) { if (Test-Path -LiteralPath $path) { Load-Bitmap $path 1200 } })
                    $StoreGallery.ItemsSource=[string[]]@($details.Images)
                    $StoreGalleryWrap.Visibility=if($images.Count -gt 0){'Visible'}else{'Collapsed'}
                    if ($images.Count -gt 0) { $StoreHero.Source=$images[0] }
                }
            } catch { Write-Log ('Mod details: '+$_) }
            finally { $job.PS.Dispose() }
            Start-DetailFetch
        }
    } catch { Write-Log ('Preview: '+$_) }
    if (-not $script:MediaJob -and -not $script:DetailJob) { $mediaTimer.Stop() }
})

$BtnNavDownloads.Add_Click({ Show-Utility 'downloads' })
$BtnNavSettings.Add_Click({ Show-Utility 'settings' })
$BtnSettingsGame.Add_Click({ Invoke-Safe { Browse-GameDir; $SettingsGamePath.Text=$script:GameDir } })
$BtnSettingsTheme.Add_Click({ Invoke-Safe { Show-ThemeMenu } })
foreach ($button in @($BtnSettingsSources,$BtnSidebarSources)) { $button.Add_Click({ $BtnStoreSources.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }) }
$BtnGlobalLaunch.Add_Click({ Invoke-Safe { Launch-Game } })
$BtnStoreBack.Add_Click({ Close-StoreDetail })
$BtnStoreClear.Add_Click({ $script:StoreFilterLoading=$true; $StoreSearch.Clear(); $StoreBuild.SelectedIndex=0; $StoreSourceFilter.SelectedIndex=0; $StoreCategory.SelectedIndex=0; $StoreFavoritesOnly.IsChecked=$false; $script:StoreFilterLoading=$false; Fill-Store })
$BtnStoreFavorite.Add_Click({
    $entry=Get-StoreEntry
    if (-not $entry) { return }
    if ($script:FavoriteKeys -contains $entry.Key) { $script:FavoriteKeys=@($script:FavoriteKeys | Where-Object {$_ -ne $entry.Key}) }
    else { $script:FavoriteKeys += $entry.Key }
    Write-CatalogJson (Join-Path $SettingsDir 'favorites.json') @{keys=@($script:FavoriteKeys | Where-Object {$_})}
    Fill-Store; Show-StoreDetails
})
$StoreFavoritesOnly.Add_Click({ Fill-Store })
$BtnImageClose.Add_Click({ $ImageOverlay.Visibility='Collapsed' })
$StoreGallery.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender,$event)
    $button=$event.OriginalSource
    while ($button -and $button -isnot [Windows.Controls.Button]) { $button=[Windows.Media.VisualTreeHelper]::GetParent($button) }
    if ($button -and $button.Tag -eq 'gallery') { $FullPreview.Source=Load-Bitmap ([string]$button.DataContext) 1600; $ImageOverlay.Visibility='Visible' }
})
$StoreList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{
    param($sender,$event)
    $button=$event.OriginalSource
    while ($button -and $button -isnot [Windows.Controls.Button]) { $button=[Windows.Media.VisualTreeHelper]::GetParent($button) }
    if (-not $button) { return }
    $row=$button.DataContext
    if ($button.Tag -eq 'details') { Open-StoreDetail $row.Entry }
    elseif ($button.Tag -eq 'install') { Invoke-Safe { Start-StoreInstall $row.Entry } }
    $event.Handled=$true
})
$StoreList.Add_KeyDown({param($sender,$event) if ($event.Key -eq 'Return' -and $StoreList.SelectedItem) { Open-StoreDetail $StoreList.SelectedItem.Entry; $event.Handled=$true }})
$StoreList.Add_SizeChanged({
    $available=$StoreList.ActualWidth-22
    if ($available -gt 0) { $columns=[Math]::Max(1,[Math]::Floor($available/235)); $window.Resources['StoreCardWidth']=[double]([Math]::Floor($available/$columns)-14) }
})
$BtnDownloadCancel.Add_Click({ $BtnStoreCancel.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) })
