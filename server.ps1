# PokeVeille 30 ans - moniteur de stock Pokemon (Windows PowerShell 5.1, aucune installation requise)
# Lancement : double-cliquer sur "Lancer PokeVeille.bat"  (ou: powershell -ExecutionPolicy Bypass -File server.ps1)
param(
    [int]$Port = 8730,
    [switch]$NoBrowser,
    [switch]$Once,
    [switch]$TestNotification,
    [string]$Export   # avec -Once : ecrit l'etat public (sans secrets) dans ce fichier JSON, pour la page mobile
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

# Pause entre deux requetes ; si le tableau de bord local tourne, on en profite pour lui repondre
# (sinon il resterait bloque pendant toute l'analyse).
function Pause-Polite {
    $ms = Get-Random -Minimum 400 -Maximum 900
    if (-not $Script:Listener) { Start-Sleep -Milliseconds $ms; return }
    $end = (Get-Date).AddMilliseconds($ms)
    do {
        $left = [int][math]::Max(1, ($end - (Get-Date)).TotalMilliseconds)
        if ($Script:CtxTask.Wait($left)) {
            $ctx = $Script:CtxTask.Result
            $Script:CtxTask = $Script:Listener.GetContextAsync()
            Handle-Request $ctx
        }
    } while ((Get-Date) -lt $end)
}

# Entree de boutique : "https://..." ou { url, exigerPokemon }
function Get-ShopEntry($raw) {
    if ($raw -is [string]) { return [pscustomobject]@{ url = $raw.TrimEnd('/'); exigerPokemon = $false } }
    return [pscustomobject]@{ url = ([string]$raw.url).TrimEnd('/'); exigerPokemon = [bool]$raw.exigerPokemon }
}

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
$Script:History = New-Object System.Collections.ArrayList   # reassorts : retours en stock et nouvelles fiches
$Script:SeenSources = @{}                                     # sources deja analysees au moins une fois
$Script:Magasins = $null                                      # magasins.json : zones proches + mots-cles des communes
$MagasinsPath = Join-Path $Root 'magasins.json'

function Load-All {
    $Script:Config = Read-Json $ConfigPath
    if (-not $Script:Config) { throw "config.json introuvable ou invalide" }
    # Secrets fournis par l'environnement (GitHub Actions) : jamais ecrits dans le depot public
    if ($env:NTFY_TOPIC)      { $Script:Config.notifications | Add-Member -NotePropertyName ntfyTopic -NotePropertyValue $env:NTFY_TOPIC -Force }
    if ($env:DISCORD_WEBHOOK) { $Script:Config.notifications | Add-Member -NotePropertyName discordWebhook -NotePropertyValue $env:DISCORD_WEBHOOK -Force }
    $Script:Catalogue = Read-Json $CataloguePath
    if (-not $Script:Catalogue) { $Script:Catalogue = [pscustomobject]@{ produits = @() } }
    $Script:Magasins = Read-Json $MagasinsPath
}

# Signalement qui mentionne une commune des zones proches (magasins.json) -> nom de la zone, sinon $null
function Find-Zone([string]$text) {
    if (-not $Script:Magasins) { return $null }
    $n = ' ' + ((Normalize $text) -replace '[^a-z0-9]+', ' ') + ' '
    foreach ($z in @($Script:Magasins.zones)) {
        foreach ($c in @($z.communes)) {
            $k = ' ' + ((Normalize $c) -replace '[^a-z0-9]+', ' ').Trim() + ' '
            if ($k.Length -gt 4 -and $n.Contains($k)) { return [pscustomobject]@{ zone = $z.nom; commune = $c } }
        }
    }
    return $null
}

function Add-History($item, [string]$kind) {
    [void]$Script:History.Add([pscustomobject]@{
        date = (Get-Date).ToString('s'); type = $kind; source = $item.source; sourceLabel = $item.sourceLabel
        titre = $item.titre; url = $item.url; prix = $item.prix; prixRef = $item.prixRef; statut = $item.statut
        catalogueNom = $item.catalogueNom
    })
    while ($Script:History.Count -gt 2000) { $Script:History.RemoveAt(0) }
}

function Load-State {
    $st = Read-Json $StatePath
    if (-not $st) { return }
    foreach ($i in @($st.items)) { if ($i -and $i.key) { $Script:Items[$i.key] = $i } }
    foreach ($d in @($st.deals)) { if ($d -and $d.key) { $Script:Deals[$d.key] = $d } }
    foreach ($a in @($st.alerts)) { if ($a) { [void]$Script:Alerts.Add($a); if ($a.id -gt $Script:AlertSeq) { $Script:AlertSeq = [int]$a.id } } }
    $Script:LastScan = $st.lastScan
    foreach ($h in @($st.historique)) { if ($h) { [void]$Script:History.Add($h) } }
    foreach ($s in @($st.sourcesVues)) { if ($s) { $Script:SeenSources[[string]$s] = $true } }
}

function Save-State {
    $obj = [ordered]@{
        lastScan = $Script:LastScan
        items    = @($Script:Items.Values)
        deals    = @($Script:Deals.Values)
        alerts   = @($Script:Alerts)
        historique  = @($Script:History)
        sourcesVues = @($Script:SeenSources.Keys)
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

# Quand GitHub envoie deja les alertes (telephone, Discord), le PC s'abstient pour eviter les doublons.
# $force : utilise par le bouton "notification de test" du tableau de bord.
function Test-PcMuted([bool]$force) {
    return ($OnWindows -and -not $force -and $Script:Config.notifications.ntfyDepuisPC -eq $false)
}

function Send-Ntfy([string]$title, [string]$msg, [string]$url, [int]$prio, [bool]$force = $false) {
    $n = $Script:Config.notifications
    if (-not $n.ntfyTopic) { return }
    if (Test-PcMuted $force) { return }
    $server = if ($n.ntfyServeur) { ([string]$n.ntfyServeur).TrimEnd('/') } else { 'https://ntfy.sh' }
    $p = [ordered]@{ topic = [string]$n.ntfyTopic; title = $title; message = $msg; priority = $prio; tags = @('rotating_light') }
    $actions = @()
    if ($url) { $p.click = $url; $actions += @{ action = 'view'; label = 'Ouvrir'; url = $url } }
    # lien vers la page mobile (GitHub Pages), fourni par le workflow
    if ($env:TABLEAU_URL) {
        if (-not $url) { $p.click = $env:TABLEAU_URL }
        $actions += @{ action = 'view'; label = 'Tableau de bord'; url = $env:TABLEAU_URL }
    }
    if ($actions.Count -gt 0) { $p.actions = $actions }
    try {
        $bytes = $Utf8.GetBytes((ConvertTo-Json -InputObject $p -Depth 5))
        Invoke-RestMethod -Uri $server -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 | Out-Null
    } catch { Write-Log "ntfy en echec: $($_.Exception.Message)" }
}

function Send-Discord([string]$title, [string]$msg, [string]$url, [string]$image, [int]$prio, [bool]$force = $false) {
    $hook = [string]$Script:Config.notifications.discordWebhook
    if (-not $hook) { return }
    if (Test-PcMuted $force) { return }
    # message "embed" : titre cliquable, image du produit, couleur selon l'importance
    $color = if ($prio -ge 5) { 1343562 } elseif ($prio -eq 4) { 2056127 } else { 9079434 }   # vert / bleu / gris
    $embed = [ordered]@{ title = $(if ($title.Length -gt 250) { $title.Substring(0, 250) } else { $title }); description = $msg; color = $color }
    if ($url -match '^https?://') { $embed.url = $url }
    if ($image -match '^https?://') { $embed.thumbnail = @{ url = $image } }
    $links = @()
    if ($url -match '^https?://') { $links += "[Ouvrir la fiche]($url)" }
    if ($env:TABLEAU_URL) { $links += "[Tableau de bord]($($env:TABLEAU_URL))" }
    if ($links.Count -gt 0) { $embed.description = $msg + "`n`n" + ($links -join '  |  ') }
    $embed.footer = @{ text = 'PokeVeille 30 ans' }
    $embed.timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $payload = [ordered]@{ username = 'PokeVeille'; embeds = @($embed) }
    try {
        $bytes = $Utf8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 6))
        Invoke-RestMethod -Uri $hook -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 | Out-Null
    } catch { Write-Log "Discord en echec: $($_.Exception.Message)" }
}

function Notify-All([string]$title, [string]$msg, [string]$url, [int]$prio = 4, [string]$image = '', [bool]$force = $false) {
    if ($Script:Config.notifications.windows) { Send-Toast $title $msg $url }
    if ($Script:Config.notifications.fenetre -ne $false) { Send-Popup $title $msg $url }
    Send-Ntfy $title $msg $url $prio $force
    Send-Discord $title $msg $url $image $prio $force
}

function Dispatch-Alerts($newAlerts) {
    $list = @($newAlerts)
    if ($list.Count -eq 0) { return }
    if ($list.Count -le 3) {
        foreach ($a in $list) { Notify-All $a.titre $a.message $a.url $(if ($a.type -eq 'prix-magasin' -or $a.magasin) { 5 } else { 4 }) ([string]$a.image) }
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

    # historique des reassorts : retour en stock, ou nouvelle fiche deja en stock sur une source connue
    if ($inStock -and $prev -and -not $prev.enStock) { Add-History $item 'retour' }
    elseif ($inStock -and -not $prev -and $Script:SeenSources.ContainsKey($src)) { Add-History $item 'nouveau' }

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
    $Script:SeenSources[$src] = $true
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
    $errors = @()
    foreach ($shopRaw in @($cfg.boutiques)) {
        $entry = Get-ShopEntry $shopRaw
        $shop = $entry.url
        if (-not $shop) { continue }
        $hostName = ([uri]$shop).Host -replace '^www\.', ''
        $src = "shopify:$hostName"
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        try {
        foreach ($q in @($cfg.requetes)) {
            $u = "$shop/search/suggest.json?q=" + [uri]::EscapeDataString($q) + '&resources[type]=product&resources[limit]=10&resources[options][unavailable_products]=last'
            $res = Get-Web $u
            $json = $res.Text | ConvertFrom-Json
            foreach ($p in @($json.resources.results.products)) {
                if (-not $p) { continue }
                if (-not (Is-Relevant $p.title $entry.exigerPokemon)) { continue }
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
        } catch { $errors += "$hostName ($($_.Exception.Message))"; Write-Log "[Shopify] $hostName en echec : $($_.Exception.Message)" }
    }
    $n = @($cfg.boutiques).Count
    $txt = "$total produits 30 ans, $($n - $errors.Count)/$n boutiques"
    if ($errors.Count -gt 0 -and $errors.Count -eq $n) { throw "toutes les boutiques en echec" }
    return $txt
}

# Boutiques WooCommerce (API publique "Store API" : /wp-json/wc/store/v1/products)
function Scan-Woo($newAlerts) {
    $cfg = $Script:Config.sources.woocommerce
    $total = 0
    $errors = @()
    foreach ($shopRaw in @($cfg.boutiques)) {
        $entry = Get-ShopEntry $shopRaw
        $shop = $entry.url
        if (-not $shop) { continue }
        $hostName = ([uri]$shop).Host -replace '^www\.', ''
        $src = "woo:$hostName"
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        try {
            foreach ($q in @($cfg.requetes)) {
                $res = Get-Web ("$shop/wp-json/wc/store/v1/products?per_page=50&search=" + [uri]::EscapeDataString($q))
                # (PS 5.1 ne deroule pas les tableaux JSON dans le pipeline : passer par une variable)
                $arr = $res.Text | ConvertFrom-Json
                foreach ($p in $arr) {
                    if (-not $p -or -not $p.id) { continue }
                    $title = Clean-Html ([string]$p.name)
                    if (-not (Is-Relevant $title $entry.exigerPokemon)) { continue }
                    $id = [string]$p.id
                    if ($seen.Contains("$src|$id")) { continue }
                    $price = $null
                    if ($p.prices -and $p.prices.price) {
                        $minor = if ($null -ne $p.prices.currency_minor_unit) { [int]$p.prices.currency_minor_unit } else { 2 }
                        $price = [math]::Round(([double]$p.prices.price) / [math]::Pow(10, $minor), 2)
                    }
                    $img = if ($p.images -and @($p.images).Count -gt 0) { [string]@($p.images)[0].src } else { '' }
                    $inStock = [bool]$p.is_in_stock -and [bool]$p.is_purchasable
                    Upsert-Item $src $hostName $id $title ([string]$p.permalink) $img $price $inStock $hostName $null $newAlerts
                    [void]$seen.Add("$src|$id")
                }
                Pause-Polite
            }
            Mark-Missing $src $seen
            $total += $seen.Count
        } catch { $errors += $hostName; Write-Log "[WooCommerce] $hostName en echec : $($_.Exception.Message)" }
    }
    $n = @($cfg.boutiques).Count
    if ($errors.Count -gt 0 -and $errors.Count -eq $n) { throw "toutes les boutiques en echec" }
    return "$total produits 30 ans, $($n - $errors.Count)/$n boutiques"
}

function Scan-Dealabs($newAlerts) {
    $cfg = $Script:Config.sources.dealabs
    $n = 0
    $errors = @()
    foreach ($feed in @($cfg.flux)) {
        if (-not $feed) { continue }
        $feedHost = ([uri][string]$feed).Host -replace '^www\.', ''
        $feedLabel = if ($feedHost -like '*dealabs*') { 'Dealabs' } elseif ($feedHost -like '*crocodeal*') { 'Le Crocodeal' } else { $feedHost }
        try { $res = Get-Web ([string]$feed) } catch { $errors += $feedHost; Write-Log "[Signalements] $feed en echec : $($_.Exception.Message)"; continue }
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
            $head = $title + ' ' + $merchant + ' ' + $desc.Substring(0, [math]::Min(600, $desc.Length))
            $magasin = (Normalize $head) -match $RxMagasin
            $zone = Find-Zone $head
            $cat = Match-Catalogue $title
            $prixRef = if ($cat) { [double]$cat.prixRef } else { $null }
            $d = [pscustomobject]@{
                key = $key; titre = $title; url = $link; image = $img; marchand = $merchant; prix = $price; prixRef = $prixRef
                catalogueNom = $(if ($cat) { $cat.nom } else { $null }); magasin = $magasin; publie = $pub; vu = (Get-Date).ToString('s')
                extrait = $desc.Substring(0, [math]::Min(220, $desc.Length)); source = $feedLabel
                zone = $(if ($zone) { $zone.zone } else { $null }); commune = $(if ($zone) { $zone.commune } else { $null })
            }
            $Script:Deals[$key] = $d
            $pTxt = if ($null -ne $price) { ('{0:N2} EUR' -f $price) } else { 'prix non indique' }
            $prefix = ''
            if ($zone) { $prefix = "PRES DE CHEZ TOI ($($zone.commune)) - " } elseif ($magasin) { $prefix = 'EN MAGASIN - ' }
            $msg = $prefix + "Signalement $feedLabel : $merchant $pTxt"
            $type = if ($zone) { 'proche' } elseif ($magasin) { 'magasin' } else { 'signalement' }
            [void]$newAlerts.Add((Add-Alert $type $title $msg $link $img ([bool]($magasin -or $zone))))
        }
        Pause-Polite
    }
    if ($errors.Count -gt 0 -and $errors.Count -eq @($cfg.flux).Count) { throw "tous les flux en echec" }
    # garder les 200 plus recents
    if ($Script:Deals.Count -gt 200) {
        $old = $Script:Deals.Values | Sort-Object vu | Select-Object -First ($Script:Deals.Count - 200)
        foreach ($o in $old) { $Script:Deals.Remove($o.key) }
    }
    return "$n signalements 30 ans dans $(@($cfg.flux).Count - $errors.Count)/$(@($cfg.flux).Count) flux"
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
            @{ name = 'shopify';      label = 'Boutiques JCC (Shopify)';     fn = { param($a) Scan-Shopify $a } },
            @{ name = 'woocommerce';  label = 'Boutiques JCC (WooCommerce)'; fn = { param($a) Scan-Woo $a } },
            @{ name = 'dealabs';      label = 'Signalements';                fn = { param($a) Scan-Dealabs $a } },
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
                    historique = @($Script:History)
                    magasins = $Script:Magasins
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
                Notify-All 'PokeVeille : test' 'Si vous lisez ceci, les alertes fonctionnent.' "http://localhost:$Port/" 3 '' $true
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
    Notify-All 'PokeVeille : test' "Les alertes envoyees par $where fonctionnent." $null 3 '' $true
    Write-Log "Notification de test envoyee"
    return
}
function Export-Etat([string]$path) {
    # Version publique de l'etat : aucun secret (pas de sujet ntfy, pas de webhook, pas de journal)
    $c = $Script:Config
    $obj = [ordered]@{
        statique = $true
        derniereAnalyse = $Script:LastScan
        prochaineAnalyse = (Get-Date).AddMinutes(5).ToString('s')
        analyseEnCours = $false
        produits = @($Script:Items.Values)
        signalements = @($Script:Deals.Values | Sort-Object vu -Descending)
        alertes = @($Script:Alerts | Select-Object -Last 100)
        sources = $Script:Sources
        config = [ordered]@{ tolerancePourcent = $c.tolerancePourcent; intervalleMinutes = 5 }
        catalogue = $Script:Catalogue
        historique = @($Script:History)
        magasins = $Script:Magasins
    }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $obj -Depth 12 -Compress), $Utf8)
    Write-Log "Etat public exporte : $path"
}

if ($Once) { Run-Scan; if ($Export) { Export-Etat $Export }; return }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch {
    Write-Host "Impossible d'ouvrir le port $Port (PokeVeille deja lance ?). Ouverture du tableau de bord..." -ForegroundColor Yellow
    Start-Process "http://localhost:$Port/"; Start-Sleep 3; return
}

try { $Host.UI.RawUI.WindowTitle = "PokeVeille 30 ans - http://localhost:$Port" } catch {}
Write-Log "PokeVeille demarre sur http://localhost:$Port/  (laisser cette fenetre ouverte, Ctrl+C pour arreter)"
if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }

$Script:Listener = $listener
$Script:CtxTask = $listener.GetContextAsync()
try {
    while ($listener.IsListening) {
        if ($Script:CtxTask.Wait(400)) {
            $ctx = $Script:CtxTask.Result
            $Script:CtxTask = $listener.GetContextAsync()
            Handle-Request $ctx
        }
        if ($Script:ScanRequested -or (Get-Date) -ge $Script:NextScan) {
            $Script:ScanRequested = $false
            Run-Scan
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
}
