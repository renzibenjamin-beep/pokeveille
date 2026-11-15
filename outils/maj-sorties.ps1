# Mise a jour automatique du calendrier des sorties (sorties.json) a partir de calendriers publics :
#  - Pokekalos (source principale : fiches structurees nom / date / prix / contenu)
#  - Le Booster (complement : tableaux en texte libre)
# Regles : on n'efface jamais rien ; une sortie connue voit sa date / son prix mis a jour (Pokekalos prioritaire) ;
# une nouvelle annonce est ajoutee et surveillee automatiquement. Les entrees "verrouille": true ne sont jamais modifiees.
# Lance chaque matin par le workflow GitHub "Calendrier des sorties" ; peut aussi etre lance a la main.
param(
    [string]$Fichier = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'sorties.json'),
    [switch]$Simulation   # affiche les changements sans ecrire le fichier
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Inv = [Globalization.CultureInfo]::InvariantCulture
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$Today = (Get-Date).Date
$Now = (Get-Date).ToString('s')

function Normalize([string]$s) {
    if (-not $s) { return '' }
    $d = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    return $sb.ToString().ToLowerInvariant()
}
function Clean-Html([string]$s) {
    if (-not $s) { return '' }
    return ([System.Net.WebUtility]::HtmlDecode(($s -replace '(?s)<[^>]+>', ' ')) -replace '\s+', ' ').Trim()
}
function Get-Page([string]$url) {
    $r = Invoke-WebRequest -Uri $url -UserAgent $UA -UseBasicParsing -TimeoutSec 40 -Headers @{ 'Accept-Language' = 'fr-FR,fr;q=0.9' }
    return $Utf8.GetString($r.RawContentStream.ToArray())
}

# "29 janv. 2027", "12 fevrier 2027", "1er mars 2027" -> [datetime] ou $null
$Mois = [ordered]@{ 'janv' = 1; 'fevr' = 2; 'mars' = 3; 'avr' = 4; 'mai' = 5; 'juil' = 7; 'juin' = 6; 'aout' = 8; 'sept' = 9; 'oct' = 10; 'nov' = 11; 'dec' = 12; 'jan' = 1; 'fev' = 2; 'sep' = 9 }
function Parse-DateFr([string]$text) {
    $n = Normalize $text
    $m = [regex]::Match($n, '\b(\d{1,2})(?:er)?\s+([a-z]+)\.?\s+(20\d\d)\b')
    if (-not $m.Success) { return $null }
    $mo = $null
    foreach ($k in $Mois.Keys) { if ($m.Groups[2].Value.StartsWith($k)) { $mo = $Mois[$k]; break } }
    if (-not $mo) { return $null }
    try { return (Get-Date -Year ([int]$m.Groups[3].Value) -Month $mo -Day ([int]$m.Groups[1].Value)).Date } catch { return $null }
}
function Parse-Prix([string]$text) {
    $m = [regex]::Match($text, '(\d{1,4}),(\d{2})\s*(?:\u20AC|&euro;|eur)')
    if ($m.Success) { return "$($m.Groups[1].Value),$($m.Groups[2].Value) " + [char]0x20AC }
    return ''
}

# Mots distinctifs d'un nom de produit (pour reconnaitre les doublons et surveiller les boutiques)
$Stop = @('collection', 'coffret', 'pokemon', 'jcc', 'avec', 'des', 'les', 'une', 'pour', 'sur', 'aux', 'the', 'and', 'tcg', 'de', 'du', 'la', 'le', 'et', 'en',
          'anniversaire', 'edition', 'version', 'francaise', 'produit', 'produits', 'serie', 'mega', 'evolution', 'set', 'box')
function Get-Tokens([string]$name) {
    $n = (Normalize $name) -replace 'pokemon day', 'journee pokemon' -replace '\bday\b', 'journee'
    $n = $n -replace '[^a-z0-9]+', ' '
    return @($n.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.Length -ge 3 -and $Stop -notcontains $_ -and $_ -notmatch '^\d{1,2}(e|eme)?$' } | Select-Object -Unique)
}
function Get-Similarity($a, $b) {
    $A = @(Get-Tokens $a); $B = @(Get-Tokens $b)
    if ($A.Count -eq 0 -or $B.Count -eq 0) { return 0 }
    $inter = @($A | Where-Object { $B -contains $_ }).Count
    $union = @($A + $B | Select-Object -Unique).Count
    $j = $inter / $union
    # un nom entierement contenu dans l'autre (2 mots distinctifs ou plus) compte comme identique
    if ($inter -ge 2 -and ($inter -eq $A.Count -or $inter -eq $B.Count)) { $j = [math]::Max($j, 0.8) }
    return $j
}
# PowerShell 7 convertit parfois les dates JSON en [datetime] : toujours revenir a "aaaa-mm-jj"
function Get-DateStr($v) {
    if ($null -eq $v -or $v -eq '') { return '' }
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-dd') }
    $s = [string]$v
    return $s.Substring(0, [math]::Min(10, $s.Length))
}
function New-Slug([string]$name) {
    $s = ((Normalize $name) -replace '[^a-z0-9]+', '-').Trim('-')
    if ($s.Length -gt 50) { $s = $s.Substring(0, 50).Trim('-') }
    return $s
}

