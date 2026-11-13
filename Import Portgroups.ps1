<#
.SYNOPSIS
    Importe un ou plusieurs vSwitch (et leurs Port Groups) depuis un fichier JSON vers un hôte ESXi.

.DESCRIPTION
    Ce script interactif lit un fichier généré par "Export Portgroups.ps1", permet de
    sélectionner les vSwitch à importer, puis, pour chacun, de choisir le vSwitch cible
    sur l'hôte ESXi (existant, ou créé à l'identique avec le même nom et MTU). Les Port
    Groups sont recréés en préservant les VLAN IDs et les politiques de sécurité.
    Les fichiers de l'ancien format (un seul vSwitch) sont également acceptés.

.NOTES
    Prérequis : Module VCF.PowerCLI (anciennement VMware.PowerCLI) installé.
#>

# ============================================================
# PRÉREQUIS
# ============================================================

# Vérifie la présence du module PowerCLI : VCF.PowerCLI (9.0+) en priorité, VMware.PowerCLI (déprécié) en repli
if (Get-Module -ListAvailable -Name "VCF.PowerCLI") {
    # OK
} elseif (Get-Module -ListAvailable -Name "VMware.PowerCLI") {
    Write-Host "VMware.PowerCLI est déprécié. Migrez vers VCF.PowerCLI : Uninstall-Module VMware.PowerCLI -AllVersions ; Install-Module VCF.PowerCLI" -ForegroundColor Yellow
} else {
    Write-Host "Le module VCF PowerCLI n'est pas installé. Installez-le avec : Install-Module VCF.PowerCLI -Scope CurrentUser" -ForegroundColor Red
    exit
}

# ============================================================
# FONCTIONS
# ============================================================

# Collecte l'IP et le credential d'un hôte ESXi via saisie interactive
function Get-ServerInfo {
    $serverIP = Read-Host "Entrez l'adresse IP ou le nom d'hôte du serveur ESXi"
    $username  = Read-Host "Entrez le nom d'utilisateur"
    $password  = Read-Host "Entrez le mot de passe" -AsSecureString
    return @{
        IP         = $serverIP
        Credential = New-Object System.Management.Automation.PSCredential ($username, $password)
    }
}

# Demande une sélection du type "1-5,7" (plages et numéros individuels).
# "*" (ou Entrée si -EmptyMeansAll) sélectionne tout. Retourne des index 1-based triés et dédoublonnés.
function Read-Selection {
    param(
        [int]    $Count,
        [string] $Prompt,
        [switch] $EmptyMeansAll
    )
    while ($true) {
        $selection = (Read-Host $Prompt).Trim()
        if ($selection -eq '*' -or ($EmptyMeansAll -and $selection -eq '')) { return 1..$Count }

        $indices = @()
        $valid   = $true
        foreach ($part in $selection.Split(',')) {
            $part = $part.Trim()
            if ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1]; $end = [int]$Matches[2]
                if ($start -gt $end) {
                    Write-Host "Plage invalide : '$part' (début > fin)." -ForegroundColor Yellow
                    $valid = $false; break
                }
                if ($start -lt 1 -or $end -gt $Count) {
                    Write-Host "Plage hors limites : '$part' (max: $Count)." -ForegroundColor Yellow
                    $valid = $false; break
                }
                $indices += $start..$end
            } elseif ($part -match '^\d+$') {
                $num = [int]$part
                if ($num -lt 1 -or $num -gt $Count) {
                    Write-Host "Numéro hors limites : '$num' (max: $Count)." -ForegroundColor Yellow
                    $valid = $false; break
                }
                $indices += $num
            } else {
                Write-Host "Valeur non reconnue : '$part'." -ForegroundColor Yellow
                $valid = $false; break
            }
        }

        if ($valid -and $indices.Count -gt 0) { return $indices | Sort-Object -Unique }
        if ($valid) { Write-Host "Aucun élément sélectionné." -ForegroundColor Yellow }
    }
}

