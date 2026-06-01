<#
.SYNOPSIS
    Copie des Port Groups d'un vSwitch source vers un vSwitch cible entre deux hôtes ESXi.

.DESCRIPTION
    Ce script interactif se connecte à deux hôtes ESXi (source et cible), permet de
    sélectionner un vSwitch source et les Port Groups à copier, puis les recrée sur le
    vSwitch cible (existant ou nouveau) en préservant les VLAN IDs et les politiques de sécurité.

.NOTES
    Prérequis : Module VMware.PowerCLI ou VCF.PowerCLI installé.
#>

# ============================================================
# PRÉREQUIS
# ============================================================

# Vérifie la présence du module PowerCLI (deux noms possibles selon la version)
$powerCLIModule = Get-Module -ListAvailable -Name "VMware.PowerCLI", "VCF.PowerCLI" | Select-Object -First 1
if (-not $powerCLIModule) {
    Write-Host "Le module VMware PowerCLI n'est pas installé. Installez-le avec : Install-Module VMware.PowerCLI" -ForegroundColor Red
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

# ============================================================
# CONNEXION AUX HÔTES ESXI
# ============================================================

Write-Host "Informations pour le serveur ESXi source :"
$sourceInfo = Get-ServerInfo

Write-Host "Informations pour le serveur ESXi cible :"
$targetInfo = Get-ServerInfo

# Toute erreur de connexion est fatale : on déconnecte les sessions ouvertes avant de sortir
try {
    Connect-VIServer $sourceInfo.IP -Credential $sourceInfo.Credential -ErrorAction Stop
    Connect-VIServer $targetInfo.IP -Credential $targetInfo.Credential -ErrorAction Stop
}
catch {
    Write-Host "Erreur de connexion : $_" -ForegroundColor Red
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    exit
}

# ============================================================
# SÉLECTION DU VSWITCH SOURCE
# ============================================================

$sourceVSwitches = Get-VirtualSwitch -VMHost $sourceInfo.IP
Write-Host "`nvSwitch disponibles sur SOURCE ($($sourceInfo.IP)) :"
for ($i = 0; $i -lt $sourceVSwitches.Count; $i++) {
    Write-Host "$($i+1). $($sourceVSwitches[$i].Name)"
}

# Boucle jusqu'à saisie valide d'un index de vSwitch
$vswitchIndex = $null
while ($null -eq $vswitchIndex) {
    $userinput = Read-Host "Entrez le numéro du vSwitch source"
    if ($userinput -match '^\d+$' -and [int]$userinput -ge 1 -and [int]$userinput -le $sourceVSwitches.Count) {
        $vswitchIndex = [int]$userinput - 1
    } else { Write-Host "Invalide." -ForegroundColor Yellow }
}

$sourceVSwitchObj = $sourceVSwitches[$vswitchIndex]
$vswitchName      = $sourceVSwitchObj.Name

# ============================================================
# SÉLECTION DES PORT GROUPS SOURCE
# ============================================================

$sourcePortGroups = $sourceVSwitchObj | Get-VirtualPortGroup
Write-Host "Groupes de ports sur $vswitchName :"
for ($i = 0; $i -lt $sourcePortGroups.Count; $i++) {
    Write-Host "$($i+1). $($sourcePortGroups[$i].Name) (VLAN: $($sourcePortGroups[$i].VLanId))"
}

# Accepte une sélection mixte du type "1-5,7" (plages et numéros individuels)
$selectedPortGroups = $null
while (-not $selectedPortGroups) {
    $selection       = Read-Host "Entrez les numéros des groupes de ports à copier (ex: 1-5,7)"
    $selectedIndices = @()
    $valid           = $true

    foreach ($part in $selection.Split(',')) {
        $part = $part.Trim()

        if ($part -match '^(\d+)-(\d+)$') {
            # Traitement d'une plage (ex : 2-5)
            $start = [int]$Matches[1]; $end = [int]$Matches[2]
            if ($start -gt $end) {
                Write-Host "Plage invalide : '$part' (début > fin)." -ForegroundColor Yellow
                $valid = $false; break
            }
            if ($start -lt 1 -or $end -gt $sourcePortGroups.Count) {
                Write-Host "Plage hors limites : '$part' (max: $($sourcePortGroups.Count))." -ForegroundColor Yellow
                $valid = $false; break
            }
            $selectedIndices += $start..$end

        } elseif ($part -match '^\d+$') {
            # Traitement d'un numéro individuel
            $num = [int]$part
            if ($num -lt 1 -or $num -gt $sourcePortGroups.Count) {
                Write-Host "Numéro hors limites : '$num' (max: $($sourcePortGroups.Count))." -ForegroundColor Yellow
                $valid = $false; break
            }
            $selectedIndices += $num

        } else {
            Write-Host "Valeur non reconnue : '$part'." -ForegroundColor Yellow
            $valid = $false; break
        }
    }

    if ($valid -and $selectedIndices.Count -gt 0) {
        # Dédoublonnage des indices avant de résoudre les objets Port Group
        $selectedIndices    = $selectedIndices | Sort-Object -Unique
        $selectedPortGroups = $sourcePortGroups | Where-Object {
            $selectedIndices -contains ([array]::IndexOf($sourcePortGroups, $_) + 1)
        }
    } elseif ($valid) {
        Write-Host "Aucun groupe sélectionné." -ForegroundColor Yellow
    }
}

# ============================================================
# CHOIX OU CRÉATION DU VSWITCH CIBLE
# ============================================================

Write-Host "`n--- Configuration du vSwitch CIBLE ---" -ForegroundColor Cyan
$targetVSwitches = Get-VirtualSwitch -VMHost $targetInfo.IP
Write-Host "0. [CRÉER UN NOUVEAU VSWITCH] (Nom: $vswitchName)" -ForegroundColor Green
for ($i = 0; $i -lt $targetVSwitches.Count; $i++) {
    Write-Host "$($i+1). $($targetVSwitches[$i].Name)"
}

$targetVswitchName = $null
$choice = Read-Host "Choisissez un vSwitch existant ou '0' pour créer à l'identique"

if ($choice -eq "0") {
    # Garde-fou : si le vSwitch existe déjà sous le même nom, on le réutilise plutôt que d'échouer
    $checkSwitch = Get-VirtualSwitch -VMHost $targetInfo.IP -Name $vswitchName -ErrorAction SilentlyContinue
    if ($checkSwitch) {
        Write-Host "Le vSwitch '$vswitchName' existe déjà sur la cible. Utilisation de l'existant." -ForegroundColor Yellow
        $targetVswitchName = $vswitchName
    } else {
        Write-Host "Création du vSwitch '$vswitchName' sur $($targetInfo.IP)..." -ForegroundColor Green
        # MTU repris du vSwitch source pour garantir la cohérence réseau
        $newVSwitch        = New-VirtualSwitch -VMHost $targetInfo.IP -Name $vswitchName -Mtu $sourceVSwitchObj.Mtu
        $targetVswitchName = $newVSwitch.Name
    }
} else {
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $targetVSwitches.Count) {
        $targetVswitchName = $targetVSwitches[[int]$choice - 1].Name
    } else {
        Write-Host "Choix invalide. Sortie du script." -ForegroundColor Red
        Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
        exit
    }
}

