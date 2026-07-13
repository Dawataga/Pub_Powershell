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

# Retourne le contrôleur SATA existant d'une VM, ou en crée un via l'API Vim
# (New-VM n'a pas d'équivalent PowerCLI pour créer un contrôleur SATA seul).
function Get-OrNewSataController {
    param($VM)
    $existing = $VM.ExtensionData.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualAHCIController] } | Select-Object -First 1
    if ($existing) { return $existing }

    $deviceSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $deviceSpec.Operation = [VMware.Vim.VirtualDeviceConfigSpecOperation]::add
    $controller = New-Object VMware.Vim.VirtualAHCIController
    $controller.Key       = -1
    $controller.BusNumber = 0
    $deviceSpec.Device    = $controller

    $configSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $configSpec.DeviceChange = @($deviceSpec)
    $VM.ExtensionData.ReconfigVM($configSpec)
    $VM.ExtensionData.UpdateViewData()

    return ($VM.ExtensionData.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualAHCIController] } | Select-Object -First 1)
}

# Crée un disque directement via l'API Vim, attaché à un contrôleur donné (clé de
# périphérique). Utilisé pour les disques SATA : New-HardDisk -Controller n'accepte
# qu'un contrôleur SCSI typé PowerCLI, pas un contrôleur SATA.
function New-VimHardDisk {
    param($VM, [int]$ControllerKey, [double]$CapacityGB, [string]$StorageFormat, $Datastore)

    $usedUnits = @($VM.ExtensionData.Config.Hardware.Device |
        Where-Object { $_.ControllerKey -eq $ControllerKey } |
        ForEach-Object { $_.UnitNumber })
    $unitNumber = 0
    while ($usedUnits -contains $unitNumber) { $unitNumber++ }

    $backing = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
    $backing.DiskMode        = 'persistent'
    $backing.ThinProvisioned = ($StorageFormat -eq 'Thin')
    $backing.EagerlyScrub    = ($StorageFormat -eq 'EagerZeroedThick')
    $backing.FileName        = "[$($Datastore.Name)]"

    $disk = New-Object VMware.Vim.VirtualDisk
    $disk.ControllerKey = $ControllerKey
    $disk.UnitNumber    = $unitNumber
    $disk.Key           = -100
    $disk.CapacityInKB  = [long]($CapacityGB * 1MB)
    $disk.Backing       = $backing

    $deviceSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $deviceSpec.Operation     = [VMware.Vim.VirtualDeviceConfigSpecOperation]::add
    $deviceSpec.FileOperation = [VMware.Vim.VirtualDeviceConfigSpecFileOperation]::create
    $deviceSpec.Device        = $disk

    $configSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $configSpec.DeviceChange = @($deviceSpec)
    $VM.ExtensionData.ReconfigVM($configSpec)
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
    $disks           = Get-HardDisk -VM $vm
    $nics            = Get-NetworkAdapter -VM $vm
    $scsiControllers = Get-ScsiController -VM $vm
    $cdDrives        = Get-CDDrive -VM $vm
    $allDevices      = $vm.ExtensionData.Config.Hardware.Device
    $sataControllers = $allDevices | Where-Object { $_ -is [VMware.Vim.VirtualAHCIController] }
    $usbControllers  = $allDevices | Where-Object { $_ -is [VMware.Vim.VirtualUSBController] -or $_ -is [VMware.Vim.VirtualUSBXHCIController] }
    $usbDevices      = Get-UsbDevice -VM $vm

    # Associe chaque disque à son contrôleur (SCSI ou SATA), pour recréer le même
    # type/bus côté cible (LSI Logic, LSI Logic SAS, ParaVirtual, BusLogic, SATA...).
    $controllerByKey = @{}
    foreach ($ctrl in $scsiControllers) {
        $controllerByKey[$ctrl.ExtensionData.Key] = [pscustomobject]@{ Kind = 'Scsi'; BusNumber = $ctrl.ExtensionData.BusNumber; Type = $ctrl.Type }
    }
    foreach ($ctrl in $sataControllers) {
        $controllerByKey[$ctrl.Key] = [pscustomobject]@{ Kind = 'Sata'; BusNumber = $ctrl.BusNumber; Type = 'SATA' }
    }

    $controllerSpecs = @($scsiControllers | ForEach-Object {
        [pscustomobject]@{ Kind = 'Scsi'; BusNumber = $_.ExtensionData.BusNumber; Type = $_.Type }
    })
    $controllerSpecs += @($sataControllers | ForEach-Object {
        [pscustomobject]@{ Kind = 'Sata'; BusNumber = $_.BusNumber; Type = 'SATA' }
    })

    $diskControllerInfo = @{}
    foreach ($disk in $disks) {
        $diskControllerInfo[$disk.Id] = $controllerByKey[$disk.ExtensionData.ControllerKey]
    }

    $sataUsedByDisk = @($disks | Where-Object { $diskControllerInfo[$_.Id].Kind -eq 'Sata' })
    $usbControllerTypes = @($usbControllers | ForEach-Object { $_.GetType().Name } | Sort-Object -Unique)

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
    }

    Write-Host "`n--- Spécifications relevées sur $($vm.Name) ---" -ForegroundColor Cyan
    $specs.GetEnumerator() | ForEach-Object { Write-Host "$($_.Key) : $($_.Value)" }

    Write-Host "Contrôleurs SCSI/SATA :"
    foreach ($ctrl in $controllerSpecs) {
        Write-Host "  - $($ctrl.Kind) bus $($ctrl.BusNumber) : $($ctrl.Type)"
    }

    Write-Host "Disques :"
    foreach ($disk in $disks) {
        $info = $diskControllerInfo[$disk.Id]
        Write-Host "  - $($disk.Name) : $($disk.CapacityGB) Go, format $($disk.StorageFormat), contrôleur $($info.Kind) bus $($info.BusNumber)"
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

    Write-Host "Contrôleur SATA : $(if ($sataControllers) { if ($sataUsedByDisk.Count -gt 0) { "présent, utilisé par $($sataUsedByDisk.Count) disque(s)" } else { "présent, non utilisé par un disque" } } else { 'absent' })"

    Write-Host "Contrôleur USB : $(if ($usbControllerTypes) { "présent ($($usbControllerTypes -join ', ')), $(@($usbDevices).Count) périphérique(s) connecté(s)" } else { 'absent' })"
    if (@($usbDevices).Count -gt 0) {
        Write-Host "  ATTENTION : les périphériques USB passthrough ne peuvent pas être répliqués (liés au matériel physique de l'hôte source)." -ForegroundColor Yellow
    }

    [pscustomobject]@{
        Specs               = $specs
        Disks               = $disks
        Nics                = $nics
        Controllers         = $controllerSpecs
        DiskControllerInfo  = $diskControllerInfo
        CDDriveCount        = @($cdDrives).Count
        UsbControllerTypes  = $usbControllerTypes
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
        NetworkMap         = $networkMap
        Controllers        = $entry.Controllers
        DiskControllerInfo = $entry.DiskControllerInfo
        CDDriveCount       = $entry.CDDriveCount
        UsbControllerTypes = $entry.UsbControllerTypes
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

        # New-VM ajoute un disque, un contrôleur SCSI et une carte réseau par défaut
        # (dimensionnés/typés selon le GuestId) même sans -DiskGB/-NetworkName :
        # on retire disque et carte réseau avant de recréer ceux de la source.
        Get-HardDisk -VM $newVM | Remove-HardDisk -DeletePermanently:$true -Confirm:$false
        Get-NetworkAdapter -VM $newVM | Remove-NetworkAdapter -Confirm:$false

        # Recréation des disques (vides, sans les données source).
        $scsiDisks = @($item.Disks | Where-Object { $item.DiskControllerInfo[$_.Id].Kind -eq 'Scsi' })
        $sataDisks = @($item.Disks | Where-Object { $item.DiskControllerInfo[$_.Id].Kind -eq 'Sata' })

        # Disques SCSI, regroupés par bus source pour recréer le bon type de
        # contrôleur. New-ScsiController n'a pas de paramètre -VM : il faut lui passer
        # un disque existant, donc on ne traite que les bus utilisés par un disque.
        $availableTargetControllers = @(Get-ScsiController -VM $newVM)
        $busControllerMap = @{}

        # Hashtable classique (pas [ordered]) : un OrderedDictionary a un indexeur par
        # position en plus de celui par clé, ce qui provoque une erreur "index" dès que
        # la clé est un entier (le bus SCSI) ne correspondant à aucune position existante.
        $disksByBus = @{}
        foreach ($disk in $scsiDisks) {
            $busNumber = $item.DiskControllerInfo[$disk.Id].BusNumber
            if (-not $disksByBus.Contains($busNumber)) { $disksByBus[$busNumber] = @() }
            $disksByBus[$busNumber] += $disk
        }

        foreach ($busNumber in ($disksByBus.Keys | Sort-Object)) {
            $ctrlSpec  = $item.Controllers | Where-Object { $_.Kind -eq 'Scsi' -and $_.BusNumber -eq $busNumber } | Select-Object -First 1
            $isFirst   = $true

            foreach ($disk in $disksByBus[$busNumber]) {
                if ($isFirst) {
                    if ($availableTargetControllers.Count -gt 0) {
                        # Réutilise un contrôleur existant (ex: celui créé par défaut par New-VM)
                        $controller = $availableTargetControllers[0]
                        $availableTargetControllers = @($availableTargetControllers | Select-Object -Skip 1)
                        if ($controller.Type -ne $ctrlSpec.Type) {
                            Write-Host "[$($item.TargetName)] Contrôleur SCSI : $($controller.Type) -> $($ctrlSpec.Type)"
                            $controller = Set-ScsiController -ScsiController $controller -Type $ctrlSpec.Type -Confirm:$false
                        }
                        Write-Host "[$($item.TargetName)] Création du disque $($disk.CapacityGB) Go (format $($disk.StorageFormat), contrôleur $($ctrlSpec.Type))..."
                        New-HardDisk -VM $newVM -CapacityGB $disk.CapacityGB -StorageFormat $disk.StorageFormat -Datastore $targetDatastore -Controller $controller -Confirm:$false | Out-Null
                    } else {
                        # Plus de contrôleur disponible : on crée le disque puis un nouveau
                        # contrôleur à partir de ce disque (New-ScsiController -HardDisk).
                        Write-Host "[$($item.TargetName)] Création du disque $($disk.CapacityGB) Go (format $($disk.StorageFormat))..."
                        $newDisk = New-HardDisk -VM $newVM -CapacityGB $disk.CapacityGB -StorageFormat $disk.StorageFormat -Datastore $targetDatastore -Confirm:$false
                        Write-Host "[$($item.TargetName)] Création du contrôleur SCSI ($($ctrlSpec.Type))..."
                        $controller = New-ScsiController -HardDisk $newDisk -Type $ctrlSpec.Type -Confirm:$false
                    }
                    $busControllerMap[$busNumber] = $controller
                    $isFirst = $false
                } else {
                    $controller = $busControllerMap[$busNumber]
                    Write-Host "[$($item.TargetName)] Création du disque $($disk.CapacityGB) Go (format $($disk.StorageFormat), contrôleur $($ctrlSpec.Type))..."
                    New-HardDisk -VM $newVM -CapacityGB $disk.CapacityGB -StorageFormat $disk.StorageFormat -Datastore $targetDatastore -Controller $controller -Confirm:$false | Out-Null
                }
            }
        }

        # Disques SATA : recréés directement via l'API Vim, car New-HardDisk -Controller
        # n'accepte qu'un contrôleur SCSI typé PowerCLI, pas un contrôleur SATA.
        if ($sataDisks.Count -gt 0) {
            $sataController = Get-OrNewSataController -VM $newVM
            foreach ($disk in $sataDisks) {
                Write-Host "[$($item.TargetName)] Création du disque SATA $($disk.CapacityGB) Go (format $($disk.StorageFormat))..."
                New-VimHardDisk -VM $newVM -ControllerKey $sataController.Key -CapacityGB $disk.CapacityGB -StorageFormat $disk.StorageFormat -Datastore $targetDatastore
            }
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

        # Recréation des lecteurs CD/DVD (sans média, la source n'est pas copiée).
        # Un lecteur CD a besoin d'un contrôleur IDE ou SATA ; New-VM n'en crée pas
        # forcément un par défaut selon le GuestId/la version matérielle.
        if ($item.CDDriveCount -gt 0) {
            $hasIdeOrSata = $newVM.ExtensionData.Config.Hardware.Device | Where-Object {
                $_ -is [VMware.Vim.VirtualIDEController] -or $_ -is [VMware.Vim.VirtualAHCIController]
            }
            if (-not $hasIdeOrSata) {
                Write-Host "[$($item.TargetName)] Ajout d'un contrôleur SATA (requis pour le lecteur CD/DVD)..."
                Get-OrNewSataController -VM $newVM | Out-Null
            }

            for ($i = 0; $i -lt $item.CDDriveCount; $i++) {
                Write-Host "[$($item.TargetName)] Création du lecteur CD/DVD $($i + 1)..."
                New-CDDrive -VM $newVM -StartConnected:$false -Confirm:$false | Out-Null
            }
        }

        # Réplique le(s) contrôleur(s) USB présent(s) sur la source si absent(s) sur la
        # cible (les périphériques USB passthrough eux-mêmes ne sont pas reproductibles,
        # ils sont liés au matériel physique de l'hôte source).
        if ($item.UsbControllerTypes) {
            $existingUsbTypes = @($newVM.ExtensionData.Config.Hardware.Device | Where-Object {
                $_ -is [VMware.Vim.VirtualUSBController] -or $_ -is [VMware.Vim.VirtualUSBXHCIController]
            } | ForEach-Object { $_.GetType().Name })

            foreach ($typeName in ($item.UsbControllerTypes | Where-Object { $existingUsbTypes -notcontains $_ })) {
                Write-Host "[$($item.TargetName)] Ajout d'un contrôleur USB ($typeName)..."
                $usbDeviceSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
                $usbDeviceSpec.Operation = [VMware.Vim.VirtualDeviceConfigSpecOperation]::add
                $usbController = New-Object "VMware.Vim.$typeName"
                $usbController.Key      = -1
                $usbDeviceSpec.Device    = $usbController

                $usbConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
                $usbConfigSpec.DeviceChange = @($usbDeviceSpec)
                $newVM.ExtensionData.ReconfigVM($usbConfigSpec)
            }
        }

        Write-Host "VM '$($item.TargetName)' créée avec succès sur $($targetInfo.IP)." -ForegroundColor Green
    }
    catch {
        Write-Host "Erreur lors de la création de '$($item.TargetName)' : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  (ligne $($_.InvocationInfo.ScriptLineNumber) : $($_.InvocationInfo.Line.Trim()))" -ForegroundColor Red
    }
}

Write-Host "`nTerminé. Rappel : les disques sont vides (pas de données copiées)." -ForegroundColor Yellow
Disconnect-VIServer -Server * -Confirm:$false
