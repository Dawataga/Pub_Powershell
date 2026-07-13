<#
.SYNOPSIS
    Récupère les spécifications d'une VM sur un hôte ESXi source et recrée une VM équivalente sur un hôte ESXi cible.

.DESCRIPTION
    Ce script interactif se connecte à deux hôtes ESXi (source et cible), permet de sélectionner
    une ou plusieurs VMs source, lit leurs caractéristiques (CPU, mémoire, disques, cartes réseau,
    firmware, version matérielle, OS invité, notes) puis crée pour chacune une nouvelle VM vide
    sur l'hôte cible avec la même configuration (même enveloppe, sans les données).
    Ecrit en tout ou partie avec Claude Code

.NOTES
    Prérequis : Module VMware.PowerCLI ou VCF.PowerCLI installé.
#>

# ============================================================
# PRÉREQUIS
# ============================================================

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

# Boucle générique de sélection dans une liste numérotée
function Select-FromList {
    param($Items, [string]$Prompt)
    $index = $null
    while ($null -eq $index) {
        $userinput = Read-Host $Prompt
        if ($userinput -match '^\d+$' -and [int]$userinput -ge 1 -and [int]$userinput -le $Items.Count) {
            $index = [int]$userinput - 1
        } else { Write-Host "Invalide." -ForegroundColor Yellow }
    }
    return $Items[$index]
}

# Demande une confirmation O/N ; reboucle si la saisie est vide ou ni O ni N
function Confirm-Action {
    param([string]$Prompt)
    while ($true) {
        $response = Read-Host "$Prompt (O/N)"
        if ($response -match '^[Oo]$') { return $true }
        if ($response -match '^[Nn]$') { return $false }
        Write-Host "Réponse invalide, entrez O ou N." -ForegroundColor Yellow
    }
}

# Sélection multiple dans une liste numérotée, accepte le format "1-3,5"
function Select-MultipleFromList {
    param($Items, [string]$Prompt)
    $selected = $null
    while (-not $selected) {
        $selection       = Read-Host $Prompt
        $selectedIndices = @()
        $valid           = $true

        foreach ($part in $selection.Split(',')) {
            $part = $part.Trim()

            if ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1]; $end = [int]$Matches[2]
                if ($start -gt $end) {
                    Write-Host "Plage invalide : '$part' (début > fin)." -ForegroundColor Yellow
                    $valid = $false; break
                }
                if ($start -lt 1 -or $end -gt $Items.Count) {
                    Write-Host "Plage hors limites : '$part' (max: $($Items.Count))." -ForegroundColor Yellow
                    $valid = $false; break
                }
                $selectedIndices += $start..$end

            } elseif ($part -match '^\d+$') {
                $num = [int]$part
                if ($num -lt 1 -or $num -gt $Items.Count) {
                    Write-Host "Numéro hors limites : '$num' (max: $($Items.Count))." -ForegroundColor Yellow
                    $valid = $false; break
                }
                $selectedIndices += $num

            } else {
                Write-Host "Valeur non reconnue : '$part'." -ForegroundColor Yellow
                $valid = $false; break
            }
        }

        if ($valid -and $selectedIndices.Count -gt 0) {
            $selectedIndices = $selectedIndices | Sort-Object -Unique
            $selected        = $selectedIndices | ForEach-Object { $Items[$_ - 1] }
        } elseif ($valid) {
            Write-Host "Aucun élément sélectionné." -ForegroundColor Yellow
        }
    }
    return @($selected)
}

# ============================================================
# CONNEXION AUX HÔTES ESXI
# ============================================================

Write-Host "Informations pour le serveur ESXi source :"
$sourceInfo = Get-ServerInfo

Write-Host "Informations pour le serveur ESXi cible :"
$targetInfo = Get-ServerInfo

try {
    $sourceConn = Connect-VIServer $sourceInfo.IP -Credential $sourceInfo.Credential -ErrorAction Stop
    $targetConn = Connect-VIServer $targetInfo.IP -Credential $targetInfo.Credential -ErrorAction Stop
}
catch {
    Write-Host "Erreur de connexion : $_" -ForegroundColor Red
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    exit
}

