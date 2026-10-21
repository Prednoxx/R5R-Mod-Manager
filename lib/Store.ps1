$script:StoreItems = @()
$script:StoreSources = @()
$script:StoreJob = $null
$script:PackageJob = $null
$script:PackageQueue = New-Object System.Collections.Queue
$script:StoreFilterLoading = $false
$script:StoreMode = $true
$script:ActiveView = 'store'
$script:StoreCache = Join-Path $SettingsDir 'catalog'
$script:StoreReceipts = Read-CatalogJson (Join-Path $SettingsDir 'installed-packages.json')
if (-not $script:StoreReceipts) { $script:StoreReceipts = [pscustomobject]@{} }

function Show-AppView([bool]$Store) {
    $script:StoreMode=$Store
    $script:ActiveView=if($Store){'store'}else{'library'}
    $UtilityView.Visibility='Collapsed'
    $StoreView.Visibility=if($Store){'Visible'}else{'Collapsed'}
    $LibraryView.Visibility=if($Store){'Collapsed'}else{'Visible'}
    $Mascot.Visibility='Collapsed'
    Set-NavActive $(if($Store){'store'}else{'library'})
}

function Set-StoreFilters {
    $script:StoreFilterLoading = $true
    try {
        foreach ($pair in @(@($StoreBuild,'All builds','Build'), @($StoreSourceFilter,'All sources','Source'), @($StoreCategory,'All categories','Category'))) {
            $control = $pair[0]; $selected = [string]$control.SelectedItem
            $control.Items.Clear(); [void]$control.Items.Add($pair[1])
            $values = @($script:StoreItems | ForEach-Object { $_.($pair[2]) } | Where-Object { $_ } | Sort-Object -Unique)
            foreach ($value in $values) { [void]$control.Items.Add($value) }
            $control.SelectedIndex = 0
            if ($selected -and $control.Items.Contains($selected)) { $control.SelectedItem = $selected }
        }
    } finally { $script:StoreFilterLoading = $false }
}

function Get-StoreStatus($Entry) {
    if ($Entry.Build -ne 'R5Reloaded S3') { return $Entry.Build }
    $installed = Get-ModById $Entry.ModId
    if (-not $installed) { if ($Entry.InstallKind -eq 'manual') { return 'Manual install' }; return 'Available' }
    if ($Entry.Version -and $installed.Version) {
        $remoteVersion = $null; $localVersion = $null
        if ([version]::TryParse($Entry.Version,[ref]$remoteVersion) -and [version]::TryParse($installed.Version,[ref]$localVersion)) {
            if ($remoteVersion -gt $localVersion) { return 'Update available' }
            if ($remoteVersion -lt $localVersion) { return 'Newer installed' }
        } elseif ($Entry.Version -ne $installed.Version) { return 'Different version' }
    }
    $receipt = $script:StoreReceipts.PSObject.Properties[$Entry.ModId]
    if ($receipt -and $receipt.Value.GameDir -eq $script:GameDir -and $receipt.Value.Key -eq $Entry.Key -and $Entry.Commit -and $receipt.Value.Commit -ne $Entry.Commit) { return 'Update available' }
    return 'Installed'
}

