#!/usr/bin/env pwsh
# =============================================================================
#  UserDashboard.ps1
#  Single Pode app that replaces Glance: serves the dashboard AND handles
#  per-user toggles, with identity from Cloudflare Access (JWT verify).
#
#  CONFIG IS READ FROM ENVIRONMENT VARIABLES, set in Portainer:
#  your stack > Environment variables (the box below the YAML editor).
#  $env: values are process-level, so they're visible inside Pode's route
#  runspaces. The two CF_ vars are REQUIRED; if either is missing the app
#  prints a loud CONFIG ERROR and exits (so a misconfig is obvious, not silent).
#
#    CF_TEAM_DOMAIN   REQUIRED. e.g. https://nogoodreason.cloudflareaccess.com (no trailing slash)
#    CF_ACCESS_AUD    REQUIRED. Application Audience (AUD) tag for the gunit Access app
#    DASH_STATE_DIR   optional. container path where prefs are mounted (default /userprefs)
#    DASH_PORT        optional. listen port (default 8080)
#    DASH_DEVMODE     optional. "true" to bypass auth for local testing (NEVER in prod)
#    DASH_DEVEMAIL    optional. identity used when DASH_DEVMODE is true
#
#  The toggle JSON files are the ONLY contract with the media pipeline:
#  the pipeline reads <DASH_STATE_DIR>/<email>.json and acts on it.
# =============================================================================

Import-Module Pode

