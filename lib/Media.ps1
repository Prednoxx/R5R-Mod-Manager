function Get-MediaKey([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-','') }
    finally { $sha.Dispose() }
}

function Get-PreviewPath($Entry, [string]$CacheDir) {
    $url = @($Entry.PreviewUrls | Where-Object { $_ }) | Select-Object -First 1
    if (-not $url) { $url = $Entry.IconUrl }
    if ($url) {
        $path = Join-Path $CacheDir ('images/' + (Get-MediaKey $url) + '.img')
        if ([IO.File]::Exists($path)) { return $path }
    }
    return $null
}

function Save-CatalogImage([string]$Url, [string]$CacheDir) {
    if (-not (Test-CatalogUrl $Url)) { return $null }
    $path = Join-Path $CacheDir ('images/' + (Get-MediaKey $Url) + '.img')
    if ([IO.File]::Exists($path)) { return $path }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Save-ModPackage $Url $temp @{} 8MB
        Add-Type -AssemblyName PresentationCore
        $stream = [IO.File]::OpenRead($temp)
        try {
            $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::None,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $frame = $decoder.Frames[0]
            if ($frame.PixelWidth -gt 16384 -or $frame.PixelHeight -gt 16384 -or ([long]$frame.PixelWidth * $frame.PixelHeight) -gt 64000000) { throw 'Preview image exceeds the size limit.' }
        } finally { $stream.Dispose() }
        if (-not [IO.File]::Exists($path)) { [IO.File]::Move($temp,$path) }
        return $path
    } catch { return $null }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Sync-CatalogImages($Items, [string]$CacheDir, $Queue) {
    foreach ($entry in @($Items)) {
        $urls = @($entry.PreviewUrls | Where-Object { $_ })
        if ($urls.Count -eq 0 -and $entry.IconUrl) { $urls = @($entry.IconUrl) }
        if ($urls.Count -eq 0) { continue }
        $path = Save-CatalogImage $urls[0] $CacheDir
        if ($path) { $Queue.Enqueue([pscustomobject]@{Key=$entry.Key;Path=$path}) }
    }
}

function Get-CatalogDetails($Entry, [string]$CacheDir) {
    $path = Join-Path $CacheDir ('details/' + (Get-MediaKey ($Entry.Key + ':' + $Entry.Version + ':' + $Entry.Commit)) + '.json')
    $cached = Read-CatalogJson $path
    if ($cached -and $cached.Updated) {
        try { if ([DateTime]::Parse($cached.Updated).ToUniversalTime() -gt [DateTime]::UtcNow.AddHours(-1)) { return $cached } } catch {}
    }
    $body = $Entry.Description
    $urls = @($Entry.PreviewUrls | Where-Object { $_ })
    if ($Entry.SourceId -eq 'flowstate-thunderstore' -and $Entry.ModId -match '^([\w-]+)\.([\w-]+)$' -and $Entry.Version -match '^[\w.-]+$') {
        $parts=$Entry.ModId -split '\.',2; $namespace=$parts[0]; $name=$parts[1]
        try { $readme = Get-CatalogHttp ('https://thunderstore.io/api/experimental/package/' + $namespace + '/' + $name + '/' + $Entry.Version + '/readme/') $CacheDir }
        catch { if ($cached) { return $cached }; throw }
        if ($readme.markdown) {
            $body = [string]$readme.markdown
            foreach ($match in [regex]::Matches($body, '!\[[^\]]*\]\((https://[^\s)]+)(?:\s+"[^"]*")?\)')) { $urls += $match.Groups[1].Value }
            foreach ($match in [regex]::Matches($body, '<img[^>]+src=["''](https://[^"'']+)', 'IgnoreCase')) { $urls += $match.Groups[1].Value }
        }
    }
    if ($urls.Count -eq 0 -and $Entry.IconUrl) { $urls += $Entry.IconUrl }
    $images = @()
    foreach ($url in @($urls | Select-Object -Unique -First 8)) { $image = Save-CatalogImage $url $CacheDir; if ($image) { $images += $image } }
    # Description text is rendered as text; remote HTML and script content are never executed.
    $body = [regex]::Replace($body,'(?is)<(script|style)\b[^>]*>.*?</\1>','')
    $body = [regex]::Replace($body,'!\[[^\]]*\]\([^)]*\)','')
    $body = [regex]::Replace($body,'<[^>]+>','')
    $body = [regex]::Replace($body,'(?m)^#{1,6}\s+','')
    $body = [regex]::Replace($body,'\[([^\]]+)\]\((https://[^)]+)\)','$1 ($2)')
    $body = [Net.WebUtility]::HtmlDecode($body).Trim()
    $result = [pscustomobject]@{Key=$Entry.Key;Body=$body;Images=$images;Updated=[DateTime]::UtcNow.ToString('o')}
    Write-CatalogJson $path $result
    return $result
}
