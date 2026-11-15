# PokeVeille 30 ans - moniteur de stock Pokemon (Windows PowerShell 5.1, aucune installation requise)
# Lancement : double-cliquer sur "Lancer PokeVeille.bat"  (ou: powershell -ExecutionPolicy Bypass -File server.ps1)
param(
    [int]$Port = 8730,
    [switch]$NoBrowser,
    [switch]$Once,
    [switch]$TestNotification
)
# Fonctionne aussi sous Linux avec PowerShell 7 (serveur Oracle Cloud) : voir le dossier "serveur".
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root          = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir       = Join-Path $Root 'data'
$WebDir        = Join-Path $Root 'web'
$ConfigPath    = Join-Path $Root 'config.json'
$CataloguePath = Join-Path $Root 'catalogue.json'
$StatePath     = Join-Path $DataDir 'state.json'
$LogPath       = Join-Path $DataDir 'journal.txt'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Inv = [Globalization.CultureInfo]::InvariantCulture

# Titre "30 ans" (titres normalises : minuscules, sans accents)
$Rx30     = '\b30\s*(e|eme|ieme|th)?\s*(anniversaire|anniversary|celebration)|\b30\s*ans\b'
$RxPoke   = 'pokemon|pokebox'
$RxMagasin = 'en magasin|en boutique|\bmagasins?\b|\bdrive\b|retrait|\blocal\b|\[local\]'

$Script:Logs = New-Object System.Collections.ArrayList

function Write-Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    [void]$Script:Logs.Add($line)
    while ($Script:Logs.Count -gt 300) { $Script:Logs.RemoveAt(0) }
    try { [IO.File]::AppendAllText($LogPath, $line + "`r`n", $Utf8) } catch {}
}

function Read-Json([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-Log "JSON illisible: $path ($($_.Exception.Message))"; return $null }
}

function Write-Json([string]$path, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 12
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $json, $Utf8)
    Move-Item -Path $tmp -Destination $path -Force
}

function Normalize([string]$s) {
    if (-not $s) { return '' }
    $d = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    return ($sb.ToString().ToLowerInvariant() -replace '[\u2019`]', "'")
}

function Clean-Html([string]$s) {
    if (-not $s) { return '' }
    $s = $s -replace '(?s)<[^>]+>', ' '
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    return ($s -replace '\s+', ' ').Trim()
}

function Parse-Price($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v) -replace '[^\d,\.]', ''
    if (-not $s) { return $null }
    if ($s -match ',\d{1,2}$') { $s = $s -replace '\.', '' -replace ',', '.' } else { $s = $s -replace ',', '' }
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return [math]::Round($d, 2) }
    return $null
}

function Get-Web([string]$Url) {
    $r = Invoke-WebRequest -Uri $Url -UserAgent $UA -UseBasicParsing -TimeoutSec 25 -Headers @{ 'Accept-Language' = 'fr-FR,fr;q=0.9' }
    $text = $Utf8.GetString($r.RawContentStream.ToArray())
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Text = $text }
}

function Pause-Polite { Start-Sleep -Milliseconds (Get-Random -Minimum 800 -Maximum 1800) }

# ---------------------------------------------------------------- etat
$Script:Config = $null
$Script:Catalogue = $null
$Script:Items = @{}
$Script:Deals = @{}
$Script:Alerts = New-Object System.Collections.ArrayList
$Script:Sources = @{}
$Script:LastScan = $null
$Script:NextScan = Get-Date
$Script:Scanning = $false
$Script:ScanRequested = $false
$Script:AlertSeq = 0

function Load-All {
    $Script:Config = Read-Json $ConfigPath
    if (-not $Script:Config) { throw "config.json introuvable ou invalide" }
    # Secrets fournis par l'environnement (GitHub Actions) : jamais ecrits dans le depot public
    if ($env:NTFY_TOPIC)      { $Script:Config.notifications | Add-Member -NotePropertyName ntfyTopic -NotePropertyValue $env:NTFY_TOPIC -Force }
    if ($env:DISCORD_WEBHOOK) { $Script:Config.notifications | Add-Member -NotePropertyName discordWebhook -NotePropertyValue $env:DISCORD_WEBHOOK -Force }
    $Script:Catalogue = Read-Json $CataloguePath
    if (-not $Script:Catalogue) { $Script:Catalogue = [pscustomobject]@{ produits = @() } }
}