Start-PodeServer {

    # --- config accessor: reads $env: (set via Portainer's Environment
    #     variables box). $env: is process-level so it's visible inside Pode's
    #     route runspaces. Set CF_TEAM_DOMAIN and CF_ACCESS_AUD in Portainer.
    function Get-Cfg([string]$name, [string]$default = '') {
        $v = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($v)) { return $default }
        return $v
    }

    # --- FAIL LOUD on missing required config, but print WHY before exiting so
    #     the logs aren't empty. (A bare crash restart-loops with no message.)
    $missing = @()
    if ([string]::IsNullOrWhiteSpace((Get-Cfg 'CF_TEAM_DOMAIN'))) { $missing += 'CF_TEAM_DOMAIN' }
    if ([string]::IsNullOrWhiteSpace((Get-Cfg 'CF_ACCESS_AUD')))  { $missing += 'CF_ACCESS_AUD' }
    if ($missing.Count -gt 0) {
        "*** CONFIG ERROR ***" | Out-Default
        "Missing required environment variable(s): $($missing -join ', ')" | Out-Default
        "Set them in Portainer > your stack > Environment variables, then redeploy." | Out-Default
        "*** Exiting. ***" | Out-Default
        throw "Missing required config: $($missing -join ', ')"
    }

    $port = [int](Get-Cfg 'DASH_PORT' '8080')
    Add-PodeEndpoint -Address 0.0.0.0 -Port $port -Protocol Http

    # Log errors and requests to the terminal so `docker logs` shows failures.
    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging
    New-PodeLoggingMethod -Terminal | Enable-PodeRequestLogging

    # Local config dir (fast disk on otis, NOT the slow NAS). Holds the
    # editable files: template.html, instructions.md, users.json.
    $cfgDir = Get-Cfg 'DASH_CONFIG_DIR' '/config'
    Set-PodeState -Name 'CfgDir' -Value $cfgDir | Out-Null

    # Toggle DEFINITIONS stay in the script: they are logic (they map to keys
    # the storage + pipeline understand), not free-text content. Add one here
    # to add a setting; that does need a rebuild, unlike the editable content.
    $script:ToggleDefs = @(
        @{ Key = 'kindleSync'; Label = 'add books I download to Kindle sync list automatically'; Default = $false }
        # calibreBusy: a "don't interrupt me" switch for when Rob is using the
        # Calibre desktop GUI. While ON, the import watcher/sweep DEFER instead of
        # killing the GUI to free the library lock. Stored as an EXPIRY TIMESTAMP
        # (epoch seconds) so it AUTO-CLEARS after 2h even if left on. Restricted to
        # Rob's account (only he uses the desktop GUI; others use calibre-web which
        # never holds the lock). 'Expiry = 7200' seconds = 2 hours.
        @{ Key = 'calibreBusy'; Label = "I'm using Calibre desktop now — pause auto-import for 2h (don't interrupt)"; Default = $false; Users = @('shops@rob.me.uk'); Expiry = 7200 }
        # @{ Key = 'notifyEmail'; Label = 'Email me when a download finishes'; Default = $false }
    )
    Set-PodeState -Name 'ToggleDefs' -Value $script:ToggleDefs | Out-Null

    # Dashboard LINKS stay in the script (they change rarely; keeping them in
    # code means they're version-controlled and can't go missing). Edit here +
    # rebuild to change them. (Greetings + instructions are editable files.)
    $script:DashLinks = @(
        @{ Title = 'Browse the library';             Url = 'https://books.rob.me.uk/discover/stored' }
        @{ Title = 'Request a book from the server'; Url = 'https://request-books.rob.me.uk' }
    )
    Set-PodeState -Name 'DashLinks' -Value $script:DashLinks | Out-Null

    # Ensure the per-user prefs dir exists.
    $stateDir = Get-Cfg 'DASH_STATE_DIR' '/userprefs'
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    # --- cached file reader: re-reads a file only when its mtime changes, so
    #     pages load fast (no disk hit per request) but edits appear on refresh.
    #     Cache lives in Pode state, keyed by path.
    function Read-CachedFile([string]$path) {
        if (-not (Test-Path $path)) { return $null }
        $mtime = (Get-Item $path).LastWriteTimeUtc.Ticks
        $cacheKey = "filecache::$path"
        $cached = $null
        try { $cached = Get-PodeState -Name $cacheKey } catch { }
        if ($cached -and $cached.Mtime -eq $mtime) { return $cached.Content }
        $content = Get-Content $path -Raw
        Set-PodeState -Name $cacheKey -Value @{ Mtime = $mtime; Content = $content } | Out-Null
        return $content
    }

    # --- greeting: read from users.json (single source of truth, editable) ---
    # Resolution: explicit 'greeting' wins; else 'name' filled into the
    # defaultGreeting template ({name}); else plain default with {name} stripped.
    function Resolve-Greeting([string]$email) {
        $dir  = Get-PodeState -Name 'CfgDir'
        $json = Read-CachedFile (Join-Path $dir 'users.json')
        $defaultTpl = 'Welcome to the library.'

        # helper: substitute {name} (or strip it cleanly if no name)
        $fill = {
            param($text, $name)
            if ($name) { return ($text -replace '\{name\}', [string]$name) }
            return ($text -replace '\s*\{name\}', '' -replace '\{name\}', '')
        }

        if ($json) {
            try {
                $obj = $json | ConvertFrom-Json
                if ($obj.defaultGreeting) { $defaultTpl = [string]$obj.defaultGreeting }
                $match = $obj.users | Where-Object { $_.email -eq $email } | Select-Object -First 1
                if ($match) {
                    $name = if ($match.name) { [string]$match.name } else { '' }

                    # 1) a list of greetings -> pick one at random
                    if ($match.greetings -and @($match.greetings).Count -gt 0) {
                        $list = @($match.greetings)
                        $pick = $list[(Get-Random -Maximum $list.Count)]
                        return (& $fill ([string]$pick) $name)
                    }
                    # 2) a single explicit greeting
                    if ($match.greeting) {
                        return (& $fill ([string]$match.greeting) $name)
                    }
                    # 3) name only -> templated default
                    if ($name) {
                        return (& $fill $defaultTpl $name)
                    }
                }
            } catch { "WARN: users.json parse failed: $_" | Out-Default }
        }
        # unknown user (or no name): default template with {name} tidied away
        return (& $fill $defaultTpl '')
    }

    # --- instructions: render instructions.md -> HTML (editable, no rebuild) ---
    function Get-InstructionsHtml {
        $dir  = Get-PodeState -Name 'CfgDir'
        $path = Join-Path $dir 'instructions.md'
        if (-not (Test-Path $path)) { return '' }
        # cache the RENDERED html keyed by mtime so we don't re-render per hit
        $mtime = (Get-Item $path).LastWriteTimeUtc.Ticks
        $cacheKey = "mdcache::$path"
        $cached = $null
        try { $cached = Get-PodeState -Name $cacheKey } catch { }
        if ($cached -and $cached.Mtime -eq $mtime) { return $cached.Html }
        try {
            $html = (ConvertFrom-Markdown -Path $path).Html
            Set-PodeState -Name $cacheKey -Value @{ Mtime = $mtime; Html = $html } | Out-Null
            return $html
        } catch {
            "WARN: instructions.md render failed: $_" | Out-Default
            return ''
        }
    }

    # ------------------------------------------------------------------------
    #  IDENTITY: verify the Cloudflare Access JWT, return the email or $null.
    # ------------------------------------------------------------------------
    function Get-VerifiedUser {
        if ((Get-Cfg 'DASH_DEVMODE' 'false') -eq 'true') {
            return (Get-Cfg 'DASH_DEVEMAIL' 'rob@rob.me.uk')
        }

        $teamDomain = Get-Cfg 'CF_TEAM_DOMAIN' ''
        $accessAud  = Get-Cfg 'CF_ACCESS_AUD' ''
        if ([string]::IsNullOrWhiteSpace($teamDomain)) {
            "AUTH FAIL: CF_TEAM_DOMAIN not set" | Out-Default
            return $null
        }

        $jwt = Get-PodeHeader -Name 'Cf-Access-Jwt-Assertion'
        if ([string]::IsNullOrWhiteSpace($jwt)) {
            "AUTH FAIL: no Cf-Access-Jwt-Assertion header" | Out-Default
            return $null
        }

        $parts = $jwt.Split('.')
        if ($parts.Count -ne 3) { "AUTH FAIL: JWT not 3 parts (got $($parts.Count))" | Out-Default; return $null }

        function ConvertFrom-B64Url([string]$s) {
            $s = $s.Replace('-', '+').Replace('_', '/')
            switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
            return [Convert]::FromBase64String($s)
        }

        $header  = [Text.Encoding]::UTF8.GetString((ConvertFrom-B64Url $parts[0])) | ConvertFrom-Json
        $payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-B64Url $parts[1])) | ConvertFrom-Json

        # fetch + cache Cloudflare's signing keys (JWKS)
        $certsUrl = "$teamDomain/cdn-cgi/access/certs"
        $jwks = $null; $jwksAge = $null
        try { $jwks = Get-PodeState -Name 'jwks'; $jwksAge = Get-PodeState -Name 'jwksAt' } catch { }
        if (-not $jwks -or -not $jwksAge -or ((Get-Date) - $jwksAge).TotalMinutes -gt 60) {
            try {
                $jwks = Invoke-RestMethod -Uri $certsUrl -TimeoutSec 10
                Set-PodeState -Name 'jwks'   -Value $jwks      | Out-Null
                Set-PodeState -Name 'jwksAt' -Value (Get-Date) | Out-Null
            } catch {
                "AUTH FAIL: JWKS fetch failed from ${certsUrl}: $_" | Out-Default
                return $null
            }
        }

        $key = $jwks.keys | Where-Object { $_.kid -eq $header.kid } | Select-Object -First 1
        if (-not $key) { "AUTH FAIL: no JWKS key matching kid=$($header.kid)" | Out-Default; return $null }

        try {
            $rsa = [Security.Cryptography.RSA]::Create()
            $rsa.ImportParameters([Security.Cryptography.RSAParameters]@{
                Modulus  = ConvertFrom-B64Url $key.n
                Exponent = ConvertFrom-B64Url $key.e
            })
            $signed = [Text.Encoding]::ASCII.GetBytes("$($parts[0]).$($parts[1])")
            $sig    = ConvertFrom-B64Url $parts[2]
            $ok = $rsa.VerifyData($signed, $sig,
                [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            if (-not $ok) { "AUTH FAIL: signature did not verify" | Out-Default; return $null }
        } catch {
            "AUTH FAIL: signature verify threw: $_" | Out-Default
            return $null
        }

        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($payload.exp -and $payload.exp -lt $now) { "AUTH FAIL: token expired" | Out-Default; return $null }
        if ($payload.iss -and $payload.iss -ne $teamDomain) {
            "AUTH FAIL: issuer mismatch. token iss=$($payload.iss) expected=$teamDomain" | Out-Default; return $null
        }
        if ($accessAud) {
            $auds = @($payload.aud)
            if ($auds -notcontains $accessAud) {
                "AUTH FAIL: aud mismatch. token aud=$($auds -join ',') expected=$accessAud" | Out-Default; return $null
            }
        }

        if ($payload.email) { return [string]$payload.email }
        "AUTH FAIL: no email claim. claims=$($payload.PSObject.Properties.Name -join ',')" | Out-Default
        return $null
    }

    # ------------------------------------------------------------------------
    #  STORAGE
    # ------------------------------------------------------------------------
    function Get-PrefPath([string]$email) {
        $dir = Get-Cfg 'DASH_STATE_DIR' '/userprefs'
        $safe = $email -replace '[^a-zA-Z0-9@._-]', '_'
        return (Join-Path $dir "$safe.json")
    }

    function Get-UserPrefs([string]$email) {
        $defs = Get-PodeState -Name 'ToggleDefs'
        $path = Get-PrefPath $email
        $prefs = @{}
        foreach ($t in $defs) { $prefs[$t.Key] = $t.Default }
        if (Test-Path $path) {
            try {
                $existing = Get-Content $path -Raw | ConvertFrom-Json
                foreach ($t in $defs) {
                    if ($t.Expiry) {
                        # Expiry toggle: stored as "<Key>Until" = epoch-seconds expiry.
                        # 'on' iff that timestamp is in the future.
                        $untilKey = "$($t.Key)Until"
                        $until = $existing.$untilKey
                        if ($null -ne $until) {
                            $now = [int][double]::Parse((Get-Date -UFormat %s))
                            $prefs[$t.Key] = ([int64]$until -gt $now)
                        }
                    } elseif ($null -ne $existing.$($t.Key)) {
                        $prefs[$t.Key] = [bool]$existing.$($t.Key)
                    }
                }
            } catch { "Bad prefs file ${path}: $_" | Out-Default }
        }
        return $prefs
    }

    function Set-UserToggle([string]$email, [string]$key, [bool]$value) {
        $defs = Get-PodeState -Name 'ToggleDefs'
        $def  = $defs | Where-Object { $_.Key -eq $key } | Select-Object -First 1
        if (-not $def) { throw "Unknown toggle '$key'" }
        # Per-user restriction: if the toggle defines Users, only they may set it.
        if ($def.Users -and ($def.Users -notcontains $email)) {
            throw "Toggle '$key' is not available for $email"
        }
        $path = Get-PrefPath $email
        $lock = "$path.lock"
        $tries = 0
        while ((Test-Path $lock) -and $tries -lt 50) { Start-Sleep -Milliseconds 20; $tries++ }
        New-Item -ItemType File -Path $lock -Force | Out-Null
        try {
            # Read the raw existing JSON so we preserve all keys (incl. *Until).
            $raw = @{}
            if (Test-Path $path) {
                try {
                    $obj = Get-Content $path -Raw | ConvertFrom-Json
                    foreach ($p in $obj.PSObject.Properties) { $raw[$p.Name] = $p.Value }
                } catch { }
            }
            if ($def.Expiry) {
                # Expiry toggle: store an absolute expiry timestamp (epoch seconds).
                $untilKey = "$($key)Until"
                if ($value) {
                    $now = [int][double]::Parse((Get-Date -UFormat %s))
                    $raw[$untilKey] = $now + [int]$def.Expiry
                } else {
                    $raw[$untilKey] = 0   # cleared / in the past = off
                }
            } else {
                $raw[$key] = $value
            }
            ($raw | ConvertTo-Json) | Set-Content $path
        } finally {
            Remove-Item $lock -Force -ErrorAction SilentlyContinue
        }
    }

    # ------------------------------------------------------------------------
    #  STATIC ROUTE: screenshots for instructions.md
    #  Serves <config>/screenshots/* at /screenshots/* so markdown can use
    #  ![alt](/screenshots/foo.png) — a URL the browser can fetch, NOT a
    #  filesystem path (which the browser can't read).
    # ------------------------------------------------------------------------
    $shotsDir = Join-Path (Get-PodeState -Name 'CfgDir') 'screenshots'
    if (Test-Path $shotsDir) {
        Add-PodeStaticRoute -Path '/screenshots' -Source $shotsDir
    } else {
        "NOTE: screenshots dir not found at $shotsDir — /screenshots route not added" | Out-Default
    }

    # ------------------------------------------------------------------------
    #  ROUTE: dashboard page
    # ------------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
      try {
        $email = Get-VerifiedUser
        if (-not $email) {
            Write-PodeTextResponse -Value 'Not authenticated.' -StatusCode 401
            return
        }
        $prefs    = Get-UserPrefs $email
        $greeting = Resolve-Greeting $email
        $links    = Get-PodeState -Name 'DashLinks'
        $defs     = Get-PodeState -Name 'ToggleDefs'

        $linksHtml = ($links | ForEach-Object {
            "<a href=`"$($_.Url)`" class=`"custom-link`">$($_.Title)</a>"
        }) -join "`n"

        $togglesHtml = ($defs | Where-Object {
            -not $_.Users -or ($_.Users -contains $email)
        } | ForEach-Object {
            $checked = if ($prefs[$_.Key]) { 'checked' } else { '' }
            @"
<label class="toggle">
  <input type="checkbox" data-key="$($_.Key)" $checked onchange="saveToggle(this)" />
  <span>$($_.Label)</span>
</label>
"@
        }) -join "`n"

        $instructionsHtml = Get-InstructionsHtml

        # Read the editable template (cached by mtime: fast loads, edits show on
        # refresh, no rebuild). Lives in the local config dir. Falls back to a
        # minimal page if missing, logging where it looked.
        $cfgDir  = Get-PodeState -Name 'CfgDir'
        $tplPath = Join-Path $cfgDir 'template.html'
        $html    = Read-CachedFile $tplPath
        if (-not $html) {
            "TEMPLATE ERROR: $tplPath not found — serving minimal fallback page" | Out-Default
            $html = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>...Gunit!</title></head>
<body style="font-family:sans-serif;background:#1c1f24;color:#ccc;padding:40px">
<h1>...Gunit!</h1><p>{{GREETING}}</p><p>Signed in as {{EMAIL}}</p>
{{LINKS}}<h2>My Settings</h2>{{TOGGLES}}<p id="status"></p>
<div>{{INSTRUCTIONS}}</div>
<p style="opacity:.5">(template file not found at $tplPath)</p>
<script>
async function saveToggle(el){const s=document.getElementById('status');s.innerText='Saving...';
try{const r=await fetch('/toggle',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({key:el.dataset.key,value:el.checked})});s.innerText=r.ok?'Saved.':'Error saving.';
if(!r.ok)el.checked=!el.checked;}catch(e){s.innerText='Network error.';el.checked=!el.checked;}
setTimeout(()=>{s.innerText='';},2500);}
</script></body></html>
"@
        }

        # Substitute the dynamic tokens.
        $html = $html.Replace('{{GREETING}}',     [string]$greeting).
                      Replace('{{EMAIL}}',        [string]$email).
                      Replace('{{INSTRUCTIONS}}', [string]$instructionsHtml).
                      Replace('{{LINKS}}',    $linksHtml).
                      Replace('{{TOGGLES}}',  $togglesHtml)

        Write-PodeHtmlResponse -Value $html
      } catch {
        Write-PodeTextResponse -StatusCode 500 -Value "ERROR in GET /: $($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
      }
    }

    # ------------------------------------------------------------------------
    #  ROUTE: flip one toggle for the current user
    # ------------------------------------------------------------------------
    Add-PodeRoute -Method Post -Path '/toggle' -ScriptBlock {
        $email = Get-VerifiedUser
        if (-not $email) { Write-PodeTextResponse -Value 'Not authenticated' -StatusCode 401; return }
        $key   = $WebEvent.Data.key
        $value = [bool]$WebEvent.Data.value
        try {
            Set-UserToggle -email $email -key $key -value $value
            Write-PodeJsonResponse -Value @{ ok = $true; key = $key; value = $value }
        } catch {
            Write-PodeTextResponse -Value "$_" -StatusCode 400
        }
    }

    # ------------------------------------------------------------------------
    #  ROUTE: JSON API for the pipeline to query prefs (optional)
    # ------------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/prefs' -ScriptBlock {
        $email = Get-VerifiedUser
        if (-not $email) { Write-PodeTextResponse -Value 'Not authenticated' -StatusCode 401; return }
        Write-PodeJsonResponse -Value (Get-UserPrefs $email)
    }
}