# ============================================================
# SÉLECTION DES VMS SOURCE
# ============================================================

$sourceVMs = Get-VM -Server $sourceConn | Sort-Object Name
if (-not $sourceVMs) {
    Write-Host "Aucune VM trouvée sur $($sourceInfo.IP)." -ForegroundColor Red
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    exit
}

Write-Host "`nVMs disponibles sur SOURCE ($($sourceInfo.IP)) :"
for ($i = 0; $i -lt $sourceVMs.Count; $i++) {
    Write-Host "$($i+1). $($sourceVMs[$i].Name) ($($sourceVMs[$i].PowerState))"
}
$selectedVMs = Select-MultipleFromList -Items $sourceVMs -Prompt "Entrez les numéros des VMs à recréer (ex: 1-3,5)"

# Avertit si une VM sélectionnée est allumée : les specs lues à chaud (hot-add,
# changements non commités côté config) peuvent ne pas refléter exactement la réalité.
$poweredOnVMs = $selectedVMs | Where-Object { $_.PowerState -eq 'PoweredOn' }
if ($poweredOnVMs) {
    Write-Host "`nATTENTION : les VMs suivantes sont allumées. Les caractéristiques relevées peuvent ne pas être exactes (valeurs à chaud, hot-add, etc.) :" -ForegroundColor Yellow
    foreach ($vm in $poweredOnVMs) {
        Write-Host "  - $($vm.Name) : $($vm.NumCpu) vCPU ($($vm.CoresPerSocket) cores/socket), $($vm.MemoryGB) Go RAM" -ForegroundColor Yellow
    }
    if (-not (Confirm-Action "Continuer avec ces VMs allumées ?")) {
        Write-Host "Opération annulée." -ForegroundColor Red
        Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
        exit
    }
}

# ============================================================
# LECTURE DES SPÉCIFICATIONS DES VMS SOURCE
# ============================================================

$vmSpecs = foreach ($vm in $selectedVMs) {
    $disks       = Get-HardDisk -VM $vm
    $nics        = Get-NetworkAdapter -VM $vm
    $controllers = Get-ScsiController -VM $vm
    $cdDrives    = Get-CDDrive -VM $vm
    $floppies    = Get-FloppyDrive -VM $vm

    # Associe chaque disque au bus de son contrôleur SCSI, pour recréer le même type
    # de contrôleur (LSI Logic, LSI Logic SAS, ParaVirtual, BusLogic...) côté cible.
    $controllerByKey = @{}
    foreach ($ctrl in $controllers) { $controllerByKey[$ctrl.ExtensionData.Key] = $ctrl }

    $controllerSpecs = $controllers | ForEach-Object {
        [pscustomobject]@{ BusNumber = $_.ExtensionData.BusNumber; Type = $_.Type }
    }

    $diskControllerBus = @{}
    foreach ($disk in $disks) {
        $ctrl = $controllerByKey[$disk.ExtensionData.ControllerKey]
        $diskControllerBus[$disk.Id] = $ctrl.ExtensionData.BusNumber
    }

    $resourceConfig = Get-VMResourceConfiguration -VM $vm

    $specs = [ordered]@{
        Name                  = $vm.Name
        NumCpu                = $vm.NumCpu
        CoresPerSocket        = $vm.CoresPerSocket
        MemoryGB              = $vm.MemoryGB
        GuestId               = $vm.ExtensionData.Config.GuestId
        HWVersion             = $vm.HardwareVersion
        Firmware              = $vm.ExtensionData.Config.Firmware
        Notes                 = $vm.Notes
        CpuHotAddEnabled      = $vm.ExtensionData.Config.CpuHotAddEnabled
        MemoryHotAddEnabled   = $vm.ExtensionData.Config.MemoryHotAddEnabled
        CpuReservationMhz     = $resourceConfig.CpuReservationMhz
        CpuLimitMhz           = $resourceConfig.CpuLimitMhz
        CpuSharesLevel        = $resourceConfig.CpuSharesLevel
        NumCpuShares          = $resourceConfig.NumCpuShares
        MemReservationMB      = $resourceConfig.MemReservationMB
        MemLimitMB            = $resourceConfig.MemLimitMB
        MemSharesLevel        = $resourceConfig.MemSharesLevel
        NumMemShares          = $resourceConfig.NumMemShares
    }

    Write-Host "`n--- Spécifications relevées sur $($vm.Name) ---" -ForegroundColor Cyan
    $specs.GetEnumerator() | ForEach-Object { Write-Host "$($_.Key) : $($_.Value)" }

    Write-Host "Contrôleurs SCSI :"
    foreach ($ctrl in $controllerSpecs) {
        Write-Host "  - Bus $($ctrl.BusNumber) : $($ctrl.Type)"
    }

    Write-Host "Disques :"
    foreach ($disk in $disks) {
        Write-Host "  - $($disk.Name) : $($disk.CapacityGB) Go, format $($disk.StorageFormat), bus SCSI $($diskControllerBus[$disk.Id])"
    }

    Write-Host "Cartes réseau :"
    foreach ($nic in $nics) {
        Write-Host "  - $($nic.Name) : $($nic.NetworkName), type $($nic.Type)"
    }

    Write-Host "Lecteurs CD/DVD :"
    if ($cdDrives) {
        foreach ($cd in $cdDrives) { Write-Host "  - $($cd.Name)" }
    } else {
        Write-Host "  (aucun)"
    }

    Write-Host "Lecteurs disquette :"
    if ($floppies) {
        foreach ($fd in $floppies) { Write-Host "  - $($fd.Name)" }
    } else {
        Write-Host "  (aucun)"
    }

    [pscustomobject]@{
        Specs              = $specs
        Disks              = $disks
        Nics               = $nics
        Controllers        = $controllerSpecs
        DiskControllerBus  = $diskControllerBus
        CDDriveCount       = @($cdDrives).Count
        FloppyDriveCount   = @($floppies).Count
    }
}

