Param (
        [parameter(Mandatory=$false)]
        [String]$SubscriptionName = "Visual Studio Ultimate with MSDN", # Replace this param with your Subscription name, please make sure you have add-azureaccount or import publishsetting file already
        [parameter(Mandatory=$false)]
        [String]$StorageAccountName = "perconadbstorage", # Replace this param with your Storage Account 
        [parameter(Mandatory=$false)]
        [String]$Servicename = "perconadbcluster", # Replace this param with your cluster name
        [parameter(Mandatory=$false)]
        [String]$Location = "West US", # Replace this with the location you want to deploy *hint same as your Storage Account
        [parameter(Mandatory=$false)]
        [String]$CertToDeploy = "C:\temp\MYSQL Cluster on Azure\shzhai.cer", # Replace your azure ssh public certificate to upload to azure, if using Password leave this as blank 
        [parameter(Mandatory=$false)]
        [String]$Keypath = "/home/shzhai/.ssh/authorized_keys",
        [parameter(Mandatory=$false)]
        [String]$LinuxImage = "Ubuntu Server 12.04 LTS", # Current support Ubuntu 12.04 LTS and CentOS 6.5
        [parameter(Mandatory=$false)]
        [String]$InstanceSize = "Large",
        [parameter(Mandatory=$false)]
        [String]$NodePrefix = "PXCNode-",
        [parameter(Mandatory=$false)]
        [String]$LinuxUser = "shzhai", # Azure user you want to use login percona cluster VM
        [parameter(Mandatory=$false)]
        [String]$LinuxPassword = "", # Password you want to input, leave as blank when using public certificate you upload ahead
        [parameter(Mandatory=$false)]
        [String]$VNetName = "westus-rvnet1", # Shoud be same region with your Location and Storage Account, and should precreate 
        [parameter(Mandatory=$false)]
        [String]$DBSubnet = "DB", # You should precreate this Subnet on above Virtual Network  
        [parameter(Mandatory=$false)]
        [String[]]$DBNodeIPs = "172.16.20.20,172.16.20.21,172.16.20.22", # input each IP within DBsubnet 
        [parameter(Mandatory=$false)]
        [String]$LoadBalancerIP = "172.16.20.30", # input Load balancer VIP for internal load balancer should within IP Range of DBSubnet
        [parameter(Mandatory=$false)]
        [String]$ExtraNICName = "eth1", # If you using second NIC, leave this as intact or please leave it blank!
        [parameter(Mandatory=$false)]
        [String]$ExtraNICSubnet = "HB", # If using second NIC, precreate this Subnet and input param as the subnet
        [parameter(Mandatory=$false)]
        [String[]]$ExtraNICIPs = "172.16.20.36,172.16.20.37,172.16.20.38", # If using second NIC, input those IPs within the subnet
        [parameter(Mandatory=$false)]
        [String]$NumofDisks = "4", # Default Data disk, please make sure you can create that much with you VM Size
        [parameter(Mandatory=$false)]
        [String]$DiskSizeinGB = "32",
        [parameter(Mandatory=$false)] # Default Data disk size 
        [String]$VMExtLocation = "https://github.com/shzhai/PXConAzure/blob/master/DeployPXC/azurepxc.sh", 
        [parameter(Mandatory=$false)]
        [String]$MyCnfLocation = "https://github.com/shzhai/PXConAzure/blob/master/DeployPXC/my.cnf.template" # This is a default Percona db config file, you can change with your own and place your URL here
        )


$VerbosePreference = "Continue"

function CheckSubnet ([string]$cidr, [string]$ip)
{
    $network, [int]$subnetlen = $cidr.Split('/')
    $a = [uint32[]]$network.split('.')
    [uint32] $unetwork = ($a[0] -shl 24) + ($a[1] -shl 16) + ($a[2] -shl 8) + $a[3]

    $mask = (-bnot [uint32]0) -shl (32 - $subnetlen)

    $a = [uint32[]]$ip.split('.')
    [uint32] $uip = ($a[0] -shl 24) + ($a[1] -shl 16) + ($a[2] -shl 8) + $a[3]

    return ($unetwork -eq ($mask -band $uip))
}

