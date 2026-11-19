<#
.SYNOPSIS
    Liste les VMs d'un vCenter ayant un ISO monté dans un lecteur CD/DVD.

.DESCRIPTION
    Ce script interactif se connecte à un vCenter (ou un hôte ESXi), parcourt toutes les VMs
    et remonte celles dont au moins un lecteur CD/DVD pointe vers un fichier ISO.
    Pour chaque lecteur, il indique :
      - le chemin de l'ISO
      - si le lecteur est actuellement connecté (Connected)
      - s'il est configuré pour se connecter à la mise sous tension (StartConnected)
    Le résultat est affiché à l'écran et peut être exporté en CSV.

.NOTES
    Prérequis : Module VCF.PowerCLI (anciennement VMware.PowerCLI) installé.
    Remarque  : une VM éteinte remonte toujours Connected = False ; c'est StartConnected
                qui indique si l'ISO sera connecté au prochain démarrage.
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
# CONNEXION
# ============================================================

$server   = Read-Host "Entrez l'adresse IP ou le nom d'hôte du vCenter"
$username = Read-Host "Entrez le nom d'utilisateur"
$password = Read-Host "Entrez le mot de passe" -AsSecureString
$credential = New-Object System.Management.Automation.PSCredential ($username, $password)

try {
    Connect-VIServer $server -Credential $credential -ErrorAction Stop | Out-Null
    Write-Host "Connecté à $server" -ForegroundColor Green
} catch {
    Write-Host "Échec de la connexion à $server : $($_.Exception.Message)" -ForegroundColor Red
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    exit
}

# ============================================================
# COLLECTE
# ============================================================

Write-Host "Récupération des VMs en cours..." -ForegroundColor Cyan

# Get-View avec une liste restreinte de propriétés : beaucoup plus rapide que Get-VM | Get-CDDrive
# sur un vCenter comportant de nombreuses VMs
$vmViews = Get-View -ViewType VirtualMachine -Property Name, Runtime.PowerState, Runtime.Host, Config.Hardware.Device, Config.Template

# Cache des noms d'hôtes ESXi pour éviter un appel par VM
$hostNames = @{}
Get-View -ViewType HostSystem -Property Name | ForEach-Object { $hostNames[$_.MoRef.Value] = $_.Name }

$results = foreach ($vm in $vmViews) {
    if ($vm.Config.Template) { continue }

    $cdDrives = $vm.Config.Hardware.Device | Where-Object {
        $_ -is [VMware.Vim.VirtualCdrom] -and $_.Backing -is [VMware.Vim.VirtualCdromIsoBackingInfo]
    }

    foreach ($cd in $cdDrives) {
        [PSCustomObject]@{
            VM             = $vm.Name
            PowerState     = $vm.Runtime.PowerState
            Host           = $hostNames[$vm.Runtime.Host.Value]
            CDDrive        = $cd.DeviceInfo.Label
            ISO            = $cd.Backing.FileName
            Connected      = $cd.Connectable.Connected
            StartConnected = $cd.Connectable.StartConnected
        }
    }
}

# ============================================================
# RÉSULTATS
# ============================================================

if (-not $results) {
    Write-Host "Aucune VM n'a d'ISO monté dans un lecteur CD/DVD." -ForegroundColor Green
    Disconnect-VIServer -Server * -Confirm:$false
    exit
}

$results = $results | Sort-Object VM, CDDrive
$results | Format-Table -AutoSize

$connectedCount = ($results | Where-Object Connected).Count
Write-Host "$($results.Count) lecteur(s) avec ISO trouvé(s) sur $(($results | Select-Object -Unique VM).Count) VM(s), dont $connectedCount connecté(s)." -ForegroundColor Cyan

$export = Read-Host "Exporter le résultat en CSV ? (O/N)"
if ($export -match '^[Oo]$') {
    $csvPath = Join-Path $PSScriptRoot ("ISO_montes_{0}_{1}.csv" -f $server, (Get-Date -Format "yyyyMMdd_HHmmss"))
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Write-Host "Export réalisé : $csvPath" -ForegroundColor Green
}

Disconnect-VIServer -Server * -Confirm:$false
