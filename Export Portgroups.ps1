<#
.SYNOPSIS
    Exporte un ou plusieurs vSwitch standards (et leurs Port Groups) d'un hôte ESXi vers un fichier JSON.

.DESCRIPTION
    Ce script interactif se connecte à un hôte ESXi, permet de sélectionner un ou plusieurs
    vSwitch puis, pour chacun, les Port Groups à exporter. La configuration (nom et MTU du
    vSwitch ; nom, VLAN ID et politique de sécurité des Port Groups) est enregistrée dans
    un fichier JSON, réimportable avec "Import Portgroups.ps1".

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
# CONNEXION À L'HÔTE ESXI
# ============================================================

Write-Host "Informations pour le serveur ESXi source :"
$sourceInfo = Get-ServerInfo

try {
    Connect-VIServer $sourceInfo.IP -Credential $sourceInfo.Credential -ErrorAction Stop | Out-Null
}
catch {
    Write-Host "Erreur de connexion : $_" -ForegroundColor Red
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    exit
}

# ============================================================
# SÉLECTION DES VSWITCH SOURCE
# ============================================================

$sourceVSwitches = @(Get-VirtualSwitch -VMHost $sourceInfo.IP -Standard)
if ($sourceVSwitches.Count -eq 0) {
    Write-Host "Aucun vSwitch standard sur $($sourceInfo.IP)." -ForegroundColor Yellow
    Disconnect-VIServer -Server * -Confirm:$false
    exit
}

Write-Host "`nvSwitch disponibles sur $($sourceInfo.IP) :"
for ($i = 0; $i -lt $sourceVSwitches.Count; $i++) {
    $pgCount = @($sourceVSwitches[$i] | Get-VirtualPortGroup).Count
    Write-Host "$($i+1). $($sourceVSwitches[$i].Name) ($pgCount groupe(s) de ports)"
}

$vswitchIndices   = Read-Selection -Count $sourceVSwitches.Count -Prompt "Entrez les numéros des vSwitch à exporter (ex: 1-3,5 ou * pour tous)"
$selectedVSwitches = @($vswitchIndices | ForEach-Object { $sourceVSwitches[$_ - 1] })

# ============================================================
# SÉLECTION DES PORT GROUPS (PAR VSWITCH) ET CONSTRUCTION DE L'EXPORT
# ============================================================

$exportVSwitches = @()
$totalPortGroups = 0

foreach ($vs in $selectedVSwitches) {
    $portGroups = @($vs | Get-VirtualPortGroup)
    $selectedPortGroups = @()

    Write-Host "`n--- vSwitch $($vs.Name) (MTU $($vs.Mtu)) ---" -ForegroundColor Cyan
    if ($portGroups.Count -eq 0) {
        Write-Host "Aucun groupe de ports : seul le vSwitch sera exporté." -ForegroundColor Yellow
    } else {
        for ($i = 0; $i -lt $portGroups.Count; $i++) {
            Write-Host "$($i+1). $($portGroups[$i].Name) (VLAN: $($portGroups[$i].VLanId))"
        }
        $pgIndices          = Read-Selection -Count $portGroups.Count -EmptyMeansAll -Prompt "Groupes de ports à exporter (ex: 1-5,7 ; Entrée ou * pour tous)"
        $selectedPortGroups = @($pgIndices | ForEach-Object { $portGroups[$_ - 1] })
    }

    $exportPortGroups = foreach ($pg in $selectedPortGroups) {
        $policy = $pg | Get-SecurityPolicy
        [ordered]@{
            Name           = $pg.Name
            VLanId         = $pg.VLanId
            SecurityPolicy = [ordered]@{
                AllowPromiscuous          = $policy.AllowPromiscuous
                AllowPromiscuousInherited = $policy.AllowPromiscuousInherited
                ForgedTransmits           = $policy.ForgedTransmits
                ForgedTransmitsInherited  = $policy.ForgedTransmitsInherited
                MacChanges                = $policy.MacChanges
                MacChangesInherited       = $policy.MacChangesInherited
            }
        }
    }

    $exportVSwitches += [ordered]@{
        Name       = $vs.Name
        Mtu        = $vs.Mtu
        PortGroups = @($exportPortGroups)
    }
    $totalPortGroups += $selectedPortGroups.Count
}

$export = [ordered]@{
    FormatVersion = 2
    ExportDate    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    SourceHost    = $sourceInfo.IP
    VSwitches     = $exportVSwitches
}

# ============================================================
# ENREGISTREMENT DU FICHIER
# ============================================================

$defaultFile = Join-Path (Get-Location) ("Portgroups_{0}_{1}.json" -f ($sourceInfo.IP -replace '[^\w\.-]', '_'), (Get-Date -Format "yyyyMMdd_HHmmss"))
$filePath    = Read-Host "`nChemin du fichier d'export (Entrée pour : $defaultFile)"
if ([string]::IsNullOrWhiteSpace($filePath)) { $filePath = $defaultFile }
$filePath = $filePath.Trim('"')

try {
    ConvertTo-Json -InputObject $export -Depth 10 | Set-Content -Path $filePath -Encoding UTF8 -ErrorAction Stop
    Write-Host "`n$($exportVSwitches.Count) vSwitch / $totalPortGroups groupe(s) de ports exporté(s) vers : $filePath" -ForegroundColor Green
}
catch {
    Write-Host "Erreur lors de l'écriture du fichier : $_" -ForegroundColor Red
}

Disconnect-VIServer -Server * -Confirm:$false