function Load-State {
    $st = Read-Json $StatePath
    if (-not $st) { return }
    foreach ($i in @($st.items)) { if ($i -and $i.key) { $Script:Items[$i.key] = $i } }
    foreach ($d in @($st.deals)) { if ($d -and $d.key) { $Script:Deals[$d.key] = $d } }
    foreach ($a in @($st.alerts)) { if ($a) { [void]$Script:Alerts.Add($a); if ($a.id -gt $Script:AlertSeq) { $Script:AlertSeq = [int]$a.id } } }
    $Script:LastScan = $st.lastScan
}

function Save-State {
    $obj = [ordered]@{
        lastScan = $Script:LastScan
        items    = @($Script:Items.Values)
        deals    = @($Script:Deals.Values)
        alerts   = @($Script:Alerts)
    }
    Write-Json $StatePath $obj
}

# ---------------------------------------------------------------- correspondance catalogue
function Match-Catalogue([string]$title) {
    $n = Normalize $title
    foreach ($p in @($Script:Catalogue.produits)) {
        if ($p.motif -and ($n -match $p.motif)) { return $p }
    }
    return $null
}

function Get-Verdict($inStock, $price, $prixRef) {
    if (-not $inStock) { return 'rupture' }
    if ($null -eq $prixRef -or $null -eq $price) { return 'dispo-sans-ref' }
    $tol = [double]$Script:Config.tolerancePourcent
    if ($price -le [math]::Round($prixRef * (1 + $tol / 100), 2)) { return 'prix-magasin' }
    return 'prix-gonfle'
}

function Is-Relevant([string]$title, [bool]$requirePokemon) {
    $n = Normalize $title
    if ($n -notmatch $Rx30) { return $false }
    if ($requirePokemon -and $n -notmatch $RxPoke) { return $false }
    $ex = [string]$Script:Config.exclure
    if ($ex -and $n -match $ex) { return $false }
    return $true
}

# ---------------------------------------------------------------- alertes
function Add-Alert([string]$type, [string]$title, [string]$message, [string]$url, [string]$image, [bool]$magasin) {
    $Script:AlertSeq++
    $a = [pscustomobject]@{
        id = $Script:AlertSeq; type = $type; titre = $title; message = $message; url = $url; image = $image
        magasin = $magasin; date = (Get-Date).ToString('s')
    }
    [void]$Script:Alerts.Add($a)
    while ($Script:Alerts.Count -gt 300) { $Script:Alerts.RemoveAt(0) }
    return $a
}

function Send-Toast([string]$title, [string]$body, [string]$url) {
    if (-not $OnWindows) { return }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [Security.SecurityElement]::Escape($title)
        $b = [Security.SecurityElement]::Escape($body)
        $u = [Security.SecurityElement]::Escape($(if ($url) { $url } else { "http://localhost:$Port/" }))
        $xml = "<toast activationType='protocol' launch='$u' duration='long'><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual><audio src='ms-winsoundevent:Notification.Reminder'/><actions><action content='Ouvrir' activationType='protocol' arguments='$u'/></actions></toast>"
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
        $Script:ToastSetting = [string]$notifier.Setting
        if ($Script:ToastSetting -ne 'Enabled') { Write-Log "Notifications Windows desactivees ($($Script:ToastSetting)) : activez-les dans Parametres > Systeme > Notifications" }
        $notifier.Show($toast)
    } catch { Write-Log "Notification Windows impossible: $($_.Exception.Message)" }
}

function Get-ToastSetting {
    if (-not $OnWindows) { return 'Serveur' }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        return [string][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Setting
    } catch { return 'Inconnu' }
}

