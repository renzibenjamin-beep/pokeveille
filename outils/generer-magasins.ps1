# Genere magasins.json : magasins susceptibles de vendre des cartes Pokemon dans un rayon autour de chaque zone,
# a partir d'OpenStreetMap (API Overpass, gratuite). A relancer de temps en temps (nouveaux magasins).
# Les coordonnees des zones restent sur ce PC : seul le resultat (magasins + distances) est publie.
param([string]$Out = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'magasins.json'))

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# Zones (centre des communes, rayon) : variable d'environnement ZONES_JSON (secret GitHub) ou outils\zones.json sur le PC.
# Elles ne sont jamais ecrites dans le depot public.
$zonesJson = $env:ZONES_JSON
if (-not $zonesJson) { $zonesJson = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'zones.json') }
$Zones = @($zonesJson | ConvertFrom-Json | ForEach-Object { $_ })

$Brands = 'Leclerc|Auchan|Carrefour|Cora|Intermarch|Hyper U|Super U|Fnac|Cultura|Espace Culturel|Furet|Micromania|King Jouet|Jou[eé] ?Club|Grande R[eé]cr[eé]|Smyths|Maxi ?Toys|Action|G[eé]ant'
$Exclude = '(?i)carrefour (city|express|contact|montagne)|my auchan|auchan (pi[eé]ton|drive)|drive|intermarch[eé] (contact|express)|station|relais|carburant|location|bricolage|brico|jardin|optique|voyage|auto|pneu|meuble|cuisine'
$Endpoints = 'https://overpass-api.de/api/interpreter', 'https://maps.mail.ru/osm/tools/overpass/api/interpreter', 'https://overpass.kumi.systems/api/interpreter', 'https://overpass.private.coffee/api/interpreter'
$Tiles = 3   # chaque zone est decoupee en 3x3 morceaux : les serveurs gratuits refusent les grosses requetes
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # Windows PowerShell 5.1 ne sait pas se connecter a overpass-api.de (TLS) : on commence par les miroirs
    $Endpoints = @($Endpoints | Select-Object -Skip 1) + @($Endpoints[0])
}

function Get-Category($tags) {
    $n = "$($tags.name) $($tags.brand)"
    $shop = [string]$tags.shop
    if ($n -match '(?i)fnac|cultura|espace culturel|furet|micromania') { return 'culture' }
    if ($n -match '(?i)king jouet|jou[eé] ?club|grande r[eé]cr[eé]|smyths|maxi ?toys') { return 'jouets' }
    if ($n -match '(?i)leclerc|auchan|carrefour|cora|intermarch|hyper u|super u|g[eé]ant') { return 'hyper' }
    if ($shop -in @('games', 'hobby', 'comic', 'anime', 'collector')) { return 'jeux' }
    if ($shop -eq 'toys') { return 'jouets' }
    if ($shop -eq 'video_games') { return 'culture' }
    # Action, Lego : pas de cartes Pokemon -> ignores
    if ($n -match '(?i)\baction\b|\blego\b') { return $null }
    return $null
}

function Get-DistanceKm($lat1, $lon1, $lat2, $lon2) {
    $r = 6371.0
    $dLat = ($lat2 - $lat1) * [math]::PI / 180; $dLon = ($lon2 - $lon1) * [math]::PI / 180
    $a = [math]::Sin($dLat / 2) * [math]::Sin($dLat / 2) + [math]::Cos($lat1 * [math]::PI / 180) * [math]::Cos($lat2 * [math]::PI / 180) * [math]::Sin($dLon / 2) * [math]::Sin($dLon / 2)
    return $r * 2 * [math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1 - $a))
}

function Invoke-Overpass([string]$q) {
    $body = 'data=' + [uri]::EscapeDataString($q)
    for ($round = 0; $round -lt 3; $round++) {
        foreach ($ep in $Endpoints) {
            try {
                $r = Invoke-WebRequest -Uri $ep -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 120 -UserAgent 'PokeVeille/1.0 (usage personnel)'
                return ($Utf8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json)
            } catch { Write-Host "    $($ep.Split('/')[2]) : $($_.Exception.Message)" -ForegroundColor DarkYellow; Start-Sleep 3 }
        }
        Start-Sleep (30 * ($round + 1))   # serveurs surcharges : on patiente de plus en plus
    }
    throw 'Overpass indisponible'
}

# Point en France ? Elimine l'Allemagne (Sarre / Palatinat, codes postaux 66xxx) pour la zone Moselle.
function Is-France($t) {
    if ($t.'addr:country' -and $t.'addr:country' -ne 'FR') { return $false }
    if ($t.'addr:postcode' -and ([string]$t.'addr:postcode') -match '^66') { return $false }
    if ("$($t.name) $($t.'addr:street')" -match '(?i)stra(ss|ß)e|\bstr\.|markt\b|spielwaren|kaufland|m(ü|u)ller|rossmann|globus|real\b|rewe|edeka') { return $false }
    return $true
}