# ============================================================
# LECTURE DU FICHIER D'EXPORT
# ============================================================

$filePath = (Read-Host "Chemin du fichier JSON à importer").Trim('"')
if (-not (Test-Path -LiteralPath $filePath)) {
    Write-Host "Fichier introuvable : $filePath" -ForegroundColor Red
    exit
}

try {
    $import = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Host "Fichier JSON invalide : $_" -ForegroundColor Red
    exit
}

# Compatibilité avec l'ancien format (un seul vSwitch, Port Groups à la racine)
if ($import.VSwitches) {
    $fileVSwitches = @($import.VSwitches)
} elseif ($import.VSwitch) {
    $fileVSwitches = @([pscustomobject]@{
        Name       = $import.VSwitch.Name
        Mtu        = $import.VSwitch.Mtu
        PortGroups = @($import.PortGroups)
    })
} else {
    Write-Host "Le fichier ne contient aucun vSwitch." -ForegroundColor Red
    exit
}

Write-Host "`nExport du $($import.ExportDate) depuis $($import.SourceHost)" -ForegroundColor Cyan
Write-Host "vSwitch contenus dans le fichier :"
for ($i = 0; $i -lt $fileVSwitches.Count; $i++) {
    $vs = $fileVSwitches[$i]
    Write-Host "$($i+1). $($vs.Name) (MTU $($vs.Mtu), $(@($vs.PortGroups).Count) groupe(s) de ports)"
    foreach ($pg in @($vs.PortGroups)) {
        Write-Host "     - $($pg.Name) (VLAN: $($pg.VLanId))"
    }
}

$vswitchIndices    = Read-Selection -Count $fileVSwitches.Count -EmptyMeansAll -Prompt "Entrez les numéros des vSwitch à importer (ex: 1-3,5 ; Entrée ou * pour tous)"
$selectedVSwitches = @($vswitchIndices | ForEach-Object { $fileVSwitches[$_ - 1] })

# ============================================================
# CONNEXION À L'HÔTE ESXI CIBLE
# ============================================================

Write-Host "`nInformations pour le serveur ESXi cible :"
$targetInfo = Get-ServerInfo

try {
    Connect-VIServer $targetInfo.IP -Credential $targetInfo.Credential -ErrorAction Stop | Out-Null
}
catch {
    Write-Host "Erreur de connexion : $_" -ForegroundColor Red
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    exit
}

# ============================================================
# CHOIX DU VSWITCH CIBLE POUR CHAQUE VSWITCH IMPORTÉ
# ============================================================

$targetVSwitches = @(Get-VirtualSwitch -VMHost $targetInfo.IP -Standard)
Write-Host "`n--- vSwitch existants sur la cible $($targetInfo.IP) ---" -ForegroundColor Cyan
for ($i = 0; $i -lt $targetVSwitches.Count; $i++) {
    Write-Host "$($i+1). $($targetVSwitches[$i].Name)"
}

# Plan d'import : pour chaque vSwitch du fichier, le nom du vSwitch cible et s'il faut le créer
$plan = @()
foreach ($vs in $selectedVSwitches) {
    $targetName = $null
    while (-not $targetName) {
        $choice = (Read-Host "Cible pour '$($vs.Name)' : Entrée/0 = même nom (créé si absent), ou numéro d'un vSwitch existant").Trim()
        if ($choice -eq '' -or $choice -eq '0') {
            $targetName = $vs.Name
        } elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $targetVSwitches.Count) {
            $targetName = $targetVSwitches[[int]$choice - 1].Name
        } else {
            Write-Host "Invalide." -ForegroundColor Yellow
        }
    }

    $exists = [bool]($targetVSwitches | Where-Object { $_.Name -eq $targetName })
    # Un même vSwitch à créer peut être ciblé plusieurs fois : on ne le crée qu'une fois
    $alreadyPlanned = [bool]($plan | Where-Object { $_.TargetName -eq $targetName -and $_.Create })
    $plan += [pscustomobject]@{
        Source     = $vs
        TargetName = $targetName
        Create     = (-not $exists -and -not $alreadyPlanned)
    }
}