function Fill-Store {
    if ($script:StoreFilterLoading) { return }
    $keep = if ($StoreList.SelectedItem) { $StoreList.SelectedItem.Key } else { '' }
    $query = $StoreSearch.Text.Trim()
    $rows = @()
    foreach ($entry in $script:StoreItems) {
        if ($StoreBuild.SelectedIndex -gt 0 -and $entry.Build -ne [string]$StoreBuild.SelectedItem) { continue }
        if ($StoreSourceFilter.SelectedIndex -gt 0 -and $entry.Source -ne [string]$StoreSourceFilter.SelectedItem) { continue }
        if ($StoreCategory.SelectedIndex -gt 0 -and $entry.Category -ne [string]$StoreCategory.SelectedItem) { continue }
        if ($StoreFavoritesOnly.IsChecked -and $script:FavoriteKeys -notcontains $entry.Key) { continue }
        $hay = $entry.Name + ' ' + $entry.Author + ' ' + $entry.Description + ' ' + $entry.ModId
        if ($query -and $hay.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $previewPath=Get-PreviewPath $entry $script:StoreCache
        $stats=if($entry.Downloads -gt 0){'{0:N0} downloads' -f $entry.Downloads}else{$entry.Source}
        $rows += New-Object R5MM.CatalogCard -Property @{Key=$entry.Key; Name=$entry.Name; Author=$entry.Author; AuthorLabel=('By '+$entry.Author); Description=$entry.Description; Source=$entry.Source; Build=$entry.Build; Category=$entry.Category; Status=(Get-StoreStatus $entry); Entry=$entry; PreviewPath=$previewPath; Stats=$stats; CanInstall=($entry.Build -eq 'R5Reloaded S3' -and $entry.InstallKind -ne 'manual' -and -not $script:PackageJob -and -not $script:ModScan)}
    }
    switch ([string]$StoreSort.SelectedItem) {
        'Recently updated' { $rows = @($rows | Sort-Object { $_.Entry.Updated } -Descending) }
        'Most downloaded' { $rows = @($rows | Sort-Object { $_.Entry.Downloads } -Descending) }
        'Installed first' { $rows = @($rows | Sort-Object @{Expression={ if($_.Status -in @('Installed','Update available','Newer installed')){0}else{1} }},Name) }
        default { $rows = @($rows | Sort-Object Name,Author) }
    }
    $StoreList.ItemsSource = $rows
    $noun = if ($rows.Count -eq 1) { 'mod' } else { 'mods' }
    $StoreCount.Text = '{0} {1}  /  {2} in catalog' -f $rows.Count,$noun,$script:StoreItems.Count
    $StoreEmpty.Text = if ($script:StoreItems.Count -eq 0) { 'No catalog available. Refresh to retry.' } else { 'No matching mods' }
    $StoreEmpty.Visibility = if ($rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $selection = $rows | Where-Object { $_.Key -eq $keep } | Select-Object -First 1
    if (-not $selection) { $selection = $rows | Select-Object -First 1 }
    $StoreList.SelectedItem = $selection
    Show-StoreDetails
}

function Show-StoreDetails {
    if (-not $script:DetailKey) { return }
    $entry=Get-StoreEntry
    if (-not $entry) { return }
    $StoreDetailName.Text = $entry.Name
    $StoreDetailAuthor.Text = $entry.Author
    $StoreDetailCategory.Text=$entry.Category
    $StoreDetailSource.Text=$entry.Source
    $StoreDetailVersion.Text=if($entry.Version){$entry.Version}else{'Unspecified'}
    $StoreDetailDownloads.Text=if($entry.Downloads -gt 0){'{0:N0}' -f $entry.Downloads}else{'Unavailable'}
    $previewPath=Get-PreviewPath $entry $script:StoreCache
    $StoreHero.Source=if($previewPath){Load-Bitmap $previewPath 1200}else{$null}
    $status=Get-StoreStatus $entry
    $meta = @($entry.Build)
    if ($status -ne $entry.Build) { $meta += $status }
    if ($entry.Size -gt 0) { $meta += ('{0:N1} MB' -f ($entry.Size / 1MB)) }
    if ($entry.Updated) { try { $meta += 'Updated ' + ([DateTime]::Parse($entry.Updated).ToString('MMM d, yyyy')) } catch {} }
    $StoreDetailMeta.Text = $meta -join '  ·  '

    $StoreDetailDependencies.Text = if ($entry.Dependencies.Count -gt 0) { 'Dependencies: ' + ($entry.Dependencies -join ', ') } else { '' }
    $BtnStoreFavorite.Content=if($script:FavoriteKeys -contains $entry.Key){'★ Favorited'}else{'☆ Favorite'}
    $BtnStoreInstall.IsEnabled = $false
    $BtnStoreInstall.Content = 'Install'
    if ($entry.Build -ne 'R5Reloaded S3') {
        $StoreCompatibility.Text = 'Requires ' + $entry.Build + '. The selected game uses R5Reloaded S3.'
        $BtnStoreInstall.Content = 'Different game build'
    } elseif ($entry.InstallKind -eq 'manual') {
        $StoreCompatibility.Text = 'Follow the installation instructions on the source page.'
        $BtnStoreInstall.Content = 'Manual installation'
    } else {
        $StoreCompatibility.Text = 'Installs to the selected R5Reloaded mods folder. Existing copies require replacement confirmation.'
        $BtnStoreInstall.Content = switch ($status) { 'Update available' {'Update'} 'Installed' {'Reinstall'} 'Newer installed' {'Install older version'} 'Different version' {'Change version'} default {'Install'} }
        $BtnStoreInstall.IsEnabled = -not $script:PackageJob -and -not $script:ModScan -and -not $script:DlJob
    }
}

function Read-StoreCache {
    $config = Read-CatalogJson (Join-Path $AppDir 'catalog/sources.json')
    $seen = @{}
    foreach ($source in @($config.sources)) {
        $snapshot = Read-CatalogJson (Join-Path $script:StoreCache ($source.id + '.json'))
        if ($snapshot -and $snapshot.schemaVersion -eq 1) {
            foreach ($entry in @($snapshot.items)) {
                $identity = if ($entry.ModId) { $entry.Build + ':' + $entry.ModId } else { $entry.Key }
                if (-not $seen.ContainsKey($identity)) { $seen[$identity] = $true; $script:StoreItems += $entry }
            }
        }
    }
    Set-StoreFilters
    Fill-Store
}

function Start-StoreSync([bool]$Force = $false) {
    if ($script:StoreJob) { return }
    $progress = [hashtable]::Synchronized(@{Text='Updating catalog'})
    $ps = [powershell]::Create()
    $code = "param(`$Code,`$Directory,`$Cache,`$Force,`$Progress) `$ErrorActionPreference='Stop'; . ([scriptblock]::Create(`$Code)); Sync-ModCatalog `$Directory `$Cache `$Force `$Progress"
    [void]$ps.AddScript($code).AddArgument([IO.File]::ReadAllText((Join-Path $AppDir 'lib/Catalog.ps1'))).AddArgument((Join-Path $AppDir 'catalog')).AddArgument($script:StoreCache).AddArgument($Force).AddArgument($progress)
    $script:StoreJob = @{PS=$ps;Handle=$ps.BeginInvoke();Progress=$progress}
    $BtnStoreRefresh.IsEnabled = $false
    $storeTimer.Start()
}

function Start-StoreInstall($EntryOverride = $null) {
    $row = $StoreList.SelectedItem
    if ((-not $row -and -not $EntryOverride) -or $script:PackageJob -or $script:ModScan -or $script:DlJob) { return }
    if (-not (Require-Game)) { return }
    if (Test-GameRunning) { Set-Status 'Close R5Reloaded before installing mods.' 'warn'; $StoreProgressText.Text = 'Close R5Reloaded before installing mods.'; return }
    $entry = if ($EntryOverride) { $EntryOverride } else { Get-StoreEntry }
    if ($entry.Build -ne 'R5Reloaded S3' -or $entry.InstallKind -eq 'manual') { return }
    foreach ($dependency in @($entry.Dependencies)) {
        if (-not (Get-ModById $dependency)) { [void](Show-Dialog 'Missing dependency' ('Install ' + $dependency + ' before installing this mod.') 'OK' '' 'warn'); return }
    }
    $stage = Join-Path $script:GameDir ('.r5mm-stage-' + [guid]::NewGuid().ToString('N'))
    $progress = [hashtable]::Synchronized(@{Text='Preparing download';Bytes=[long]0;Total=[long]0})
    $code = "param(`$Library,`$Entry,`$Stage,`$Progress,`$Cache) `$ErrorActionPreference='Stop'; . ([scriptblock]::Create(`$Library)); Prepare-CatalogPackage `$Entry `$Stage `$Progress `$Cache"
    $library = [IO.File]::ReadAllText((Join-Path $AppDir 'lib/Catalog.ps1')) + "`n" + [IO.File]::ReadAllText((Join-Path $AppDir 'lib/Packages.ps1'))
    foreach ($name in @('ConvertFrom-Vdf','Get-VdfString','Read-ModVdf')) { $library += "`nfunction $name {" + (Get-Item "function:$name").Definition + "}`n" }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($code).AddArgument($library).AddArgument($entry).AddArgument($stage).AddArgument($progress).AddArgument($script:StoreCache)
    $script:PackageJob = @{PS=$ps;Handle=$ps.BeginInvoke();Stage=$stage;Progress=$progress;Entry=$entry;GameDir=$script:GameDir;Cancelled=$false}
    $StoreProgress.Visibility = 'Visible'; $StoreProgress.IsIndeterminate = $true
    $BtnStoreCancel.Visibility = 'Visible'; $BtnStoreInstall.IsEnabled = $false
    $storeTimer.Start()
}

$storeTimer = New-Object System.Windows.Threading.DispatcherTimer
$storeTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$storeTimer.Add_Tick({
    if ($script:StoreTickActive) { return }
    $script:StoreTickActive = $true
    try {
    if ($script:StoreJob) {
        $job = $script:StoreJob
        $StoreSyncText.Text = $job.Progress.Text
        if ($job.Handle.IsCompleted) {
            try {
                $result = @($job.PS.EndInvoke($job.Handle))
                if ($job.PS.HadErrors) { throw $job.PS.Streams.Error[0] }
                $script:StoreItems = @($result[-1].Items); $script:StoreSources = @($result[-1].Sources)
                Set-StoreFilters; Fill-Store
                Start-CatalogImages
                $failed = @($script:StoreSources | Where-Object { $_.State -ne 'Current' })
                $StoreSyncText.Text = if ($failed.Count) { $failed.Count.ToString() + ' sources unavailable' } else { 'Catalog current' }
                $StoreSyncText.ToolTip = ($script:StoreSources | ForEach-Object { $_.Name + ': ' + $_.State + $(if($_.Error){' - '+$_.Error}) }) -join "`n"
            } catch { Write-Log ('Catalog: ' + $_); $StoreSyncText.Text = 'Catalog unavailable. Refresh to retry.' }
            finally { $job.PS.Dispose(); $script:StoreJob = $null; $BtnStoreRefresh.IsEnabled = $true }
        }
    }
    if ($script:PackageJob) {
        $job = $script:PackageJob
        $StoreProgressText.Text = $job.Progress.Text
        $DownloadName.Text=$job.Entry.Name
        $DownloadStatus.Text=$job.Progress.Text
        $DownloadProgress.Visibility='Visible'; $BtnDownloadCancel.IsEnabled=$true
        if ($job.Progress.Total -gt 0) {
            $StoreProgress.IsIndeterminate = $false
            $StoreProgress.Value = [Math]::Min(100,100.0 * $job.Progress.Bytes / $job.Progress.Total)
            $StoreProgressText.Text += ('  {0:N1} / {1:N1} MB' -f ($job.Progress.Bytes/1MB),($job.Progress.Total/1MB))
        }
        $DownloadProgress.IsIndeterminate=$StoreProgress.IsIndeterminate; $DownloadProgress.Value=$StoreProgress.Value
        if ($job.Handle.IsCompleted) {
            $script:PackageJob = $null
            try {
                if ($job.Cancelled) { $StoreProgressText.Text = 'Download cancelled'; return }
                $result = @($job.PS.EndInvoke($job.Handle))
                if ($job.PS.HadErrors) { throw $job.PS.Streams.Error[0] }
                if ($job.GameDir -ne $script:GameDir) { throw 'The game folder changed. Select the mod again to install.' }
                if (Test-GameRunning) { throw 'Close R5Reloaded before installing mods.' }
                if ($script:ModScan -or $script:DlJob) { throw 'A mod operation is still running. Select the mod again to install.' }
                Install-Paths @($result[-1].Path) -MoveStaged
                if ($script:LastInstalledIds -contains $job.Entry.ModId) {
                    $receipt = [pscustomobject]@{Key=$job.Entry.Key; GameDir=$script:GameDir; Version=$job.Entry.Version; Commit=$job.Entry.Commit; Installed=[DateTime]::UtcNow.ToString('o')}
                    $script:StoreReceipts | Add-Member -NotePropertyName $job.Entry.ModId -NotePropertyValue $receipt -Force
                    Write-CatalogJson (Join-Path $SettingsDir 'installed-packages.json') $script:StoreReceipts
                    $StoreProgressText.Text = 'Installed ' + $job.Entry.Name
                } else { $StoreProgressText.Text = 'Installation skipped' }
            } catch { Write-Log ('Package: ' + $_); $StoreProgressText.Text = 'Installation failed'; [void](Show-Dialog 'Installation failed' $_.Exception.Message 'OK' '' 'warn') }
            finally {
                $job.PS.Dispose()
                try { Remove-PackageStage $job.Stage $job.GameDir } catch { Write-Log ('Package cleanup: ' + $_) }
                $StoreProgress.Visibility = 'Collapsed'; $BtnStoreCancel.Visibility = 'Collapsed'
                $script:DownloadEvents=@((Get-Date -Format 'HH:mm')+'  '+$job.Entry.Name+'  —  '+$StoreProgressText.Text)+$script:DownloadEvents
                $DownloadHistory.Text=$script:DownloadEvents -join "`n"
                $DownloadName.Text='No active downloads'; $DownloadStatus.Text=$StoreProgressText.Text; $DownloadProgress.Visibility='Collapsed'; $BtnDownloadCancel.IsEnabled=$false
                Fill-Store
            }
        }
    }
    if (-not $script:StoreJob -and -not $script:PackageJob -and $script:PackageQueue.Count -eq 0) { $storeTimer.Stop() }
    if ($script:PackageQueue.Count -gt 0 -and -not $script:PackageJob -and -not $script:ModScan) {
        Start-StoreInstall ($script:PackageQueue.Dequeue())
    }
    } finally { $script:StoreTickActive = $false }
})

$storeRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$storeRefreshTimer.Interval = [TimeSpan]::FromMinutes(5)
$storeRefreshTimer.Add_Tick({ Start-StoreSync })
$BtnNavStore.Add_Click({ Show-AppView $true })
$BtnNavLibrary.Add_Click({ Show-AppView $false })
$BtnStoreRefresh.Add_Click({ Start-StoreSync $true })
$BtnStoreInstall.Add_Click({ Invoke-Safe { Start-StoreInstall } })
$BtnStoreCancel.Add_Click({
    if ($script:PackageJob -and -not $script:PackageJob.Cancelled) {
        $script:PackageJob.Cancelled = $true
        $script:PackageQueue.Clear()
        $script:PackageJob.Progress.Text = 'Cancelling download'
        [void]$script:PackageJob.PS.BeginStop($null,$null)
    }
})
$BtnStorePage.Add_Click({ $entry=Get-StoreEntry; if ($entry -and (Test-CatalogUrl $entry.PageUrl)) { Start-Process $entry.PageUrl } })
$BtnStoreSources.Add_Click({
    $text = ($script:StoreSources | ForEach-Object { $_.Name + ' - ' + $_.State + ' (' + $_.Count + ' listings)' + $(if($_.Error){"`n"+$_.Error}) }) -join "`n`n"
    if (-not $text) { $text = 'Sources are loading.' }
    [void](Show-Dialog 'Catalog sources' $text 'OK')
})
$StoreSearch.Add_TextChanged({ Invoke-Safe { Fill-Store } })
foreach ($control in @($StoreBuild,$StoreSourceFilter,$StoreCategory,$StoreSort)) { $control.Add_SelectionChanged({ Invoke-Safe { Fill-Store } }) }
$StoreList.Add_SelectionChanged({ Invoke-Safe { Show-StoreDetails } })
foreach ($label in @('Name','Recently updated','Most downloaded','Installed first')) { [void]$StoreSort.Items.Add($label) }
$StoreSort.SelectedIndex = 0