# ------------------------------------------------------------------ lecture des sources
$found = New-Object System.Collections.ArrayList
$errors = @()

# 1. Pokekalos : <div class="pk-card" data-category="..."> <h3>Nom</h3> "Sortie le 29 janv. 2027" <strong class="pk-price">25,99 \u20AC</strong>
try {
    $h = Get-Page 'https://www.pokekalos.fr/tcgevents'
    foreach ($m in [regex]::Matches($h, '(?s)<div class="pk-card"(.*?)<div class="pk-product-footer">')) {
        $c = $m.Groups[1].Value
        $nom = Clean-Html (([regex]::Match($c, '(?s)<h3>(.*?)</h3>')).Groups[1].Value)
        $dateTxt = Clean-Html (([regex]::Match($c, '(?s)class="pk-product-date">(.*?)</div>')).Groups[1].Value)
        if (-not $nom) { continue }
        [void]$found.Add([pscustomobject]@{
            nom = $nom; date = (Parse-DateFr $dateTxt); type = [System.Net.WebUtility]::HtmlDecode(([regex]::Match($c, 'data-category="([^"]*)"')).Groups[1].Value)
            prix = (Parse-Prix (Clean-Html (([regex]::Match($c, '(?s)class="pk-price">(.*?)</strong>')).Groups[1].Value)))
            note = (Clean-Html (([regex]::Match($c, '(?s)class="pk-description">(.*?)</div>')).Groups[1].Value))
            source = 'https://www.pokekalos.fr/tcgevents'; priorite = 1; statut = 'estime'
        })
    }
    Write-Host ("Pokekalos : {0} produit(s)" -f @($found | Where-Object priorite -eq 1).Count)
} catch { $errors += "Pokekalos ($($_.Exception.Message))"; Write-Host "Pokekalos en echec : $($_.Exception.Message)" -ForegroundColor Yellow }