function New-AzureLinuxService ([string]$Servicename, [string]$Location,[string]$CertToDeploy) 
{

    if (!(Test-AzureName -Service $Servicename -ErrorAction SilentlyContinue)){
    Write-Verbose "Creating Service $Servicename..."
    New-AzureService -ServiceName $Servicename -Location $Location
    Start-Sleep -Seconds 1
    $svcstatus = Get-AzureService -ServiceName $Servicename
    While ($svcstatus.Status -ne "Created") 
        {
            Start-Sleep -Seconds 1
            $svcstatus = Get-AzureService -ServiceName $servicename
        }
            Write-Verbose ("Service $Servicename has been created")
    }
    elseif ((Get-AzureService -ServiceName $Servicename).location -ne $Location )
    {
        Write-Error ("Existing {0} Conflict with Virtual Network Location {1}!" -f $Servicename,$Location)
        break
     }
    if ($CertToDeploy -ne "")                 
    {    
         Try 
         { 
               Write-Verbose "Adding Service $Servicename certificate..."
               Add-AzureCertificate -ServiceName $Servicename -CertToDeploy $CertToDeploy
               $Script:Certinstalled = $true 
          }
          Catch { Throw "Unable to install certificate to $Servicename because of：$Error[0] "}        
    }
}

function Select-UptodateAzureVMImage (
[String]$Image,
[Parameter(ParameterSetName='Parameter Set 1')]
[switch]$WindowsOS,
[Parameter(ParameterSetName='Parameter Set 2')]
[switch]$LinuxOS
)
{
    if ($WindowsOS.IsPresent) 
        {$Images = Get-AzureVMImage | Where-Object {$_.OS -eq "Windows" -and $_.ImageFamily -imatch "$Image"}  
            if ($Images -ne $null) {$Images | Sort-Object -Property PublishedDate -Descending  | Select-Object -First 1}
            else {
                Write-Error "Image $Image is not found, Please check the Image you type is correct!"
                break
            }
         }
    if ($LinuxOS.IsPresent) 
        {$Images = Get-AzureVMImage | Where-Object {$_.OS -eq "Linux" -and $_.ImageFamily -imatch "$Image"}  
         if ($Images -ne $null) {$Images | Sort-Object -Property PublishedDate -Descending  | Select-Object -First 1}
         else {
            Write-Warning "Image $Image is not found, Please check the Image you type is correct!"
            }
         }
} 

function New-PerconaCluster (
$Servicename,
$Imagename,
$SSHKey, 
$Instancesize,
$NodePrefix,
$LinuxUser,
$VNetName,
$DBSubnet,
$DBNodeIPs,
$LoadBalancerIP,
$ExtraNICName,
$ExtraNICSubnet,
$ExtraNICIPs,
$NumofDisks,
$DiskSizeinGB,
$ExistingVMPorts
)
{
    $LoadBalancerName = $NodePrefix + 'iLB'
    $LoadBalancerSetName = $NodePrefix + 'iLBSet'
    $AvailabilitySetName =$NodePrefix + "HAset"
    $ExtraVMIPs = $null
    $Nodes = $DBNodeIPs.split(",")
    $ExtensionName="CustomScriptForLinux"
    $ExtensionPublisher="Microsoft.OSTCExtensions"
    $ExtensionVersion="1.*"
    $MySQLPort=3306
    $MySQLProbePort=9200
    $ilbConfig = New-AzureInternalLoadBalancerConfig -InternalLoadBalancerName $LoadBalancerName -StaticVNetIPAddress $LoadBalancerIP -SubnetName $DBSubnet    
    if (($ExtraNICName) -and ($ExtraNICName -ne ""))
    {
        $ExtraVMIPs = $ExtraNICIPs.Split(",")
    }


    for ($i=0; $i -lt $Nodes.count;$i++)
    {
        $VMName = $NodePrefix + ($i + 1)
        $VMIP = $Nodes[$i].Trim(' ')
        $EPName = "MYSQL" + $VMName
        $PublicPort = (22+$i)
        if (Get-AzureVM -ServiceName $Servicename -Name $VMName){
            Write-Error ("Node {0} already exist in cloud service {1}, can't create!" -f $VMName,$Servicename)
            break
        }

        $VM = New-AzureVMConfig -Name $VMName -InstanceSize $Instancesize -ImageName $ImageName -AvailabilitySetName $AvailabilitySetName
        if ($LinuxPassword -eq "")
        { 
            Add-AzureProvisioningConfig -VM $VM -Linux -LinuxUser $LinuxUser -NoSSHPassword -SSHPublicKeys $SSHKey
        }
        else {
            Add-AzureProvisioningConfig -VM $VM -Linux -LinuxUser $LinuxUser -Password $LinuxPassword
        }
        Set-AzureSubnet -SubnetNames $DBSubnet -VM $VM
        Set-AzureStaticVNetIP -IPAddress $VMIP -VM $VM
        
       
        if (($ExtraVMIPs) -and ($ExtraVMIPs -ne $null)) 
        {
            $VMIP2 = $ExtraVMIPs[$i].Trim(' ')
            Add-AzureNetworkInterfaceConfig -Name $ExtraNICName -SubnetName $ExtraNICSubnet -StaticVNetIPAddress $VMIP2 -VM $VM
            $Params = $ExtraNICIPs.Trim(' ') + ' ' + $VMIP2 + ' '
        }
        else
        {
            $Params = $DBNodeIPs.Trim(' ') + ' ' + $VMIP + ' '
        }
         
         <# if (!($ExistingVMPorts -contains $PublicPort))
        {
            Set-AzureEndpoint -Name "SSH" -Protocol tcp -LocalPort 22  -VM $VM -PublicPort $PublicPort
        }
        #>

        Add-AzureEndpoint -LBSetName $LoadBalancerSetName -Name $EPName -Protocol tcp -LocalPort $MySQLPort -PublicPort $MySQLPort -ProbePort $MySQLProbePort -ProbeProtocol http -ProbePath '/' -InternalLoadBalancerName $LoadBalancerName -VM $VM

        for ($j=0; $j -lt $NumOfDisks; $j++)
        {
            $DiskLabel = $VMName + "-datadisk" + ($j+1)
            Add-AzureDataDisk -CreateNew -DiskSizeInGB $DiskSizeInGB -DiskLabel $DiskLabel -LUN $j -VM $VM
        }
        if ($i -eq 0)
        {
            $Params += "bootstrap-pxc "
        }
        else 
        {
            $Params += "start "
        }
        
        $Params += $MyCnfLocation.Trim(' ') + ' ' + $ExtraNICName.Trim(' ') + ' '

        if ($LinuxPassword -ne ""){$Params += "ALLOWPWD"}

        $PublicVMExtConfig = '{"fileUris":["' + $VMExtLocation +'"], "commandToExecute": "bash azurepxc.sh ' + $Params + '" }'
        
        Set-AzureVMExtension -ExtensionName $ExtensionName -Publisher $ExtensionPublisher -Version $ExtensionVersion -PublicConfiguration $PublicVMExtConfig -VM $VM

        Write-Verbose -Verbose ("Creating VM {0}" -f $VMName)
        New-AzureVM -ServiceName $ServiceName -VNetName $VNetName -VM $VM -InternalLoadBalancerConfig $ilbConfig
        Start-Sleep -Seconds 5
        $VMStatus = Get-AzureVM -ServiceName $ServiceName -Name $VMName
        Write-Verbose -Verbose ("VM {0} is {1}" -f $VMName, $VMstatus.PowerState)
        While (($VMStatus.PowerState -ne "Started") -or ($VMstatus.InstanceStatus -ne "ReadyRole"))
        {
            Start-Sleep -Seconds 5
            $VMstatus = Get-AzureVM -ServiceName $ServiceName -Name $VMName
        }
        Write-Verbose -Verbose ("VM {0} {1}" -f $VMName, $VMstatus.PowerState)
    }
}