$result = [ordered]@{ genere = (Get-Date).ToString('s'); source = 'OpenStreetMap (ODbL)'; zones = @() }
foreach ($z in $Zones) {
    Write-Host "==> Zone $($z.nom)" -ForegroundColor Cyan
    # boite englobante (plus rapide que "around")
    $dLat = $z.rayonKm / 111.0
    $dLon = $z.rayonKm / (111.0 * [math]::Cos($z.lat * [math]::PI / 180))
    $Inv = [Globalization.CultureInfo]::InvariantCulture
    $bb = [string]::Format($Inv, '{0:F4},{1:F4},{2:F4},{3:F4}', ($z.lat - $dLat), ($z.lon - $dLon), ($z.lat + $dLat), ($z.lon + $dLon))
    $queries = @()
    for ($a = 0; $a -lt $Tiles; $a++) {
        for ($b = 0; $b -lt $Tiles; $b++) {
            $s = $z.lat - $dLat + (2 * $dLat / $Tiles) * $a; $w = $z.lon - $dLon + (2 * $dLon / $Tiles) * $b
            $tb = [string]::Format($Inv, '{0:F4},{1:F4},{2:F4},{3:F4}', $s, $w, ($s + 2 * $dLat / $Tiles), ($w + 2 * $dLon / $Tiles))
            # requete legere : filtre uniquement sur le type de magasin (index), le tri des enseignes se fait ici
            $queries += "[out:json][timeout:90][bbox:$tb];nwr[shop~`"^(toys|games|video_games|hobby|comic|anime|collector|supermarket|hypermarket|books|department_store|variety_store|multimedia)$`"];out center tags;"
        }
    }
    $stores = @{}
    $i = 0
    $failed = 0
    foreach ($q in $queries) {
        $i++
        Write-Host "  morceau $i/$($queries.Count)"
        try { $data = Invoke-Overpass $q } catch { Write-Host "  morceau $i ignore (serveurs indisponibles)" -ForegroundColor Yellow; $failed++; continue }
        foreach ($e in @($data.elements)) {
            $t = $e.tags
            if (-not $t -or -not $t.name) { continue }
            if ("$($t.name) $($t.brand)" -match $Exclude) { continue }
            if (-not (Is-France $t)) { continue }
            $cat = Get-Category $t
            if (-not $cat) { continue }
            $lat = if ($e.lat) { [double]$e.lat } else { [double]$e.center.lat }
            $lon = if ($e.lon) { [double]$e.lon } else { [double]$e.center.lon }
            $d = [math]::Round((Get-DistanceKm $z.lat $z.lon $lat $lon), 1)
            if ($d -gt $z.rayonKm) { continue }
            $k = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}|{1:F3}|{2:F3}', $t.name, $lat, $lon)
            $stores[$k] = [ordered]@{
                nom = [string]$t.name; categorie = $cat; distanceKm = $d
                ville = $(if ($t.'addr:city') { [string]$t.'addr:city' } else { '' })
                adresse = (@($t.'addr:housenumber', $t.'addr:street') | Where-Object { $_ }) -join ' '
                lat = [math]::Round($lat, 5); lon = [math]::Round($lon, 5)
                site = $(if ($t.website) { [string]$t.website } elseif ($t.'contact:website') { [string]$t.'contact:website' } else { '' })
                horaires = $(if ($t.opening_hours) { [string]$t.opening_hours } else { '' })
                telephone = $(if ($t.phone) { [string]$t.phone } elseif ($t.'contact:phone') { [string]$t.'contact:phone' } else { '' })
            }
        }
        Start-Sleep 2
    }
    $list = @($stores.Values | Sort-Object { $_.distanceKm })
    Write-Host ("  {0} magasins ({1} morceau(x) ignore(s))" -f $list.Count, $failed)
    # ne pas remplacer une bonne liste par une liste trouee : on echoue, l'ancienne liste est conservee
    if ($failed -gt [math]::Floor($queries.Count / 3)) { throw "Trop de morceaux en echec ($failed/$($queries.Count)) pour la zone $($z.nom) : liste non mise a jour" }

    Write-Host '  communes'
    $places = Invoke-Overpass "[out:json][timeout:60][bbox:$bb];node[place~`"^(city|town)$`"][name];out tags center;"
    $communes = @(@($places.elements | ForEach-Object { [string]$_.tags.name }) + @($list | ForEach-Object { $_.ville }) | Where-Object { $_ -and $_.Length -ge 4 } | Sort-Object -Unique)
    Write-Host ("  {0} communes" -f $communes.Count)

    $result.zones += [ordered]@{ id = $z.id; nom = $z.nom; rayonKm = $z.rayonKm; magasins = $list; communes = $communes }
}
[IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject $result -Depth 8), $Utf8)
Write-Host "Ecrit : $Out" -ForegroundColor Green