# ============================================================
# CONFIRMATION ET EXÉCUTION
# ============================================================

Write-Host "`nRésumé de l'import sur $($targetInfo.IP) :" -ForegroundColor Cyan
foreach ($p in $plan) {
    $action = if ($p.Create) { "création (MTU $($p.Source.Mtu))" } else { "existant" }
    Write-Host " - $($p.Source.Name) -> $($p.TargetName) [$action] : $(@($p.Source.PortGroups).Count) groupe(s) de ports"
}
$confirmation = Read-Host "Confirmer l'opération ? (O/N)"
if ($confirmation -notmatch '^[Oo]$') { Disconnect-VIServer -Server * -Confirm:$false ; exit }

$created = 0; $skipped = 0; $failed = 0

foreach ($p in $plan) {
    Write-Host "`n=== $($p.Source.Name) -> $($p.TargetName) ===" -ForegroundColor Cyan

    try {
        if ($p.Create) {
            Write-Host "Création du vSwitch '$($p.TargetName)'..." -ForegroundColor Green
            # MTU repris de l'export pour garantir la cohérence réseau
            $targetSwitch = New-VirtualSwitch -VMHost $targetInfo.IP -Name $p.TargetName -Mtu $p.Source.Mtu -ErrorAction Stop
        } else {
            $targetSwitch = Get-VirtualSwitch -VMHost $targetInfo.IP -Name $p.TargetName -Standard -ErrorAction Stop
        }
    }
    catch {
        Write-Host "Impossible d'obtenir le vSwitch '$($p.TargetName)' : $_" -ForegroundColor Red
        $failed += @($p.Source.PortGroups).Count
        continue
    }

    foreach ($pg in @($p.Source.PortGroups)) {
        $existingPg = Get-VirtualPortGroup -VMHost $targetInfo.IP -Name $pg.Name -Standard -ErrorAction SilentlyContinue
        if ($existingPg) {
            # Un nom de Port Group standard est unique sur l'hôte, tous vSwitch confondus
            Write-Host "Le groupe $($pg.Name) existe déjà sur l'hôte. Ignoré." -ForegroundColor Yellow
            $skipped++
            continue
        }

        try {
            Write-Host "Création de $($pg.Name) (VLAN $($pg.VLanId))..."
            $newPg = New-VirtualPortGroup -VirtualSwitch $targetSwitch -Name $pg.Name -VLanId $pg.VLanId -ErrorAction Stop

            # Réplication de la politique de sécurité : héritée du vSwitch si c'était le cas à l'export,
            # sinon valeur forcée au niveau du Port Group
            $sp = $pg.SecurityPolicy
            if ($sp) {
                $params = @{}
                if ($sp.AllowPromiscuousInherited) { $params.AllowPromiscuousInherited = $true } else { $params.AllowPromiscuous = [bool]$sp.AllowPromiscuous }
                if ($sp.ForgedTransmitsInherited)  { $params.ForgedTransmitsInherited  = $true } else { $params.ForgedTransmits  = [bool]$sp.ForgedTransmits }
                if ($sp.MacChangesInherited)       { $params.MacChangesInherited       = $true } else { $params.MacChanges       = [bool]$sp.MacChanges }

                $newPg | Get-SecurityPolicy | Set-SecurityPolicy @params -ErrorAction Stop | Out-Null
            }
            $created++
        }
        catch {
            Write-Host "Erreur sur $($pg.Name) : $_" -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host "`nTerminé ! $created créé(s), $skipped ignoré(s), $failed en erreur." -ForegroundColor Green
Disconnect-VIServer -Server * -Confirm:$false