# 2. Le Booster : lignes de tableaux <tr><td>Nom</td><td>date en texte</td><td>prix / remarques</td></tr>
try {
    $h = Get-Page 'https://lebooster.fr/guides/calendrier-sorties-pokemon'
    $n0 = $found.Count
    # Chaque tableau a ses en-tetes : on y cherche la colonne "date" et la colonne "nom"
    foreach ($tb in [regex]::Matches($h, '(?s)<table.*?</table>')) {
        $heads = @([regex]::Matches($tb.Value, '(?s)<th[^>]*>(.*?)</th>') | ForEach-Object { Normalize (Clean-Html $_.Groups[1].Value) })
        if ($heads.Count -lt 2) { continue }
        if (($heads -join ' ') -match 'japon|japonais') { continue }          # tableau de correspondance Japon -> France
        $iDate = -1; $iNom = -1
        for ($i = 0; $i -lt $heads.Count; $i++) {
            if ($iDate -lt 0 -and $heads[$i] -match '^(date|sortie)') { $iDate = $i }
            elseif ($iNom -lt 0 -and $heads[$i] -match 'extension|ce qui|collection|produit|nom') { $iNom = $i }
        }
        if ($iDate -lt 0 -or $iNom -lt 0) { continue }
        $prefixe = if ($heads[$iNom] -match '^collection ultra') { 'Collection Ultra-Premium ' } else { '' }
        foreach ($m in [regex]::Matches($tb.Value, '(?s)<tr>(.*?)</tr>')) {
            $cells = @([regex]::Matches($m.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>') | ForEach-Object { Clean-Html $_.Groups[1].Value })
            if ($cells.Count -le [math]::Max($iDate, $iNom)) { continue }
            $dateTxt = $cells[$iDate]
            # hors perimetre : dates japonaises ou anglaises, Pokemon Pocket (jeu mobile), jeux video
            if ((Normalize (($cells -join ' '))) -match 'au japon|en anglais|japan|pocket|jeu video|nintendo switch') { continue }
            $d = Parse-DateFr $dateTxt
            if (-not $d) { continue }                                           # annonces sans date : ignorees
            $statut = if ((Normalize $dateTxt) -match 'annonce(e)? par pokemon|officiel|confirme') { 'confirme' } else { 'estime' }
            $autres = @(for ($i = 0; $i -lt $cells.Count; $i++) { if ($i -ne $iDate -and $i -ne $iNom) { $cells[$i] } })
            [void]$found.Add([pscustomobject]@{
                nom = ($prefixe + ($cells[$iNom] -replace '\s*\(.*?\)\s*$', '')).Trim(); date = $d; type = ''
                prix = (Parse-Prix ($autres -join ' ')); note = ($autres -join ' - ')
                source = 'https://lebooster.fr/guides/calendrier-sorties-pokemon'; priorite = 2; statut = $statut
            })
        }
    }
    Write-Host ("Le Booster : {0} ligne(s)" -f ($found.Count - $n0))
} catch { $errors += "Le Booster ($($_.Exception.Message))"; Write-Host "Le Booster en echec : $($_.Exception.Message)" -ForegroundColor Yellow }

if ($found.Count -eq 0) { throw "Aucune source lisible : calendrier inchange. $($errors -join ' ; ')" }

# ------------------------------------------------------------------ fusion
$cal = Get-Content -Raw -Encoding UTF8 $Fichier | ConvertFrom-Json
$list = New-Object System.Collections.ArrayList
foreach ($s in @($cal.sorties)) { if ($s) { [void]$list.Add($s) } }
$changes = @()

function Set-Field($obj, [string]$name, $value) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }

# on ne garde que l'avenir proche (et les 7 derniers jours) ; Pokekalos d'abord
$cands = @($found | Where-Object { $_.date -and $_.date -ge $Today.AddDays(-7) } | Sort-Object priorite)
$handled = @{}
foreach ($f in $cands) {
    # meilleure correspondance parmi les sorties connues
    $best = $null; $bestScore = 0
    foreach ($s in $list) { $sc = Get-Similarity $f.nom $s.nom; if ($sc -gt $bestScore) { $best = $s; $bestScore = $sc } }
    if ($best -and $bestScore -ge 0.5) {
        if ($handled.ContainsKey($best.id) -and $handled[$best.id] -lt $f.priorite) { continue }   # deja traite par une source prioritaire
        $handled[$best.id] = $f.priorite
        if ($best.verrouille) { continue }
        $curDate = Get-DateStr $best.date
        $newDate = if ($f.date) { $f.date.ToString('yyyy-MM-dd') } else { '' }
        # Pokekalos peut changer une date ; Le Booster ne fait que completer une date manquante
        if ($newDate -and $newDate -ne $curDate -and ($f.priorite -eq 1 -or -not $curDate)) {
            Set-Field $best 'dateAvant' $(if ($curDate) { $curDate } else { $null })
            Set-Field $best 'date' $newDate
            Set-Field $best 'modifieLe' $Now
            $changes += "date modifiee : $($best.nom) : $curDate -> $newDate"
        }
        if ($f.prix -and -not $best.prix) { Set-Field $best 'prix' $f.prix; $changes += "prix ajoute : $($best.nom) : $($f.prix)" }
        continue
    }
    # nouvelle sortie (ignorer les doublons entre sources)
    if (@($list | Where-Object { (Get-Similarity $f.nom $_.nom) -ge 0.5 }).Count -gt 0) { continue }
    $tokens = @(Get-Tokens $f.nom)
    $surveiller = $tokens.Count -ge 2
    $motif = if ($surveiller) { '^' + (($tokens | Select-Object -First 3 | ForEach-Object { "(?=.*\b$([regex]::Escape($_)))" }) -join '') } else { '' }
    $id = New-Slug $f.nom
    while (@($list | Where-Object { $_.id -eq $id }).Count -gt 0) { $id += '-2' }
    $new = [pscustomobject][ordered]@{
        id = $id; nom = $f.nom; date = $(if ($f.date) { $f.date.ToString('yyyy-MM-dd') } else { $null }); type = $(if ($f.type) { $f.type } else { 'Produit' })
        prix = $f.prix; statut = $f.statut; surveiller = $surveiller; recherche = $(if ($surveiller) { ($tokens | Select-Object -First 2) -join ' ' } else { '' })
        motif = $motif; source = $f.source; note = $(if ($f.note.Length -gt 220) { $f.note.Substring(0, 220) + '...' } else { $f.note })
        ajouteLe = $Now; auto = $true
    }
    [void]$list.Add($new)
    $changes += "nouvelle sortie : $($f.nom) ($($new.date))"
}

Write-Host ("{0} changement(s)" -f $changes.Count)
$changes | ForEach-Object { Write-Host "  - $_" }
if ($changes.Count -eq 0 -or $Simulation) { return }

foreach ($s in $list) { if ($s.date) { Set-Field $s 'date' (Get-DateStr $s.date) } }
Set-Field $cal 'sorties' @($list)
Set-Field $cal 'maj' $Now
Set-Field $cal 'majAuto' ([ordered]@{ date = $Now; sources = @('Pokekalos', 'Le Booster'); erreurs = $errors })
[IO.File]::WriteAllText($Fichier, (ConvertTo-Json -InputObject $cal -Depth 8), $Utf8)
Write-Host "Calendrier mis a jour : $Fichier"