function Send-Popup([string]$title, [string]$msg, [string]$url) {
    if (-not $OnWindows) { return }
    try {
        $f = Join-Path $DataDir ('popup-' + [guid]::NewGuid().ToString('N') + '.json')
        Write-Json $f ([ordered]@{ titre = $title; message = $msg; url = $url })
        # Ne pas utiliser Start-Process -WindowStyle Hidden : Windows appliquerait SW_HIDE a la fenetre d'alerte elle-meme.
        # C'est powershell.exe qui masque sa propre console (-WindowStyle Hidden en argument).
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + (Join-Path $Root 'popup.ps1') + '"'), '-File', ('"' + $f + '"')) | Out-Null
    } catch { Write-Log "Fenetre d'alerte impossible: $($_.Exception.Message)" }
}

function Send-Ntfy([string]$title, [string]$msg, [string]$url, [int]$prio) {
    $n = $Script:Config.notifications
    if (-not $n.ntfyTopic) { return }
    # quand GitHub envoie deja les alertes au telephone, le PC peut s'abstenir (evite les doublons)
    if ($OnWindows -and $n.ntfyDepuisPC -eq $false) { return }
    $server = if ($n.ntfyServeur) { ([string]$n.ntfyServeur).TrimEnd('/') } else { 'https://ntfy.sh' }
    $p = [ordered]@{ topic = [string]$n.ntfyTopic; title = $title; message = $msg; priority = $prio; tags = @('rotating_light') }
    if ($url) { $p.click = $url; $p.actions = @(@{ action = 'view'; label = 'Ouvrir'; url = $url }) }
    try {
        $bytes = $Utf8.GetBytes((ConvertTo-Json -InputObject $p -Depth 5))
        Invoke-RestMethod -Uri $server -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 | Out-Null
    } catch { Write-Log "ntfy en echec: $($_.Exception.Message)" }
}

function Send-Discord([string]$title, [string]$msg, [string]$url) {
    $hook = [string]$Script:Config.notifications.discordWebhook
    if (-not $hook) { return }
    $content = "**$title**`n$msg"
    if ($url) { $content += "`n$url" }
    try {
        $bytes = $Utf8.GetBytes((ConvertTo-Json -InputObject @{ content = $content }))
        Invoke-RestMethod -Uri $hook -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 | Out-Null
    } catch { Write-Log "Discord en echec: $($_.Exception.Message)" }
}

function Notify-All([string]$title, [string]$msg, [string]$url, [int]$prio = 4) {
    if ($Script:Config.notifications.windows) { Send-Toast $title $msg $url }
    if ($Script:Config.notifications.fenetre -ne $false) { Send-Popup $title $msg $url }
    Send-Ntfy $title $msg $url $prio
    Send-Discord $title $msg $url
}

function Dispatch-Alerts($newAlerts) {
    $list = @($newAlerts)
    if ($list.Count -eq 0) { return }
    if ($list.Count -le 3) {
        foreach ($a in $list) { Notify-All $a.titre $a.message $a.url $(if ($a.type -eq 'prix-magasin' -or $a.magasin) { 5 } else { 4 }) }
    } else {
        $names = ($list | Select-Object -First 5 | ForEach-Object { '- ' + $_.titre + ' : ' + $_.message }) -join "`n"
        $link = if ($OnWindows) { "http://localhost:$Port/" } else { $list[0].url }
        Notify-All ("PokeVeille : {0} nouvelles alertes" -f $list.Count) $names $link 4
    }
}

