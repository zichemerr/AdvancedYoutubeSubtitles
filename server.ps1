Add-Type -AssemblyName System.Web

$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.json not found at $configPath"
    exit 1
}
$cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

$port       = if ($cfg.server.port)       { $cfg.server.port }       else { 8080 }
$bindHost   = if ($cfg.server.host)       { $cfg.server.host }       else { "localhost" }
$ytdlpPath  = if ($cfg.ytdlp.path)        { $cfg.ytdlp.path }        else { "tools/yt-dlp.exe" }
$YtDlp      = Join-Path $PSScriptRoot $ytdlpPath

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://${bindHost}:${port}/")
try {
    $hostName = [System.Net.Dns]::GetHostName()
    $allIPs = [System.Net.Dns]::GetHostAddresses($hostName)
    foreach ($ip in $allIPs) {
        if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $ip.IPAddressToString -ne '127.0.0.1') {
            try { $listener.Prefixes.Add("http://$($ip.IPAddressToString):${port}/") } catch {}
        }
    }
} catch {}
$listener.Start()

Write-Host "Server running at http://${bindHost}:${port}/Main.html"
try {
    $hostName = [System.Net.Dns]::GetHostName()
    $allIPs = [System.Net.Dns]::GetHostAddresses($hostName)
    foreach ($ip in $allIPs) {
        if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $ip.IPAddressToString -ne '127.0.0.1') {
            Write-Host "Phone: http://$($ip.IPAddressToString):${port}/Main.html"
        }
    }
} catch {}
Write-Host "Press Ctrl+C to stop"

function Send-Json($context, $obj, $code = 200) {
    try {
        $context.Response.StatusCode = $code
        $json = $obj | ConvertTo-Json -Depth 10 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $context.Response.ContentType = 'application/json; charset=utf-8'
        $context.Response.Headers.Add('Access-Control-Allow-Origin', '*')
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        Write-Host "[send-json] Error: $_"
    } finally {
        try { $context.Response.Close() } catch {}
    }
}

function Send-Error($context, $msg, $code = 500) {
    Send-Json $context @{error=$msg} $code
}

function Get-QueryParam($context, $name) {
    $qs = [System.Web.HttpUtility]::ParseQueryString($context.Request.Url.Query, [System.Text.Encoding]::UTF8)
    return $qs[$name]
}