# ============================================================
# CONFIRMATION ET EXÉCUTION
# ============================================================

Write-Host "`nRésumé : Copie vers vSwitch '$targetVswitchName' sur $($targetInfo.IP)"
$confirmation = Read-Host "Confirmer l'opération ? (O/N)"
if ($confirmation -notmatch '^[Oo]$') { Disconnect-VIServer -Server * -Confirm:$false ; exit }

$targetSwitch = Get-VirtualSwitch -VMHost $targetInfo.IP -Name $targetVswitchName

foreach ($pg in $selectedPortGroups) {
    $existingPg = Get-VirtualPortGroup -VirtualSwitch $targetSwitch -Name $pg.Name -ErrorAction SilentlyContinue

    if ($existingPg) {
        Write-Host "Le groupe $($pg.Name) existe déjà. Ignoré." -ForegroundColor Yellow
    } else {
        Write-Host "Création de $($pg.Name) (VLAN $($pg.VLanId))..."
        $newPg = New-VirtualPortGroup -VirtualSwitch $targetSwitch -Name $pg.Name -VLanId $pg.VLanId

        # Réplication de la politique de sécurité (promiscuité, MAC spoofing, forged transmits)
        $sourcePolicy = $pg | Get-SecurityPolicy
        $newPg | Get-SecurityPolicy | Set-SecurityPolicy `
            -AllowPromiscuous $sourcePolicy.AllowPromiscuous `
            -ForgedTransmits   $sourcePolicy.ForgedTransmits `
            -MacChanges        $sourcePolicy.MacChanges
    }
}

Write-Host "`nTerminé !"
Disconnect-VIServer -Server * -Confirm:$false