# ---------------------------------------------------------------- mise a jour d'un produit
function Upsert-Item($src, $srcLabel, $id, $title, $url, $image, $price, $inStock, $seller, $stockQty, $newAlerts) {
    $key = "$src|$id"
    $cat = Match-Catalogue $title
    $prixRef = if ($cat) { [double]$cat.prixRef } else { $null }
    $verdict = Get-Verdict $inStock $price $prixRef
    $now = (Get-Date).ToString('s')
    $prev = $Script:Items[$key]
    $prevVerdict = if ($prev) { $prev.statut } else { $null }

    $item = [pscustomobject]@{
        key = $key; source = $src; sourceLabel = $srcLabel; id = $id; titre = $title; url = $url; image = $image
        prix = $price; prixRef = $prixRef; catalogueId = $(if ($cat) { $cat.id } else { $null }); catalogueNom = $(if ($cat) { $cat.nom } else { $null })
        enStock = [bool]$inStock; stock = $stockQty; vendeur = $seller; statut = $verdict
        premiereVue = $(if ($prev) { $prev.premiereVue } else { $now }); derniereVue = $now
        dernierChangement = $(if ($prev -and $prevVerdict -eq $verdict -and $prev.prix -eq $price) { $prev.dernierChangement } else { $now })
    }
    $Script:Items[$key] = $item

    $wantAlert = $false
    if ($verdict -eq 'prix-magasin' -and $prevVerdict -ne 'prix-magasin') { $wantAlert = $true }
    if ($verdict -eq 'dispo-sans-ref' -and $prevVerdict -notin @('dispo-sans-ref', 'prix-magasin') -and $Script:Config.alerterSansReference) { $wantAlert = $true }
    if ($wantAlert) {
        $pTxt = if ($null -ne $price) { ('{0:N2} EUR' -f $price) } else { 'prix ?' }
        $refTxt = if ($null -ne $prixRef) { (' (ref. {0:N2})' -f $prixRef) } else { '' }
        $msg = "Disponible chez $srcLabel" + $(if ($seller) { " / $seller" } else { '' }) + " a $pTxt$refTxt"
        [void]$newAlerts.Add((Add-Alert $verdict $title $msg $url $image $false))
    }
}

function Mark-Missing($src, $seenKeys) {
    foreach ($k in @($Script:Items.Keys)) {
        $it = $Script:Items[$k]
        if ($it.source -eq $src -and -not $seenKeys.Contains($k) -and $it.enStock) {
            # les resultats de recherche varient d'un appel a l'autre : rupture seulement apres 3 absences
            $abs = 1 + [int]($it.PSObject.Properties['absences'] | ForEach-Object { $_.Value })
            $it | Add-Member -NotePropertyName absences -NotePropertyValue $abs -Force
            if ($abs -ge 3) { $it.enStock = $false; $it.statut = 'rupture'; $it.dernierChangement = (Get-Date).ToString('s') }
        }
    }
}

# ---------------------------------------------------------------- sources
function Scan-Auchan($newAlerts) {
    $cfg = $Script:Config.sources.auchan
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $count = 0
    foreach ($q in @($cfg.requetes)) {
        $res = Get-Web ('https://www.auchan.fr/recherche?text=' + [uri]::EscapeDataString($q))
        $arts = [regex]::Matches($res.Text, '(?s)<article[^>]*product-thumbnail[^>]*>.*?</article>')
        foreach ($m in $arts) {
            $h = $m.Value
            $id = ([regex]::Match($h, 'data-id="([^"]+)"')).Groups[1].Value
            $href = ([regex]::Match($h, 'href="(/[^"]+/pr-[^"]+)"')).Groups[1].Value
            $title = Clean-Html (([regex]::Match($h, '(?s)itemprop="name description">(.*?)</p>')).Groups[1].Value)
            if (-not $id -or -not $title) { continue }
            if (-not (Is-Relevant $title $true)) { continue }
            $price = Parse-Price (([regex]::Match($h, 'itemprop="price" content="([^"]+)"')).Groups[1].Value)
            $avail = ([regex]::Match($h, 'itemprop="availability" content="([^"]+)"')).Groups[1].Value
            $sellerM = [regex]::Match($h, 'marketplace-label-link">([^<]+)<')
            $seller = if ($sellerM.Success) { Clean-Html $sellerM.Groups[1].Value } else { 'Auchan' }
            $stockM = [regex]::Match($h, 'data-stock="(\d+)"')
            $stockQty = if ($stockM.Success) { [int]$stockM.Groups[1].Value } else { $null }
            $img = [System.Net.WebUtility]::HtmlDecode(([regex]::Match($h, 'itemprop="image" content="([^"]+)"')).Groups[1].Value) -replace 'width=2048&height=2048', 'width=300&height=300'
            $inStock = ($avail -match 'InStock') -and ($stockQty -ne 0)
            Upsert-Item 'auchan' 'Auchan' $id $title ('https://www.auchan.fr' + $href) $img $price $inStock $seller $stockQty $newAlerts
            [void]$seen.Add("auchan|$id"); $count++
        }
        Pause-Polite
    }
    Mark-Missing 'auchan' $seen
    return "$($seen.Count) produits 30 ans"
}