function Run-YtDlp([string[]]$argList, $timeoutSec = 60) {
    $argStr = ($argList | ForEach-Object {
        if ($_ -match '\s' -or $_ -match '"') { "`"$_`"" } else { $_ }
    }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $YtDlp
    $psi.Arguments = $argStr
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($timeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        return @{ exitCode = -1; stdout = ''; stderr = 'Timeout exceeded' }
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    return @{ exitCode = $proc.ExitCode; stdout = $stdout; stderr = $stderr }
}

function Parse-SubLines($stdout) {
    $result = @{ manual = @(); auto = @() }
    $lines = $stdout -split "`n"
    $section = ''

    foreach ($line in $lines) {
        if ($line -match 'Available manual captions') { $section = 'manual'; continue }
        if ($line -match 'Available automatic captions') { $section = 'auto'; continue }
        if ($section -eq '' -or $line -match '^\s*$') { continue }
        if ($line -match '^Language\s') { continue }

        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }

        $parts = $trimmed -split '\s{2,}', 3
        if ($parts.Count -lt 2) { continue }

        $langCode = $parts[0].Trim()
        $name = $parts[1].Trim()

        if ($langCode -notmatch '^[a-z]{2,3}(-[A-Za-z0-9-]+)?$') { continue }

        $track = @{
            languageCode = $langCode
            name = $name
            section = $section
        }

        if ($section -eq 'manual') {
            $result.manual += $track
        } else {
            $result.auto += $track
        }
    }
    return $result
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $path = $context.Request.Url.LocalPath

    if ($path -eq '/api/config') {
        $clientConfig = @{
            server   = $cfg.server
            app      = $cfg.app
            languages = $cfg.languages
            apis     = $cfg.apis
        }
        Send-Json $context $clientConfig
        continue
    }

    if ($path -eq '/api/info') {
        $vid = Get-QueryParam $context 'v'
        if (-not $vid) { Send-Error $context 'Missing ?v= parameter' 400; continue }
        Write-Host "[info] Fetching title for: $vid"
        $timeout = if ($cfg.ytdlp.timeoutInfo) { $cfg.ytdlp.timeoutInfo } else { 15 }
        $result = Run-YtDlp @("--skip-download","--print","title","--",$vid) $timeout
        if ($result.exitCode -eq 0 -and $result.stdout.Trim()) {
            $title = $result.stdout.Trim().Split("`n")[0].Trim()
            Send-Json $context @{title=$title; id=$vid}
        } else {
            Send-Json $context @{title=$vid; id=$vid}
        }
        continue
    }

    if ($path -eq '/api/duration') {
        $vid = Get-QueryParam $context 'v'
        if (-not $vid) { Send-Error $context 'Missing ?v= parameter' 400; continue }
        $timeout = if ($cfg.ytdlp.timeoutInfo) { $cfg.ytdlp.timeoutInfo } else { 15 }
        $result = Run-YtDlp @("--skip-download","--print","duration","--",$vid) $timeout
        if ($result.exitCode -eq 0 -and $result.stdout.Trim()) {
            $dur = $result.stdout.Trim().Split("`n")[0].Trim()
            Send-Json $context @{duration=$dur; id=$vid}
        } else {
            Send-Json $context @{duration="0"; id=$vid}
        }
        continue
    }

    if ($path -eq '/api/captions') {
        $vid = Get-QueryParam $context 'v'
        if (-not $vid) { Send-Error $context 'Missing ?v= parameter' 400; continue }
        Write-Host "[captions] Fetching for: $vid"
        $timeoutInfo = if ($cfg.ytdlp.timeoutInfo) { $cfg.ytdlp.timeoutInfo } else { 15 }
        $langResult = Run-YtDlp @("--skip-download","--print","language","--",$vid) $timeoutInfo
        $detectedLang = ''
        if ($langResult.exitCode -eq 0 -and $langResult.stdout.Trim()) {
            $raw = $langResult.stdout.Trim().Split("`n")[0].Trim()
            if ($raw -match '^[a-z]{2,3}(-[A-Za-z0-9-]+)?$') { $detectedLang = $raw }
        }
        Write-Host "[captions] yt-dlp language: '$detectedLang'"

        $timeoutCaptions = if ($cfg.ytdlp.timeoutCaptions) { $cfg.ytdlp.timeoutCaptions } else { 30 }
        $result = Run-YtDlp @("--skip-download","--list-subs","--",$vid) $timeoutCaptions
        Write-Host "[captions] Exit: $($result.exitCode)"
        if ($result.exitCode -ne 0) {
            Send-Error $context "yt-dlp error: $($result.stderr)" 500
            continue
        }
        $parsed = Parse-SubLines $result.stdout
        if (-not $detectedLang -and $parsed.manual.Count -gt 0) {
            $enTrack = $parsed.manual | Where-Object { $_.languageCode -eq 'en' }
            if ($enTrack) { $detectedLang = 'en' }
            else { $detectedLang = $parsed.manual[0].languageCode }
            Write-Host "[captions] Detected from subs: $detectedLang"
        }
        if (-not $detectedLang) { $detectedLang = 'en' }
        $tracks = @()
        foreach ($t in $parsed.manual) { $tracks += $t }
        foreach ($t in $parsed.auto) { $tracks += $t }
        Write-Host "[captions] Found $($tracks.Count) tracks ($($parsed.manual.Count) manual, $($parsed.auto.Count) auto)"
        Send-Json $context @{tracks=$tracks; detectedLanguage=$detectedLang}
    }
    elseif ($path -eq '/api/subtitles') {
        $vid = Get-QueryParam $context 'v'
        $lang = Get-QueryParam $context 'lang'
        if (-not $vid) { Send-Error $context 'Missing ?v= parameter' 400; continue }
        if (-not $lang) { $lang = 'en' }
        Write-Host "[subtitles] Fetching: $vid lang=$lang"
        $tempDir = Join-Path $env:TEMP "ytsubs_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
        try {
            $outPath = Join-Path $tempDir "sub"
            $timeoutSubs = if ($cfg.ytdlp.timeoutSubtitles) { $cfg.ytdlp.timeoutSubtitles } else { 60 }
            $result = Run-YtDlp @("--write-sub","--write-auto-sub","--sub-lang",$lang,"--sub-format","json3","--skip-download","-o",$outPath,"--",$vid) $timeoutSubs
            Write-Host "[subtitles] Exit: $($result.exitCode)"
            Write-Host "[subtitles] stderr: $($result.stderr.Substring(0, [Math]::Min(200, $result.stderr.Length)))"
            $jsonFiles = Get-ChildItem $tempDir -Filter "*.json3" -ErrorAction SilentlyContinue
            if ($null -eq $jsonFiles -or $jsonFiles.Count -eq 0) {
                Send-Json $context @{lines=@()}
                continue
            }
            $content = [System.IO.File]::ReadAllText($jsonFiles[0].FullName, [System.Text.Encoding]::UTF8)
            $json = $content | ConvertFrom-Json
            $lines = @()
            foreach ($ev in $json.events) {
                if (-not $ev.segs) { continue }
                $text = ($ev.segs | ForEach-Object { $_.utf8 }) -join ''
                $text = $text.Trim()
                if ([string]::IsNullOrEmpty($text)) { continue }
                $lines += @{
                    timeMs = if ($ev.tStartMs) { $ev.tStartMs } else { 0 }
                    durationMs = if ($ev.dDurationMs) { $ev.dDurationMs } else { 0 }
                    text = $text
                }
            }
            Write-Host "[subtitles] Got $($lines.Count) lines"
            Send-Json $context @{lines=$lines}
        } catch {
            Write-Host "[subtitles] Error: $_"
            Send-Error $context $_.Exception.Message
        } finally {
            if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    elseif ($path -eq '/api/tts') {
        $text = Get-QueryParam $context 'text'
        $lang = Get-QueryParam $context 'lang'
        if (-not $text) { Send-Error $context 'Missing ?text= parameter' 400; continue }
        if (-not $lang) { $lang = 'en' }
        try {
            $ttsUrl = if ($cfg.apis.tts.url) { $cfg.apis.tts.url } else { "https://translate.google.com/translate_tts" }
            $ttsClient = if ($cfg.apis.tts.client) { $cfg.apis.tts.client } else { "tw-ob" }
            $encoded = [System.Uri]::EscapeDataString($text)
            $url = "${ttsUrl}?ie=UTF-8&tl=$lang&client=$ttsClient&q=$encoded"
            $headers = @{'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -Headers $headers
            $bytes = $r.Content
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'audio/mpeg'
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {
            Write-Host "[tts] Error: $_"
            Send-Error $context "TTS failed: $($_.Exception.Message)"
        } finally {
            try { $context.Response.Close() } catch {}
        }
    }
    elseif ($path -eq '/api/translate') {
        $text = Get-QueryParam $context 'text'
        $from = Get-QueryParam $context 'from'
        $to = Get-QueryParam $context 'to'
        if (-not $text) { Send-Error $context 'Missing ?text= parameter' 400; continue }
        if (-not $to) { $to = 'ru' }
        try {
            $translateUrl = if ($cfg.apis.translate.url) { $cfg.apis.translate.url } else { "https://translate.googleapis.com/translate_a/single" }
            $translateClient = if ($cfg.apis.translate.client) { $cfg.apis.translate.client } else { "gtx" }
            $encoded = [System.Uri]::EscapeDataString($text)
            $url = "${translateUrl}?client=$translateClient&sl=$from&tl=$to&dt=t&q=$encoded"
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add('User-Agent', 'Mozilla/5.0')
            $bytes = $webClient.DownloadData($url)
            $json = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
            $translation = ($json[0] | ForEach-Object { $_[0] }) -join ''
            Send-Json $context @{translation=$translation; source=$text}
        } catch {
            Write-Host "[translate] Error: $_"
            Send-Error $context "Translation failed: $($_.Exception.Message)"
        }
    }
    elseif ($path -eq '/api/words') {
        $word = Get-QueryParam $context 'word'
        if (-not $word) { Send-Error $context 'Missing ?word= parameter' 400; continue }
        Write-Host "[words] Fetching synonyms for: $word"
        try {
            $synonymsUrl = if ($cfg.apis.synonyms.url) { $cfg.apis.synonyms.url } else { "https://api.datamuse.com/words" }
            $synonymsMax = if ($cfg.apis.synonyms.maxResults) { $cfg.apis.synonyms.maxResults } else { 8 }
            $encoded = [System.Uri]::EscapeDataString($word)
            $url = "${synonymsUrl}?rel_syn=$encoded&max=$synonymsMax"
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add('User-Agent', 'Mozilla/5.0')
            $bytes = $webClient.DownloadData($url)
            $json = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
            $synonyms = @()
            foreach ($item in $json) {
                if ($item.word) { $synonyms += $item.word }
            }
            Send-Json $context @{word=$word; synonyms=$synonyms}
        } catch {
            Write-Host "[words] Error: $_"
            Send-Json $context @{word=$word; synonyms=@()}
        }
        continue
    }
    else {
        $file = Join-Path $PSScriptRoot $path.TrimStart('/')
        if (-not (Test-Path $file)) { $context.Response.StatusCode = 404; $context.Response.Close(); continue }
        $bytes = [IO.File]::ReadAllBytes($file)
        $ext = [IO.Path]::GetExtension($file)
        $context.Response.ContentType = switch ($ext) {
            '.html' { 'text/html' }
            '.css' { 'text/css' }
            '.js' { 'application/javascript' }
            '.json' { 'application/json' }
            '.png' { 'image/png' }
            '.ico' { 'image/x-icon' }
            default { 'application/octet-stream' }
        }
        $context.Response.ContentLength64 = $bytes.Length
        if ($ext -eq '.html') {
            $context.Response.Headers.Add('Cache-Control', 'no-cache, no-store, must-revalidate')
            $context.Response.Headers.Add('Pragma', 'no-cache')
            $context.Response.Headers.Add('Expires', '0')
        }
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()
    }
}