# ============================================================
# CHOIX DE LA CIBLE (HÔTE, DATASTORE)
# ============================================================

$targetVMHost = Get-VMHost -Server $targetConn | Select-Object -First 1

$targetDatastores = Get-Datastore -VMHost $targetVMHost | Sort-Object Name
if (-not $targetDatastores) {
    Write-Host "Aucun datastore trouvé sur $($targetInfo.IP)." -ForegroundColor Red
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    exit
}
Write-Host "`nDatastores disponibles sur CIBLE ($($targetInfo.IP)) :"
for ($i = 0; $i -lt $targetDatastores.Count; $i++) {
    Write-Host "$($i+1). $($targetDatastores[$i].Name) ($([math]::Round($targetDatastores[$i].FreeSpaceGB)) Go libres)"
}
$targetDatastore = Select-FromList -Items $targetDatastores -Prompt "Entrez le numéro du datastore cible (utilisé pour toutes les VMs)"

$targetPortGroups = Get-VirtualPortGroup -VMHost $targetVMHost

# ============================================================
# DÉTERMINATION DU NOM CIBLE ET DE LA CORRESPONDANCE RÉSEAU (PAR VM)
# ============================================================

$networkCache = @{}   # Réutilisé entre VMs pour ne pas reposer la même question deux fois
$plan = foreach ($entry in $vmSpecs) {
    $baseName   = $entry.Specs.Name
    $targetName = Read-Host "Nom de la VM cible pour '$baseName' (Entrée pour garder ce nom)"
    if ([string]::IsNullOrWhiteSpace($targetName)) { $targetName = $baseName }

    while (Get-VM -Server $targetConn -Name $targetName -ErrorAction SilentlyContinue) {
        do {
            $targetName = Read-Host "Une VM '$targetName' existe déjà sur la cible. Nouveau nom pour '$baseName'"
        } while ([string]::IsNullOrWhiteSpace($targetName))
    }

    $networkMap = @{}
    foreach ($nic in $entry.Nics) {
        if ($networkCache.ContainsKey($nic.NetworkName)) {
            $networkMap[$nic.Name] = $networkCache[$nic.NetworkName]
            continue
        }

        $match = $targetPortGroups | Where-Object { $_.Name -eq $nic.NetworkName }
        if ($match) {
            $resolved = $nic.NetworkName
        } else {
            Write-Host "`nLe groupe de ports '$($nic.NetworkName)' (VM '$baseName', carte $($nic.Name)) n'existe pas sur la cible." -ForegroundColor Yellow
            Write-Host "0. [IGNORER cette carte réseau]"
            for ($i = 0; $i -lt $targetPortGroups.Count; $i++) {
                Write-Host "$($i+1). $($targetPortGroups[$i].Name)"
            }
            $choice = Read-Host "Choisissez un groupe de ports de remplacement"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $targetPortGroups.Count) {
                $resolved = $targetPortGroups[[int]$choice - 1].Name
            } else {
                $resolved = $null
            }
        }
        $networkCache[$nic.NetworkName] = $resolved
        $networkMap[$nic.Name]          = $resolved
    }

    [pscustomobject]@{
        TargetName        = $targetName
        Specs             = $entry.Specs
        Disks             = $entry.Disks
        Nics              = $entry.Nics
        NetworkMap        = $networkMap
        Controllers       = $entry.Controllers
        DiskControllerBus = $entry.DiskControllerBus
        CDDriveCount      = $entry.CDDriveCount
        FloppyDriveCount  = $entry.FloppyDriveCount
    }
}