function Scan-Shopify($newAlerts) {
    $cfg = $Script:Config.sources.shopify
    $total = 0
    foreach ($shopRaw in @($cfg.boutiques)) {
        $shop = ([string]$shopRaw).TrimEnd('/')
        if (-not $shop) { continue }
        $hostName = ([uri]$shop).Host -replace '^www\.', ''
        $src = "shopify:$hostName"
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($q in @($cfg.requetes)) {
            $u = "$shop/search/suggest.json?q=" + [uri]::EscapeDataString($q) + '&resources[type]=product&resources[limit]=10&resources[options][unavailable_products]=last'
            $res = Get-Web $u
            $json = $res.Text | ConvertFrom-Json
            foreach ($p in @($json.resources.results.products)) {
                if (-not $p) { continue }
                if (-not (Is-Relevant $p.title $false)) { continue }
                $id = [string]$p.id
                if ($seen.Contains("$src|$id")) { continue }
                $img = [string]$p.image
                if ($img.StartsWith('//')) { $img = 'https:' + $img }
                $url = [string]$p.url
                if ($url.StartsWith('/')) { $url = $shop + ($url -replace '\?.*$', '') }
                Upsert-Item $src $hostName $id $p.title $url $img (Parse-Price $p.price) ([bool]$p.available) $hostName $null $newAlerts
                [void]$seen.Add("$src|$id")
            }
            Pause-Polite
        }
        Mark-Missing $src $seen
        $total += $seen.Count
    }
    return "$total produits 30 ans"
}

function Scan-Dealabs($newAlerts) {
    $cfg = $Script:Config.sources.dealabs
    $n = 0
    foreach ($feed in @($cfg.flux)) {
        if (-not $feed) { continue }
        $res = Get-Web ([string]$feed)
        foreach ($m in [regex]::Matches($res.Text, '(?s)<item>(.*?)</item>')) {
            $x = $m.Groups[1].Value
            $title = Clean-Html (([regex]::Match($x, '(?s)<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>')).Groups[1].Value)
            $link = ([regex]::Match($x, '<link>([^<]+)</link>')).Groups[1].Value.Trim()
            if (-not $title -or -not $link) { continue }
            if (-not (Is-Relevant $title $true)) { continue }
            $n++
            $key = "dealabs|$link"
            if ($Script:Deals.ContainsKey($key)) { continue }
            $desc = Clean-Html (([regex]::Match($x, '(?s)<description>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</description>')).Groups[1].Value)
            $merchM = [regex]::Match($x, '<pepper:merchant name="([^"]*)"(?: price="([^"]*)")?')
            $merchant = if ($merchM.Success) { [System.Net.WebUtility]::HtmlDecode($merchM.Groups[1].Value) } else { '' }
            $price = if ($merchM.Success) { Parse-Price $merchM.Groups[2].Value } else { $null }
            $img = ([regex]::Match($x, '<media:content[^>]*url="([^"]+)"')).Groups[1].Value
            $pub = ([regex]::Match($x, '<pubDate>([^<]+)</pubDate>')).Groups[1].Value
            $magasin = (Normalize ($title + ' ' + $desc.Substring(0, [math]::Min(400, $desc.Length)))) -match $RxMagasin
            $cat = Match-Catalogue $title
            $prixRef = if ($cat) { [double]$cat.prixRef } else { $null }
            $d = [pscustomobject]@{
                key = $key; titre = $title; url = $link; image = $img; marchand = $merchant; prix = $price; prixRef = $prixRef
                catalogueNom = $(if ($cat) { $cat.nom } else { $null }); magasin = $magasin; publie = $pub; vu = (Get-Date).ToString('s')
                extrait = $desc.Substring(0, [math]::Min(220, $desc.Length))
            }
            $Script:Deals[$key] = $d
            $pTxt = if ($null -ne $price) { ('{0:N2} EUR' -f $price) } else { 'prix non indique' }
            $msg = $(if ($magasin) { 'EN MAGASIN - ' } else { '' }) + "Signalement Dealabs : $merchant $pTxt"
            [void]$newAlerts.Add((Add-Alert $(if ($magasin) { 'magasin' } else { 'signalement' }) $title $msg $link $img $magasin))
        }
        Pause-Polite
    }
    # garder les 200 plus recents
    if ($Script:Deals.Count -gt 200) {
        $old = $Script:Deals.Values | Sort-Object vu | Select-Object -First ($Script:Deals.Count - 200)
        foreach ($o in $old) { $Script:Deals.Remove($o.key) }
    }
    return "$n signalements 30 ans dans le flux"
}