Select-AzureSubscription -SubscriptionName $SubscriptionName
Set-AzureSubscription -SubscriptionName $SubscriptionName -CurrentStorageAccountName $StorageAccountName
$AzureVersion = (Get-Module -ListAvailable -Name Azure).Version
$ExistingVMPorts = Get-AzureVM | Get-AzureEndpoint | Select-Object -ExpandProperty Port


# Validate Configuration
if (!(Get-AzureLocation | Where-Object {$_.DisplayName -eq $Location}))
{
    Write-Error ("Specified Location {0} doesn't within current Azure subscription {1}" -f $Location,$SubscriptionName)
    break
}
$StorageAccount = Get-AzureStorageAccount -StorageAccountName $StorageAccountName
$StorageLocation = $StorageAccount.Location
$Imagename = (Select-UptodateAzureVMImage -LinuxOS -Image $LinuxImage -ErrorAction SilentlyContinue).ImageName
if (!($Imagename)) 
{
    Write-Error ("Linux image {0} doesn't exist, can't process!" -f $LinuxImage)
    break
}
if (($LinuxPassword -ne "") -and ($CertToDeploy -ne "")) {
    Write-Error ("Can't provide ceritificate and linux password at the same time! Choose either way only")
    break
}
[xml]$VNetConfig = (Get-AzureVNetConfig).XMLConfiguration
$VNetLocation = ($VNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites.VirtualNetworkSite | where {$_.name -eq $VNetName}).Location
if ($StorageLocation -ne $VNetLocation) {
    Write-Error  ("Storage account {0} in location {1} should be in the same region as the Virtual network {2} in location {3}!" -f $StorageAccountName,$StorageLocation,$VNetName,$VNetLocation)
    break
}

if ($StorageAccount.AccountType -ne "Standard_LRS"){
    Write-Error ("Storage account {0} should be configured to use local(Standard_LRS) only!" -f $StorageAccountName)
    break
}

