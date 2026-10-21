function Save-ModPackage([string]$Url, [string]$Path, $Progress, [long]$MaxBytes = 1GB) {
    if (-not (Test-CatalogUrl $Url)) { throw 'Package downloads require HTTPS.' }
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'R5R-Mod-Manager/3.2'
    $request.Timeout = 15000; $request.ReadWriteTimeout = 30000
    $response = $request.GetResponse()
    try {
        if ($response.ResponseUri.Scheme -ne 'https') { throw 'An insecure package redirect was rejected.' }
        if ($response.ContentLength -gt $MaxBytes) { throw 'Package exceeds the 1 GB download limit.' }
        $Progress.Total = $response.ContentLength; $Progress.Bytes = [long]0
        $input = $response.GetResponseStream(); $output = [IO.File]::Create($Path)
        try {
            $buffer = New-Object byte[] 65536
            while (($count = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
                $Progress.Bytes = $Progress.Bytes + $count
                if ($Progress.Bytes -gt $MaxBytes) { throw 'Package exceeds the 1 GB download limit.' }
                $output.Write($buffer,0,$count)
            }
        } finally { $output.Dispose(); $input.Dispose() }
    } finally { $response.Close() }
}

function Expand-ModPackage([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 20000) { throw 'Package contains too many files.' }
        $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
        $total = [long]0; $paths = @{}
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\','/')
            if ($name.StartsWith('/') -or $name.Contains(':') -or $name -match '(^|/)\.\.(/|$)' -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Package contains an unsafe path or symbolic link.' }
            foreach ($part in $name.Split('/')) {
                if ($part -and ($part -match '[. ]$|[<>"|?*]' -or $part -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)')) { throw 'Package contains an invalid Windows file name.' }
            }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $name))
            if (-not $target.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw 'Package path escapes the staging folder.' }
            if ($paths.ContainsKey($target)) { throw 'Package contains duplicate paths.' }
            $paths[$target] = $true
            $total += $entry.Length
            if ($total -gt 4GB) { throw 'Expanded package exceeds the 4 GB limit.' }
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
    } finally { $zip.Dispose() }
}

function Test-GitBlob([string]$Path, [string]$Expected) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $header = [Text.Encoding]::UTF8.GetBytes('blob ' + $stream.Length + [char]0)
        [void]$sha.TransformBlock($header,0,$header.Length,$header,0)
        $buffer = New-Object byte[] 65536
        while (($count = $stream.Read($buffer,0,$buffer.Length)) -gt 0) { [void]$sha.TransformBlock($buffer,0,$count,$buffer,0) }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        return ([BitConverter]::ToString($sha.Hash).Replace('-','') -ieq $Expected)
    } finally { $sha.Dispose(); $stream.Dispose() }
}

function Prepare-CatalogPackage($Entry, [string]$StageRoot, $Progress, [string]$CacheDir) {
    if ($Entry.Build -ne 'R5Reloaded S3') { throw 'This package targets a different game build.' }
    if ($Entry.InstallKind -notin @('zip','github-directory')) { throw 'This listing requires manual installation.' }
    if ($Entry.ModId -notmatch '^[A-Za-z0-9_.-]{1,100}$') { throw 'Invalid package mod ID.' }
    [void][IO.Directory]::CreateDirectory($StageRoot)
    $archive = Join-Path $StageRoot 'package.zip'
    $expanded = Join-Path $StageRoot 'expanded'
    if ($Entry.InstallKind -eq 'github-directory') {
        if ($Entry.Repository -notmatch '^[\w.-]+/[\w.-]+$' -or $Entry.Commit -notmatch '^[a-f0-9]{40}$' -or
            $Entry.PackagePath -notmatch '^[\w./-]+$' -or $Entry.PackagePath -match '(^|/)\.\.(/|$)') { throw 'Invalid repository package location.' }
        $tree = Get-CatalogHttp ('https://api.github.com/repos/' + $Entry.Repository + '/git/trees/' + $Entry.Commit + '?recursive=1') $CacheDir
        if ($tree.truncated) { throw 'The repository listing is incomplete.' }
        $prefix = $Entry.PackagePath.TrimEnd('/') + '/'
        $files = @($tree.tree | Where-Object { $_.type -eq 'blob' -and $_.path.StartsWith($prefix,[StringComparison]::Ordinal) })
        if ($files.Count -eq 0 -or $files.Count -gt 20000) { throw 'Invalid repository package file count.' }
        $modRoot = Join-Path $StageRoot 'repository-mod'
        [void][IO.Directory]::CreateDirectory($modRoot)
        $Progress.Total = [long]($files | Measure-Object size -Sum).Sum; $Progress.Bytes = [long]0
        if ($Progress.Total -gt 1GB) { throw 'Package exceeds the 1 GB download limit.' }
        foreach ($file in $files) {
            $relative = $file.path.Substring($prefix.Length)
            if ($file.mode -notin @('100644','100755') -or $file.sha -notmatch '^[a-f0-9]{40}$' -or
                $relative -match '(^|/)\.\.(/|$)|[:\\<>"|?*]' -or $relative -match '(^|/)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|/|$)' -or $relative -match '[. ](/|$)') { throw 'Repository contains an unsafe path or symbolic link.' }
            $out = [IO.Path]::GetFullPath((Join-Path $modRoot $relative))
            if (-not $out.StartsWith($modRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Repository path escapes the staging folder.' }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($out))
            $Progress.Text = 'Downloading ' + $Entry.Name + ' - ' + [IO.Path]::GetFileName($out)
            Save-ModPackage ('https://raw.githubusercontent.com/' + $Entry.Repository + '/' + $Entry.Commit + '/' + $file.path) $out @{} ([long]$file.size + 1)
            if (-not (Test-GitBlob $out $file.sha)) { throw 'A repository file failed its integrity check.' }
            $Progress.Bytes = $Progress.Bytes + $file.size
        }
    } else {
        $Progress.Text = 'Downloading ' + $Entry.Name
        Save-ModPackage $Entry.DownloadUrl $archive $Progress
        if ($Entry.Sha256 -and (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $Entry.Sha256) { throw 'Package checksum does not match the catalog.' }
        $Progress.Text = 'Checking ' + $Entry.Name
        Expand-ModPackage $archive $expanded
        $manifests = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter mod.vdf)
        if ($manifests.Count -ne 1) { throw 'Package must contain exactly one mod.vdf.' }
        $modRoot = $manifests[0].DirectoryName
    }
    $vdf = Join-Path $modRoot 'mod.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) { throw 'Package has no mod.vdf.' }
    $metadata = Read-ModVdf $vdf
    if ($metadata.Id -ine $Entry.ModId) { throw 'Package mod ID does not match the catalog.' }
    if ($Entry.Version -and $metadata.Version -ne $Entry.Version) { throw 'Package version does not match the catalog.' }
    $Progress.Text = 'Preparing ' + $Entry.Name
    # The final move stays on the game volume; large asset copies finish before replacement.
    $ready = Join-Path $StageRoot ('ready/' + $Entry.ModId)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ready))
    [IO.Directory]::Move($modRoot, $ready)
    [pscustomobject]@{Path=$ready; ModId=$metadata.Id; Version=$metadata.Version}
}

function Remove-PackageStage([string]$Stage, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Stage).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike '.r5mm-stage-*') { throw 'Invalid package staging path.' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