function Scan-Pages($newAlerts) {
    $cfg = $Script:Config.sources.surveillance
    $ok = 0; $blocked = 0
    foreach ($pg in @($cfg.pages)) {
        if (-not $pg -or -not $pg.url) { continue }
        $url = [string]$pg.url
        $id = $url
        $hostName = 'page'
        try { $hostName = ([uri]$url).Host -replace '^www\.', '' } catch {}
        $title = if ($pg.nom) { [string]$pg.nom } else { $url }
        try {
            $res = Get-Web $url
            $h = $res.Text
            if ($res.Status -ne 200 -or $h.Length -lt 3000) { throw "reponse anti-robot ($($res.Status), $($h.Length) octets)" }
            if (-not $pg.nom) {
                $t = ([regex]::Match($h, '<meta property="og:title" content="([^"]+)"')).Groups[1].Value
                if (-not $t) { $t = ([regex]::Match($h, '(?s)<title>(.*?)</title>')).Groups[1].Value }
                if ($t) { $title = Clean-Html $t }
            }
            $avail = ([regex]::Match($h, '"availability"\s*:\s*"([^"]+)"|itemprop="availability"[^>]*(?:content|href)="([^"]+)"'))
            $availTxt = $avail.Groups[1].Value + $avail.Groups[2].Value
            $priceM = [regex]::Match($h, '"price"\s*:\s*"?([\d.,]+)|itemprop="price"[^>]*content="([\d.,]+)"')
            $price = Parse-Price ($priceM.Groups[1].Value + $priceM.Groups[2].Value)
            $img = ([regex]::Match($h, '<meta property="og:image" content="([^"]+)"')).Groups[1].Value
            $inStock = $availTxt -match 'InStock|LimitedAvailability|InStoreOnly|PreOrder'
            if (-not $availTxt) { throw "disponibilite introuvable sur la page" }
            # prix de reference specifique a la page s'il est fourni
            if ($pg.prixRef) {
                $verdict = Get-Verdict $inStock $price ([double]$pg.prixRef)
            }
            Upsert-Item 'page' $hostName $id $title $url $img $price $inStock $hostName $null $newAlerts
            if ($pg.prixRef) {
                $it = $Script:Items["page|$id"]; $it.prixRef = [double]$pg.prixRef; $it.statut = $verdict
            }
            $ok++
        } catch {
            $blocked++
            $key = "page|$id"
            $prev = $Script:Items[$key]
            $Script:Items[$key] = [pscustomobject]@{
                key = $key; source = 'page'; sourceLabel = $hostName; id = $id; titre = $title; url = $url; image = $(if ($prev) { $prev.image } else { '' })
                prix = $null; prixRef = $(if ($pg.prixRef) { [double]$pg.prixRef } else { $null }); catalogueId = $null; catalogueNom = $null
                enStock = $false; stock = $null; vendeur = $hostName; statut = 'bloque'; erreur = $_.Exception.Message
                premiereVue = $(if ($prev) { $prev.premiereVue } else { (Get-Date).ToString('s') }); derniereVue = (Get-Date).ToString('s'); dernierChangement = (Get-Date).ToString('s')
            }
        }
        Pause-Polite
    }
    # retirer les pages supprimees de la config
    $urls = @(@($cfg.pages) | ForEach-Object { [string]$_.url })
    foreach ($k in @($Script:Items.Keys)) { if ($Script:Items[$k].source -eq 'page' -and $urls -notcontains $Script:Items[$k].id) { $Script:Items.Remove($k) } }
    return "$ok pages lues, $blocked bloquees"
}