# ============================================================
# CONFIRMATION ET CRÉATION DES VMS
# ============================================================

Write-Host "`nRésumé : création de $($plan.Count) VM(s) sur $($targetInfo.IP) / $($targetDatastore.Name) :"
foreach ($item in $plan) { Write-Host "  - $($item.Specs.Name) -> $($item.TargetName)" }
if (-not (Confirm-Action "Confirmer l'opération ?")) { Disconnect-VIServer -Server * -Confirm:$false ; exit }

foreach ($item in $plan) {
    try {
        $newVMParams = @{
            Name           = $item.TargetName
            VMHost         = $targetVMHost
            Datastore      = $targetDatastore
            NumCpu         = $item.Specs.NumCpu
            CoresPerSocket = $item.Specs.CoresPerSocket
            MemoryGB       = $item.Specs.MemoryGB
            GuestId        = $item.Specs.GuestId
            HardwareVersion = $item.Specs.HWVersion
            Notes          = $item.Specs.Notes
            Confirm        = $false
        }
        $newVM = New-VM @newVMParams -ErrorAction Stop

        # Le firmware (BIOS/EFI) et le hot-add CPU/RAM ne sont pas exposés par New-VM :
        # reconfiguration via l'API Vim.
        $configSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $configSpec.Firmware            = $item.Specs.Firmware
        $configSpec.CpuHotAddEnabled    = $item.Specs.CpuHotAddEnabled
        $configSpec.MemoryHotAddEnabled = $item.Specs.MemoryHotAddEnabled
        $newVM.ExtensionData.ReconfigVM($configSpec)

        # Réservations / limites / shares CPU et mémoire
        $resourceParams = @{
            VM             = $newVM
            CpuReservationMhz = $item.Specs.CpuReservationMhz
            CpuLimitMhz       = $item.Specs.CpuLimitMhz
            CpuSharesLevel    = $item.Specs.CpuSharesLevel
            MemReservationMB  = $item.Specs.MemReservationMB
            MemLimitMB        = $item.Specs.MemLimitMB
            MemSharesLevel    = $item.Specs.MemSharesLevel
            Confirm           = $false
        }
        if ($item.Specs.CpuSharesLevel -eq 'Custom') { $resourceParams.NumCpuShares = $item.Specs.NumCpuShares }
        if ($item.Specs.MemSharesLevel -eq 'Custom') { $resourceParams.NumMemShares = $item.Specs.NumMemShares }
        Set-VMResourceConfiguration @resourceParams | Out-Null

        # New-VM ajoute un disque, un contrôleur SCSI et une carte réseau par défaut
        # (dimensionnés/typés selon le GuestId) même sans -DiskGB/-NetworkName :
        # on retire disque et carte réseau avant de recréer ceux de la source.
        Get-HardDisk -VM $newVM | Remove-HardDisk -DeletePermanently:$true -Confirm:$false
        Get-NetworkAdapter -VM $newVM | Remove-NetworkAdapter -Confirm:$false

        # Prépare les contrôleurs SCSI cible avec le même type que sur la source
        # (le contrôleur par défaut du bus 0 est réutilisé et retypé si besoin).
        $targetControllers = Get-ScsiController -VM $newVM
        $busControllerMap  = @{}
        foreach ($ctrlSpec in $item.Controllers) {
            $existing = $targetControllers | Where-Object { $_.ExtensionData.BusNumber -eq $ctrlSpec.BusNumber }
            if ($existing) {
                if ($existing.Type -ne $ctrlSpec.Type) {
                    Write-Host "[$($item.TargetName)] Contrôleur SCSI bus $($ctrlSpec.BusNumber) : $($existing.Type) -> $($ctrlSpec.Type)"
                    $existing = Set-ScsiController -ScsiController $existing -Type $ctrlSpec.Type -Confirm:$false
                }
                $busControllerMap[$ctrlSpec.BusNumber] = $existing
            } else {
                Write-Host "[$($item.TargetName)] Création du contrôleur SCSI bus $($ctrlSpec.BusNumber) ($($ctrlSpec.Type))..."
                $busControllerMap[$ctrlSpec.BusNumber] = New-ScsiController -VM $newVM -Type $ctrlSpec.Type -Confirm:$false
            }
        }

        # Recréation des disques (vides, sans les données source), sur le bon contrôleur
        foreach ($disk in $item.Disks) {
            $busNumber  = $item.DiskControllerBus[$disk.Id]
            $controller = $busControllerMap[$busNumber]
            Write-Host "[$($item.TargetName)] Création du disque $($disk.CapacityGB) Go (format $($disk.StorageFormat), contrôleur $($controller.Type) bus $busNumber)..."
            New-HardDisk -VM $newVM -CapacityGB $disk.CapacityGB -StorageFormat $disk.StorageFormat -Datastore $targetDatastore -Controller $controller -Confirm:$false | Out-Null
        }

        # Recréation des cartes réseau selon la correspondance établie plus haut
        foreach ($nic in $item.Nics) {
            $targetNetwork = $item.NetworkMap[$nic.Name]
            if ($targetNetwork) {
                Write-Host "[$($item.TargetName)] Création de la carte réseau sur '$targetNetwork' (type $($nic.Type))..."
                New-NetworkAdapter -VM $newVM -NetworkName $targetNetwork -Type $nic.Type -StartConnected:$true -Confirm:$false | Out-Null
            } else {
                Write-Host "[$($item.TargetName)] Carte réseau $($nic.Name) ignorée (aucune correspondance choisie)." -ForegroundColor Yellow
            }
        }

        # Recréation des lecteurs CD/DVD et disquette (sans média, la source n'est pas copiée)
        for ($i = 0; $i -lt $item.CDDriveCount; $i++) {
            Write-Host "[$($item.TargetName)] Création du lecteur CD/DVD $($i + 1)..."
            New-CDDrive -VM $newVM -NoMedia -Confirm:$false | Out-Null
        }
        for ($i = 0; $i -lt $item.FloppyDriveCount; $i++) {
            Write-Host "[$($item.TargetName)] Création du lecteur disquette $($i + 1)..."
            New-FloppyDrive -VM $newVM -NoMedia -Confirm:$false | Out-Null
        }

        Write-Host "VM '$($item.TargetName)' créée avec succès sur $($targetInfo.IP)." -ForegroundColor Green
    }
    catch {
        Write-Host "Erreur lors de la création de '$($item.TargetName)' : $_" -ForegroundColor Red
    }
}

Write-Host "`nTerminé. Rappel : les disques sont vides (pas de données copiées)." -ForegroundColor Yellow
Disconnect-VIServer -Server * -Confirm:$false