if (!(Get-AzureVNetSite -VNetName $VNetName -ErrorAction SilentlyContinue)) {
    Write-Error (" Virtual Network {0} Doesn't exist, you need to preconfigure Virtual Network with subnet to deploy!" -f $VNetName)
    break
} 

if (!(Test-AzureStaticVNetIP -VNetName $VNetName -IPAddress $LoadBalancerIP).IsAvailable){
        Write-Error ("Load Balancer IP {0} is not available in VNet {1}." -f $LoadBalancerIP, $VNetName)
        break  
}
 
$vNetSubNetObj = (Get-AzureVNetSite -VNetName $VNetName -ErrorAction SilentlyContinue).Subnets

if (!($vNetSubNetObj).Name -contains $DBSubnet){
    Write-Error ("You must create the subnet {0} in {1} for the Nodes!" -f $DBSubnet, $VNetName)
    break
}
 
if ($DBNodeIPs.split(",").Count -lt 3) {
    Write-Error ("Nodes IP should more than 3 in a Cluster")
    break
}

$vNetDBSubNetObj = $vNetSubNetObj | Where-Object {$_.Name -eq $DBSubnet}

if (!(CheckSubnet -cidr $vNetDBSubNetObj.AddressPrefix -ip $LoadBalancerIP))
    {
        Write-Error ("Loadbalancer IP {0} not valid within {1} subnet!" -f $LoadBalancerIP,$DBSubnet)
        break
    }

foreach ($DBNodeIP in $DBNodeIPs.split(",")) {
    if (!(CheckSubnet -cidr $vNetDBSubNetObj.AddressPrefix -ip $DBNodeIP) -or !(Test-AzureStaticVNetIP -VNetName $VNetName -IPAddress $DBNodeIP).IsAvailable)
    {
        Write-Error ("Node IP {0} is not available in subnet {1}!" -f $NodeIP, $DBSubnet)
        break    
    } 
}

if ($ExtraNICName -and ($ExtraNICName -ne "")){
    if ($AzureVersion.Minor -eq 8 -and $AzureVersion.Build -lt 12)
    {
        Write-Error ("Multiple NIC is not supported in this version of Azure SDK. Clear ExtraNICName or upgrade above 0.8.12 and try again!")
        break
    }
    if (!(Get-AzureVNetSite -VNetName $VNetName).Subnets.Name -contains $ExtraNICSubnet){
        Write-Error ("You must create the subnet {0} in {1} for the Nodes!" -f $ExtraNICSubnet, $VNetName)
        break
    }
    
    if (($ExtraNICIPs).split(",").Count -ne ($DBNodeIPs).split(",").Count) {
        Write-Error "ExtraNICIPs and DBNodeIPs must have same number!"
        break
   }

    $vNetExtraSubNetObj = $vNetSubNetObj | Where-Object {$_.Name -eq $ExtraNICSubnet}
    foreach ($ExtraNICIP in ($ExtraNICIPs).split(",")) {
    if (!(CheckSubnet -cidr $vNetExtraSubNetObj.AddressPrefix -ip $ExtraNICIP) -or !(Test-AzureStaticVNetIP -VNetName $VNetName -IPAddress $ExtraNICIP).IsAvailable)
        {
        Write-Error ("Node IP {0} is not available in subnet {1}!" -f $ExtraNICIP, $ExtraNICSubnet)
        break    
        } 
    }
}


  

if (!($?)) {

    throw "Can't proceed create Percona Cluster, please fix issues $($error[0])"

}

# Try Create Cloud service with certificate first    
New-AzureLinuxService -Servicename $Servicename -CertToDeploy $CertToDeploy -Location $Location

# Create Percona Cluster VMs
if ($?) 
{
    if ($Certinstalled)
    {
        $Certificate = Get-AzureCertificate -ServiceName $Servicename
        $Thumbprint = $Certificate[0].Thumbprint
        $sshkey = New-AzureSSHKey -PublicKey -Fingerprint $Thumbprint -Path $KeyPath
    }
     
New-PerconaCluster -Servicename $Servicename -Imagename $Imagename -SSHKey $sshkey `
-Instancesize $InstanceSize -NodePrefix $NodePrefix -LinuxUser $LinuxUser -LinuxPassword $LinuxPassword `
-DBSubnet $DBSubnet -DBNodeIPs $DBNodeIPs -LoadBalancerIP $LoadBalancerIP `
-ExtraNICName $ExtraNICName -ExtraNICSubnet $ExtraNICSubnet -ExtraNICIPs $ExtraNICIPs `
-NumofDisks $NumofDisks -DiskSizeinGB $DiskSizeinGB -VNetName $VNetName -ExistingVMPorts $ExistingVMPorts
}