function Run-Scan {
    $Script:Scanning = $true
    try {
        Load-All
        # recalculer les verdicts avec le catalogue / la tolerance a jour
        foreach ($it in @($Script:Items.Values)) {
            if ($it.source -eq 'page' -or $it.statut -eq 'bloque') { continue }
            if (-not (Is-Relevant $it.titre $false)) { $Script:Items.Remove($it.key); continue }
            $cat = Match-Catalogue $it.titre
            $it.prixRef = if ($cat) { [double]$cat.prixRef } else { $null }
            $it.catalogueNom = if ($cat) { $cat.nom } else { $null }
            $it.statut = Get-Verdict $it.enStock $it.prix $it.prixRef
        }
        $newAlerts = New-Object System.Collections.ArrayList
        $plan = @(
            @{ name = 'auchan';       label = 'Auchan';                 fn = { param($a) Scan-Auchan $a } },
            @{ name = 'shopify';      label = 'Boutiques Shopify';      fn = { param($a) Scan-Shopify $a } },
            @{ name = 'dealabs';      label = 'Dealabs (signalements)'; fn = { param($a) Scan-Dealabs $a } },
            @{ name = 'surveillance'; label = 'Pages surveillees';      fn = { param($a) Scan-Pages $a } }
        )
        foreach ($s in $plan) {
            $cfg = $Script:Config.sources.($s.name)
            if (-not $cfg -or -not $cfg.actif) { $Script:Sources[$s.name] = @{ label = $s.label; etat = 'desactive'; detail = ''; date = $null }; continue }
            try {
                $detail = & $s.fn $newAlerts
                $Script:Sources[$s.name] = @{ label = $s.label; etat = 'ok'; detail = [string]$detail; date = (Get-Date).ToString('s') }
                Write-Log ("[{0}] {1}" -f $s.label, $detail)
            } catch {
                $Script:Sources[$s.name] = @{ label = $s.label; etat = 'erreur'; detail = $_.Exception.Message; date = (Get-Date).ToString('s') }
                Write-Log ("[{0}] ERREUR : {1}" -f $s.label, $_.Exception.Message)
            }
        }
        $Script:LastScan = (Get-Date).ToString('s')
        Save-State
        if ($newAlerts.Count -gt 0) { Write-Log ("{0} nouvelle(s) alerte(s)" -f $newAlerts.Count) }
        Dispatch-Alerts $newAlerts
    } finally {
        $Script:Scanning = $false
        $mins = [double]$Script:Config.intervalleMinutes
        if ($mins -lt 2) { $mins = 2 }
        $Script:NextScan = (Get-Date).AddSeconds($mins * 60 + (Get-Random -Minimum 0 -Maximum 40))
    }
}

# ---------------------------------------------------------------- serveur HTTP local
function Send-Response($ctx, [int]$code, [string]$contentType, [string]$body) {
    $bytes = $Utf8.GetBytes($body)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $contentType
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-JsonResponse($ctx, $obj) { Send-Response $ctx 200 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $obj -Depth 12 -Compress) }

function Read-Body($ctx) {
    $sr = New-Object System.IO.StreamReader($ctx.Request.InputStream, $Utf8)
    $t = $sr.ReadToEnd(); $sr.Close(); return $t
}

