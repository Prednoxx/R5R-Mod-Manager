# Catalog providers and persistent source snapshots. No window dependencies.
function Test-CatalogUrl([string]$Url) {
    $uri = $null
    return ([uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and -not $uri.UserInfo)
}

function Write-CatalogJson([string]$Path, $Value) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Read-CatalogJson([string]$Path) {
    if ([IO.File]::Exists($Path)) {
        try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { return $null }
    }
}

function Get-CatalogHttp([string]$Url, [string]$CacheDir, [bool]$Json = $true) {
    if (-not (Test-CatalogUrl $Url)) { throw 'The source URL must use HTTPS.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url))).Replace('-','') } finally { $hash.Dispose() }
    $path = Join-Path $CacheDir ('http/' + $key + '.json')
    $cached = Read-CatalogJson $path
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'R5R-Mod-Manager/3.2'
    $req.Timeout = 15000; $req.ReadWriteTimeout = 15000
    $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    if ($cached -and $cached.etag) { $req.Headers['If-None-Match'] = $cached.etag }
    $response = $null
    try {
        try { $response = $req.GetResponse() }
        catch [Net.WebException] {
            $errorResponse = $_.Exception.Response
            if ($errorResponse -and [int]$errorResponse.StatusCode -eq 304 -and $cached) {
                $errorResponse.Close()
                if ($Json) { return ($cached.body | ConvertFrom-Json) }
                return [string]$cached.body
            }
            if ($errorResponse) {
                $code = [int]$errorResponse.StatusCode
                $errorResponse.Close()
                if ($code -in @(403,429)) { throw 'Source rate limit reached. Cached listings remain available.' }
                throw ('Source returned HTTP ' + $code + '.')
            }
            throw 'Source unavailable. Cached listings remain available.'
        }
        if ($response.ResponseUri.Scheme -ne 'https') { throw 'An insecure source redirect was rejected.' }
        if ($response.ContentLength -gt 32MB) { throw 'The catalog exceeds the size limit.' }
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try {
            $builder = New-Object Text.StringBuilder
            $buffer = New-Object char[] 8192
            while (($count = $reader.Read($buffer,0,$buffer.Length)) -gt 0) {
                [void]$builder.Append($buffer,0,$count)
                if ($builder.Length -gt 32MB) { throw 'The catalog exceeds the size limit.' }
            }
            $body = $builder.ToString()
        } finally { $reader.Dispose() }
        $value = $body
        if ($Json) { $value = $body | ConvertFrom-Json }
        Write-CatalogJson $path @{etag=$response.Headers['ETag']; body=$body}
        return $value
    } finally { if ($response) { $response.Close() } }
}

function New-CatalogEntry($Source, $Item) {
    if (-not $Item.id -or -not $Item.name -or -not $Item.build) { throw 'A catalog listing is missing its ID, name or game build.' }
    if ([string]$Item.id -notmatch '^[A-Za-z0-9_.-]{1,100}$') { throw 'A catalog listing has an invalid ID.' }
    if (-not (Test-CatalogUrl $Item.pageUrl)) { throw 'A catalog listing has an invalid page URL.' }
    $kind = [string]$Item.installKind
    if (-not $kind) { $kind = 'manual' }
    if ($kind -notin @('manual','zip','github-directory')) { throw 'Unsupported catalog package type.' }
    if ($kind -ne 'manual') {
        if (-not $Item.modId -or [string]$Item.modId -notmatch '^[A-Za-z0-9_.-]{1,100}$') { throw 'An installable listing requires a valid mod ID.' }
        if (-not (Test-CatalogUrl $Item.downloadUrl)) { throw 'An installable listing requires an HTTPS package URL.' }
    }
    if ($kind -eq 'github-directory') {
        if ($Item.repository -notmatch '^[\w.-]+/[\w.-]+$' -or $Item.commit -notmatch '^[a-f0-9]{40}$' -or
            $Item.packagePath -notmatch '^[\w./-]+$' -or $Item.packagePath -match '(^|/)\.\.(/|$)') { throw 'Invalid GitHub package location.' }
    }
    if ($Item.sha256 -and $Item.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid package checksum.' }
    [pscustomobject]@{
        Key=([string]$Source.id + ':' + [string]$Item.id); Id=[string]$Item.id; ModId=[string]$Item.modId
        Name=[string]$Item.name; Author=[string]$Item.author; Description=[string]$Item.description
        Version=[string]$Item.version; Category=[string]$Item.category; Build=[string]$Item.build
        SourceId=[string]$Source.id; Source=[string]$Source.name; PageUrl=[string]$Item.pageUrl
        DownloadUrl=[string]$Item.downloadUrl; InstallKind=$kind; Sha256=[string]$Item.sha256
        Repository=[string]$Item.repository; Commit=[string]$Item.commit; PackagePath=[string]$Item.packagePath
        Updated=[string]$Item.updated; Downloads=[long]$Item.downloads; Size=[long]$Item.size
        Dependencies=@($Item.dependencies | Where-Object { $_ }); IconUrl=[string]$Item.iconUrl
        PreviewUrls=@($Item.previewUrls | Where-Object { Test-CatalogUrl $_ })
    }
}

function Get-GitHubCatalog($Source, [string]$CacheDir) {
    if ($Source.repository -notmatch '^[\w.-]+/[\w.-]+$' -or $Source.root -notmatch '^[\w/-]+$') { throw 'Invalid GitHub source.' }
    $seen = @{}
    foreach ($ref in @($Source.refs)) {
        $branch = Get-CatalogHttp ('https://api.github.com/repos/' + $Source.repository + '/branches/' + [uri]::EscapeDataString($ref)) $CacheDir
        $commit = [string]$branch.commit.sha
        if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'Invalid repository revision.' }
        $tree = Get-CatalogHttp ('https://api.github.com/repos/' + $Source.repository + '/git/trees/' + $commit + '?recursive=1') $CacheDir
        if ($tree.truncated) { throw 'The repository listing is incomplete.' }
        $pattern = '^' + [regex]::Escape($Source.root) + '/([^/]+)/mod\.vdf$'
        foreach ($file in @($tree.tree | Where-Object { $_.path -match $pattern -and $_.type -eq 'blob' })) {
            $folder = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($file.path))
            $raw = Get-CatalogHttp ('https://raw.githubusercontent.com/' + $Source.repository + '/' + $commit + '/' + $file.path) $CacheDir $false
            $metadata = @{}
            foreach ($field in @('id','name','version','author','description')) {
                $match = [regex]::Match($raw, '(?im)^\s*"' + $field + '"\s*"((?:\\.|[^"\\])*)"')
                if ($match.Success) { $metadata[$field] = $match.Groups[1].Value.Replace('\n',"`n") }
            }
            if (-not $metadata.id -or $seen.ContainsKey($metadata.id)) { continue }
            $seen[$metadata.id] = $true
            $metadata.modId = $metadata.id; $metadata.build = $Source.build; $metadata.category = $Source.category
            $metadata.installKind = 'github-directory'; $metadata.repository = $Source.repository; $metadata.commit = $commit
            $metadata.packagePath = $Source.root + '/' + $folder
            $metadata.pageUrl = 'https://github.com/' + $Source.repository + '/tree/' + $ref + '/' + $metadata.packagePath
            $metadata.downloadUrl = 'https://codeload.github.com/' + $Source.repository + '/zip/' + $commit
            $art = @($tree.tree | Where-Object { $_.path -match ('^' + [regex]::Escape($metadata.packagePath) + '/(preview|screenshot|icon)\.(png|jpg|jpeg)$') } | Select-Object -First 1)
            if ($art.Count -gt 0) { $metadata.previewUrls = @('https://raw.githubusercontent.com/' + $Source.repository + '/' + $commit + '/' + $art[0].path) }
            New-CatalogEntry $Source ([pscustomobject]$metadata)
        }
    }
}

function Get-ThunderstoreCatalog($Source, [string]$CacheDir) {
    $packages = @(Get-CatalogHttp $Source.url $CacheDir)
    foreach ($package in $packages) {
        if (-not $package.owner -or -not $package.name -or -not $package.versions) { throw 'Invalid Thunderstore response.' }
        if ($package.is_deprecated) { continue }
        $version = @($package.versions | Where-Object { $_.is_active -ne $false }) | Select-Object -First 1
        if (-not $version) { continue }
        New-CatalogEntry $Source ([pscustomobject]@{
            id=($package.owner + '.' + $package.name); modId=($package.owner + '.' + $package.name)
            name=$package.name; author=$package.owner; description=$version.description; version=$version.version_number
            category=(@($package.categories) -join ', '); build=$Source.build; pageUrl=$package.package_url
            installKind='zip'; downloadUrl=$version.download_url; updated=$package.date_updated
            size=$version.file_size; downloads=($package.versions | Measure-Object downloads -Sum).Sum
            dependencies=@($version.dependencies); iconUrl=$version.icon
        })
    }
}

function Get-FeedCatalog($Source, [string]$CatalogDir, [string]$CacheDir) {
    if ($Source.url) { $feed = Get-CatalogHttp $Source.url $CacheDir }
    else {
        $path = [IO.Path]::GetFullPath((Join-Path $CatalogDir $Source.path))
        if (-not $path.StartsWith([IO.Path]::GetFullPath($CatalogDir).TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid catalog feed path.' }
        $feed = Read-CatalogJson $path
    }
    if (-not $feed -or $feed.schemaVersion -ne 1 -or $null -eq $feed.mods) { throw 'Unsupported catalog feed format.' }
    foreach ($item in @($feed.mods)) { New-CatalogEntry $Source $item }
}

function Sync-ModCatalog([string]$CatalogDir, [string]$CacheDir, [bool]$Force = $false, $Progress = @{}) {
    $config = Read-CatalogJson (Join-Path $CatalogDir 'sources.json')
    if (-not $config -or $config.schemaVersion -ne 1) { throw 'Unsupported source configuration.' }
    $ids = @{}; $merged = @{}; $states = @()
    foreach ($source in @($config.sources)) {
        if ($source.id -notmatch '^[a-z0-9-]{1,60}$' -or $ids.ContainsKey($source.id)) { throw 'Invalid or duplicate source ID.' }
        $ids[$source.id] = $true
        $path = Join-Path $CacheDir ($source.id + '.json')
        $snapshot = Read-CatalogJson $path
        $now = [DateTime]::UtcNow
        $state = 'Current'; $errorText = ''
        $due = $true
        if ($snapshot -and $snapshot.nextCheck) { try { $due = [DateTime]::Parse($snapshot.nextCheck).ToUniversalTime() -le $now } catch {} }
        if ($Force -or $due -or -not $snapshot) {
            $Progress.Text = 'Updating ' + $source.name
            try {
                $items = @(switch ($source.type) {
                    'github-tree' { Get-GitHubCatalog $source $CacheDir }
                    'thunderstore' { Get-ThunderstoreCatalog $source $CacheDir }
                    'feed' { Get-FeedCatalog $source $CatalogDir $CacheDir }
                    default { throw 'Unsupported catalog provider.' }
                })
                $snapshot = [pscustomobject]@{schemaVersion=1; updated=$now.ToString('o'); nextCheck=$now.AddMinutes(30).ToString('o'); items=$items; error=''}
                Write-CatalogJson $path $snapshot
            } catch {
                $state = 'Unavailable'; $errorText = $_.Exception.Message
                if ($snapshot) {
                    $state = 'Cached'
                    $snapshot.nextCheck = $now.AddMinutes(5).ToString('o'); $snapshot.error = $errorText
                    Write-CatalogJson $path $snapshot
                }
            }
        } elseif ($snapshot.error) { $state = 'Cached'; $errorText = $snapshot.error }
        if ($snapshot -and $snapshot.schemaVersion -eq 1) {
            foreach ($item in @($snapshot.items)) {
                $identity = if ($item.ModId) { $item.Build + ':' + $item.ModId } else { $item.Key }
                if (-not $merged.ContainsKey($identity)) { $merged[$identity] = $item }
            }
        }
        $states += [pscustomobject]@{Name=$source.name; State=$state; Error=$errorText; Updated=if($snapshot){$snapshot.updated}else{''}; Count=@($snapshot.items).Count}
    }
    [pscustomobject]@{Items=@($merged.Values | Sort-Object Name); Sources=$states}
}