function Handle-Request($ctx) {
    $path = $ctx.Request.Url.AbsolutePath
    $method = $ctx.Request.HttpMethod
    try {
        # protection basique : uniquement les requetes venant de la page locale
        if ($method -eq 'POST') {
            $origin = $ctx.Request.Headers['Origin']
            if ($origin -and $origin -notmatch '^http://(localhost|127\.0\.0\.1):\d+$') { Send-Response $ctx 403 'text/plain' 'interdit'; return }
        }
        switch -Regex ("$method $path") {
            '^GET /$' {
                Send-Response $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllText((Join-Path $WebDir 'index.html'), $Utf8)); break
            }
            '^GET /api/etat$' {
                Send-JsonResponse $ctx ([ordered]@{
                    derniereAnalyse = $Script:LastScan
                    prochaineAnalyse = $Script:NextScan.ToString('s')
                    analyseEnCours = ($Script:Scanning -or $Script:ScanRequested)
                    notificationsWindows = $Script:ToastSetting
                    produits = @($Script:Items.Values)
                    signalements = @($Script:Deals.Values | Sort-Object vu -Descending)
                    alertes = @($Script:Alerts | Select-Object -Last 100)
                    sources = $Script:Sources
                    config = $Script:Config
                    catalogue = $Script:Catalogue
                    journal = @($Script:Logs | Select-Object -Last 60)
                }); break
            }
            '^POST /api/analyser$' { $Script:ScanRequested = $true; Send-JsonResponse $ctx @{ ok = $true }; break }
            '^POST /api/config$' {
                $obj = (Read-Body $ctx) | ConvertFrom-Json
                if (-not $obj.sources) { throw 'configuration invalide' }
                Write-Json $ConfigPath $obj; Load-All
                Write-Log 'Configuration enregistree'
                Send-JsonResponse $ctx @{ ok = $true }; break
            }
            '^POST /api/catalogue$' {
                $obj = (Read-Body $ctx) | ConvertFrom-Json
                if ($null -eq $obj.produits) { throw 'catalogue invalide' }
                Write-Json $CataloguePath $obj; Load-All
                foreach ($it in @($Script:Items.Values)) {
                    if ($it.source -eq 'page' -or $it.statut -eq 'bloque') { continue }
                    $cat = Match-Catalogue $it.titre
                    $it.prixRef = if ($cat) { [double]$cat.prixRef } else { $null }
                    $it.catalogueNom = if ($cat) { $cat.nom } else { $null }
                    $it.statut = Get-Verdict $it.enStock $it.prix $it.prixRef
                }
                Write-Log 'Catalogue enregistre'
                Send-JsonResponse $ctx @{ ok = $true }; break
            }
            '^POST /api/test-notification$' {
                Notify-All 'PokeVeille : test' 'Si vous lisez ceci, les alertes fonctionnent.' "http://localhost:$Port/" 3
                Send-JsonResponse $ctx @{ ok = $true }; break
            }
            '^POST /api/effacer-alertes$' {
                $Script:Alerts.Clear(); Save-State; Send-JsonResponse $ctx @{ ok = $true }; break
            }
            default { Send-Response $ctx 404 'text/plain; charset=utf-8' 'introuvable' }
        }
    } catch {
        Write-Log "Erreur requete $method $path : $($_.Exception.Message)"
        try { Send-Response $ctx 500 'application/json; charset=utf-8' (ConvertTo-Json @{ ok = $false; erreur = $_.Exception.Message }) } catch {}
    }
}

# ---------------------------------------------------------------- demarrage
Load-All
Load-State
$Script:ToastSetting = Get-ToastSetting

if ($TestNotification) {
    $where = if ($OnWindows) { 'votre PC' } else { 'le serveur' }
    Notify-All 'PokeVeille : test' "Les alertes envoyees par $where fonctionnent." $null 3
    Write-Log "Notification de test envoyee"
    return
}
if ($Once) { Run-Scan; return }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch {
    Write-Host "Impossible d'ouvrir le port $Port (PokeVeille deja lance ?). Ouverture du tableau de bord..." -ForegroundColor Yellow
    Start-Process "http://localhost:$Port/"; Start-Sleep 3; return
}

try { $Host.UI.RawUI.WindowTitle = "PokeVeille 30 ans - http://localhost:$Port" } catch {}
Write-Log "PokeVeille demarre sur http://localhost:$Port/  (laisser cette fenetre ouverte, Ctrl+C pour arreter)"
if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }

$ctxTask = $listener.GetContextAsync()
try {
    while ($listener.IsListening) {
        if ($ctxTask.Wait(400)) {
            Handle-Request $ctxTask.Result
            $ctxTask = $listener.GetContextAsync()
        }
        if ($Script:ScanRequested -or (Get-Date) -ge $Script:NextScan) {
            $Script:ScanRequested = $false
            Run-Scan
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
}
