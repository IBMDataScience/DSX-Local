#!/bin/bash

function checkRAM(){
    local size="$1"
    local limit="$2"
	if [[ ${size} -lt ${limit} ]]; then
		echo "ERROR: RAM size is ${size}GB, while requirement is ${limit}GB"  | tee -a ${OUTPUT}
		return 1
	fi
}

function checkCPU(){
    local size="$1"
    local limit="$2"
	if [[ ${size} -lt ${limit} ]]; then
		echo "ERROR: CPU cores are ${size}, while requirement are ${limit}"  | tee -a ${OUTPUT}
		return 1
	fi
}

function usage(){
	echo "This script checks if this node meets requirements for installation."
	echo "Arguments: "
	echo "--type=[9nodes_master|9nodes_deploy|9nodes_compute|3nodes]     To specify a node type"
	echo "--help                                                          To see help "
}


function checkkube(){
    if [ -d $line/.kube ] 
    then
        echo "ERROR: Found .kube directory in $line. Please remove the old version of kubernetes (rm -rf .kube) and try the installation again. " | tee -a ${OUTPUT}
        return 1
    else
        return 0
    fi
     
}


#Duplicate function also found in utils.sh
function binary_convert() {
    input=$1
    D2B=({0..1}{0..1}{0..1}{0..1}{0..1}{0..1}{0..1}{0..1})
    if (( input >=0 )) && (( input <= 255 ))
    then
        echo $((10#${D2B[${input}]}))
    else
        (>&2 echo "number ${input} is out of range [0,255]")
    fi
}

# Test the if weave subnet overlaps with node subnets
# Example --> test_subnet_overlap 9.30.168.0/16 subnet
#          subnet IP is 9.30.168.0
#          mask is 255.255.0.0
#          takes the logical AND of the subnet IP with the mask
#          Result is 9.30.0.0
#          Minimum of subnet range is 9.30.0.1
#          Add the range which is 2^(32-masknumber) - 2
#          Maximum is 9.30.255.254
#          Creates the minimum and maximum for ip route subnets
#          Compares the weave subnet which is passed to the ip route subnets
#          If the subnets overlap will return 1 and the overlapping subnet
#          If we have a non-default subnet in ip route will return 2 and the non-default field
function test_subnet_overlap() {
    local err_subnet=$3
    # Create the overlay mask
    if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        eval $err_subnet="$1"
        return 3
    fi
    local weave_mask_num=($(echo $1 | cut -d'/' -f2))
    local weave_mask="$(head -c $weave_mask_num < /dev/zero | tr '\0' '1')$(head -c $((32 - $weave_mask_num)) < /dev/zero | tr '\0' '0')"
    # Calculate range difference
    local diff=$((2**(32-$weave_mask_num)))
    # Break the overlay subnet IP into it's components
    local weave_sub=($(echo $1 | cut -d'/' -f1 | sed 's/\./ /g'))
    local weave_bin=""
    # Convert the overlay subnet IP to binary
    for weave in ${weave_sub[@]}; do
        cur_bin="00000000$(binary_convert $weave)"
        local weave_bin="${weave_bin}${cur_bin: -8}"
    done
    # Bitwise AND of the mask and binary overlay IP
    # Develop the range (minimum to maximum) of the overlay subnet
    local weave_min=$(echo $((2#$weave_bin & 2#$weave_mask)) | tr -d -)
    weave_min=$((weave_min + 1))
    local weave_max=($(($weave_min + $diff - 2)))
    # Perform the same steps for node routing subnets
    local ips=($2)
    for ip in ${ips[@]}; do
        if [[ ! "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            eval $err_subnet="$ip"
            return 2
        fi
        local sub_ip=($(echo $ip | cut -d'/' -f1 | sed 's/\./ /g'))
        local sub_mask_num=($(echo $ip | cut -d'/' -f2))
        local sub_mask="$(head -c $sub_mask_num < /dev/zero | tr '\0' '1')$(head -c $((32 - $sub_mask_num)) < /dev/zero | tr '\0' '0')"
        local sub_diff=$((2**(32-$sub_mask_num)))
        local sub_bin=""
        for sub in ${sub_ip[@]}; do
            bin="00000000$(binary_convert $sub)"
            local sub_bin="${sub_bin}${bin: -8}"
        done
        local sub_min=$(echo $((2#$sub_bin & 2#$sub_mask)) | tr -d -)
        sub_min=$((sub_min + 1))
        local sub_max=($(($sub_min + $sub_diff - 2)))
	# Check for if the overlay subnet and node routing subnet overlaps
        if [[ ("$sub_min" -gt "$weave_min" && "$sub_min" -le "$weave_max") || ("$weave_min" -gt "$sub_min" && "$weave_min" -le "$sub_max") || ("$sub_min" == "$weave_min" || "$sub_max" == "$weave_max") ]]; then
            echo "The overlay network ${1} is in the node routing subnet ${ip}"
	     # Define problem subnet
            eval $err_subnet="$ip"
            return 1
        else
            echo "The overlay network ${1} is not in the node routing subnet ${ip}"
        fi
    done
    return 0
}

function helper(){
	echo "##########################################################################################
   Help:
    ./$(basename $0) --type=[9nodes_master|9nodes_deploy|9nodes_compute|3nodes]
    Specify a node type and start the validation
    Checking preReq before installation
    Please run this script in all the nodes of your cluster
    Differnt node types have different RAM/CPU requirement
    List of validation:
    CPU
	ERROR for 9node master cpu core < 8, 9node deploy cpu core < 16, 9node compute cpu core < 16; for 3node cpu core < 16
	ERROR for 3node cpu core < 16
    RAM
	ERROR for 9node master RAM < 16GB, 9node deploy RAM < 32GB, 9node compute RAM size < 32GB; for 3node RAM size < 32GB
	ERROR for 3node RAM < 32GB
    Disk latency test:
     	WARNING dd if=/dev/zero of=/root/testfile bs=512 count=1000 oflag=dsync The value should be less than 10s for copying 512 kB
     	ERROR: must be less than 60s for copying 512 kB,
    Disk throughput test:
    	WARNING dd if=/dev/zero of=/root/testfile bs=1G count=1 oflag=dsync The value should be less than 5s for copying 1.1 GB
    	ERROR: must be less than 35s for copying 1.1 GB
    Chrony/NTP
    	WARNING check is ntp/chrony is setup
    Firewall disabled
    	ERROR firewalled and iptable is disabled
    Disk
    	ERROR root directory should have at least 10 GB
    	WARNING partition for installer files should have one xfs disk formartted and mounted > ${INSTALLPATH_SIZE}GB
    	WARNING partition for data storage should have one xfs disk formartted and mounted > ${DATAPATH_SIZE}GB
    Cron job check
    	ERROR check whether this node has a cronjob changes ip route, hosts file or firewall setting during installation
    Port 443 check
    	ERROR check port 443 is open
    SELinux check
    	ERROR check SElinux is either in enforcing or permissive mode
    Gateway check
    	ERROR check is gateway is setup
    DNS check
    	ERROR check is DNS service is setup which allow hostname map to ip
    Docker check
    	ERROR Check to confirm Docker is not installed
    Kubernetes check
    	ERROR Check to confirm Kubernetes is not installed
    Subnet check
        WARNING: Non-default routing subnets exist and start at the following word in ip route: ${subnet} that the installer failed to parse. Please verify these subnets yourself.
        ERROR: The overlay network ${WEAVE} conflicts with the node routing subnet ${subnet}
  ##########################################################################################"
}

function checkpath(){
	local mypath="$1"
	if [[  "$mypath" = "/"  ]]; then
		echo "ERROR: Can not use root path / as path" | tee -a ${OUTPUT}
		usage
		exit 1
	fi
	if [ ! -d "$mypath" ]; then
	    echo "ERROR: $mypath not found in node." | tee -a ${OUTPUT}
	    usage
	    exit 1
	fi
}

function become_cmd(){
    local BECOME_CMD="$1"
    if [[ "$(whoami)" != "root" && $pb_run -eq 0 ]]; then
        BECOME_CMD="sudo $BECOME_CMD"
    elif [[ "$(whoami)" != "root" && $pb_run -eq 1 ]]; then
        BECOME_CMD="pbrun bash -c \"$BECOME_CMD\""
    fi
    eval "$BECOME_CMD"
    return $?
}

function check_package_availability(){
    additional=""
    # $1 - Dependency being checked
    # $2 - Parent of this dependency (if it is not a subdependency this will be "none")
    # $3 - Version of the dependency (if these is no specific version uses empty string)
    # $4 - Determines if we allow installed versions of the packages or not
    #      will be i if we want to check for installed packages otherwise it will be empty
    pack_name="$(echo $1 | cut -d'#' -f1)"
    parent="$(echo $1 | cut -d'#' -f2)"
    version="$(echo $1 | cut -d'#' -f3)"
    pre_installable="$(echo $1 | cut -d'#' -f4)"
    error=0
    INSTALLSTATE=""
    installed=0
    testInstalled=""
    testAvailable=""
    if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
        testInstalled="$(${BECOME_CMD} \"yum list installed ${pack_name}\* 2> /dev/null\")"
    else
        testInstalled="$(${BECOME_CMD} yum list installed ${pack_name}\* 2> /dev/null)"
    fi
    installed=${PIPESTATUS[0]}
    package=0
    if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
        testAvailable="$(${BECOME_CMD} \"yum list available ${pack_name}\* 2> /dev/null\")"
    else
        testAvailable="$(${BECOME_CMD} yum list available ${pack_name}\* 2> /dev/null)"
    fi
    package=${PIPESTATUS[0]}
    if [[ "$version" != "" ]]; then
        if [[ $installed -eq 0 ]]; then
            echo "$testInstalled" | grep "$version" > /dev/null
            installed=$?
        fi
        if [[ $package -eq 0 ]]; then
            echo "$testAvailable" | grep "$version" > /dev/null
            package=$?
        fi
    fi
    if [[ $installed -eq 0 ]]; then
        if [[ "${pre_installable}" != "i" ]]; then
            if [[ $package -eq 0 ]]; then
                INSTALLSTATE="already installed. Please uninstall and continue."
                error=1
            else
                INSTALLSTATE="already installed and not available from the yum repos. Please uninstall and add the package with it's dependencies to the yum repos."
                error=1
            fi
        fi
    else
        if [[ $package -ne 0 ]]; then
            if [[ "${pre_installable}" != "i" ]]; then
                INSTALLSTATE="not available from the yum repos. Please add the package with it's dependencies to the yum repos."
                error=1
            else
                INSTALLSTATE="not available from the yum repos and not installed. Please add the package with it's dependencies to the yum repos or install the package."
                error=1
            fi
        fi
    fi
    if [[ $error -eq 1 ]]; then
        if [[ "${version}" != "" ]]; then
            if [[ "$parent" == "none" ]]; then
                echo "ERROR: ${pack_name} with version ${version} is ${INSTALLSTATE}" | tee -a ${OUTPUT}
            else
                echo "ERROR: The ${pack_name} dependency with version ${version} for the $parent package is ${INSTALLSTATE}" | tee -a ${OUTPUT}
            fi
        else
            if [[ "$parent" == "none" ]]; then
                echo "ERROR: ${pack_name} is ${INSTALLSTATE}" | tee -a ${OUTPUT}
            else
                echo "ERROR: The ${pack_name} dependency for the $parent package is ${INSTALLSTATE}" | tee -a ${OUTPUT}
            fi
            
        fi
    fi
    return $error
}

#for internal usage
NODETYPE="NODE_PLACEHOLDER" #if master one internal run will not check docker since we already install it
NODENUMBER="NODENUM_PLACEHOLDER"
INSTALLPATH="INSTALLPATH_PLACEHOLDER"
DATAPATH="DATAPATH_PLACEHOLDER"
CPU=0
RAM=0
WEAVE=0
pb_run=0
centos_repo=0

#Global parameter
INSTALLPATH_SIZE=150
DATAPATH_SIZE=350

#size in GB
DOCKER_BASE_SIZE=25

#setup output file
OUTPUT="/tmp/preInstallCheckResult"
rm -f ${OUTPUT}

WARNING=0
ERROR=0
LOCALTEST=0

if [[ "$(whoami)" != "root" && $pb_run -eq 0 ]]; then
    BECOME_CMD="sudo "
elif [[ "$(whoami)" != "root" && $pb_run -eq 1 ]]; then
    BECOME_CMD="pbrun bash -c "
fi

#input check
if [[  $# -ne 1  ]]; then
	if [[ "$INSTALLPATH" != "" ]]; then
		# This mean internal call the script, the script has already edited the INSTALLPATH DATAPATH CPU RAM by sed cmd
		checkpath $INSTALLPATH
		if [[ "$DATAPATH" != "" ]]; then
			checkpath "$DATAPATH"
		fi
	else
		usage
		exit 1
	fi
else
	# This mean the user runs script, will prompt user to input the INSTALLPATH DATAPATH
	if [[  "$1" = "--help"  ]]; then
		helper
		exit 1
	elif [ "$1" == "--type=9nodes_master" ] || [ "$1" == "--type=9nodes_deploy" ] || [ "$1" == "--type=9nodes_compute" ] || [ "$1" == "--type=3nodes" ]; then

		echo "Please enter the path of partition for installer files"
		read INSTALLPATH
		checkpath "$INSTALLPATH"

		if [[ "$1" = "--type=9nodes_deploy" ]]; then
			CPU=8
			RAM=24
		elif [[ "$1" = "--type=9nodes_master" ]]; then
			echo "Please enter the path of partition for data storage"
			read DATAPATH
			checkpath "$DATAPATH"
			CPU=8
			RAM=24
		elif [[ "$1" = "--type=9nodes_compute" ]]; then
			CPU=8
			RAM=24
		elif [[ "$1" = "--type=3nodes" ]]; then
			echo "Please enter the path of partition for data storage"
			read DATAPATH
			checkpath "$DATAPATH"
			CPU=8
			RAM=24
		else
			echo "please only specify type among 9nodes_master/9nodes_deploy/9nodes_compute/3nodes"
			exit 1
		fi
	else
		echo "Sorry the argument is invalid"
		usage
		exit 1
	fi
fi

echo "##########################################################################################" > ${OUTPUT} 2>&1
echo "Checking Disk latency and Disk throughput" | tee -a ${OUTPUT}
become_cmd "dd if=/dev/zero of=${INSTALLPATH}/testfile bs=512 count=1000 oflag=dsync &> output"

res=$(cat output | tail -n 1 | awk '{print $6}')
# writing this since bc may not be default support in customer environment
res_int=$(echo $res | grep -E -o "[0-9]+" | head -n 1)
if [[ $res_int -gt 60 ]]; then
	echo "ERROR: Disk latency test failed. By copying 512 kB, the time must be shorter than 60s, recommended to be shorter than 10s, validation result is ${res_int}s " | tee -a ${OUTPUT}
	ERROR=1
	LOCALTEST=1
elif [[ $res_int -gt 10 ]]; then
	echo "WARNING: Disk latency test failed. By copying 512 kB, the time recommended to be shorter than 10s, validation result is ${res_int}s " | tee -a ${OUTPUT}
	WARNING=1
	LOCALTEST=1
fi

become_cmd "dd if=/dev/zero of=${INSTALLPATH}/testfile bs=1G count=1 oflag=dsync &> output"

res=$(cat output | tail -n 1 | awk '{print $6}')
# writing this since bc may not be default support in customer environment
res_int=$(echo $res | grep -E -o "[0-9]+" | head -n 1)
if [[ $res_int -gt 35 ]]; then
	echo "ERROR: Disk throughput test failed. By copying 1.1 GB, the time must be shorter than 35s, recommended to be shorter than 5s, validation result is ${res_int}s " | tee -a ${OUTPUT}
	ERROR=1
	LOCALTEST=1
elif [[ $res_int -gt 5 ]]; then
	echo "WARNING: Disk throughput test failed. By copying 1.1 GB, the time is recommended to be shorter than 5s, validation result is ${res_int}s " | tee -a ${OUTPUT}
	WARNING=1
	LOCALTEST=1
fi
rm -f output > /dev/null 2>&1
rm -f ${INSTALLPATH}/testfile > /dev/null 2>&1
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1 
echo "Checking gateway" | tee -a ${OUTPUT} 
become_cmd "ip route" | grep "default" > /dev/null 2>&1


if [[ $? -ne 0 ]]; then
	echo "ERROR: default gateway is not setup " | tee -a ${OUTPUT}
	ERROR=1
	LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking DNS" | tee -a ${OUTPUT}

become_cmd "cat /etc/resolv.conf" | grep  -E "nameserver [0-9]+.[0-9]+.[0-9]+.[0-9]+" &> /dev/null

if [[ $? -ne 0 ]]; then
	echo "ERROR: DNS is not properly setup " | tee -a ${OUTPUT}
	ERROR=1
	LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking chrony / ntp" | tee -a ${OUTPUT}

TIMESYNCON=1  # 1 for not sync 0 for sync
become_cmd "systemctl status ntpd > /dev/null 2>&1"

if [[ $? -eq 0 || $? -eq 3 ]]; then     # 0 is active, 3 is active, both are ok here
	TIMESYNCON=0
fi 
become_cmd "systemctl status chronyd > /dev/null 2>&1" 

if [[ $? -eq 0 || $? -eq 3 ]]; then		# 0 is active, 3 is active, both are ok here
	TIMESYNCON=0
fi
if [[ ${TIMESYNCON} -ne 0 ]]; then
	echo "WARNING: NTP/Chronyc is not setup " | tee -a ${OUTPUT}
	WARNING=1
	LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking if firewall is shutdown" | tee -a ${OUTPUT}
become_cmd "service iptables status > /dev/null 2>&1"

if [ $? -eq 0 ]; then		 
	echo "WARNING: iptable is not disabled" | tee -a ${OUTPUT} 
	LOCALTEST=1
	WARNING=1
fi
become_cmd "service ip6tables status > /dev/null 2>&1"

if [ $? -eq 0 ]; then		 
	echo "WARNING: ip6table is not disabled" | tee -a ${OUTPUT} 
	LOCALTEST=1
	WARNING=1
fi
become_cmd "systemctl status firewalld > /dev/null 2>&1"

if [ $? -eq 0 ]; then		 
	echo "WARNING: firewalld is not disabled" | tee -a ${OUTPUT} 
	LOCALTEST=1
	WARNING=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking SELinux" | tee -a ${OUTPUT}
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    selinux_res="$(${BECOME_CMD} \"getenforce\" 2>&1)"
else 
    selinux_res="$(${BECOME_CMD} getenforce 2>&1)"
fi
if [[ ! "${selinux_res}" =~ ("Permissive"|"permissive"|"Enforcing"|"enforcing") ]]; then
	echo "ERROR: SElinux is not in enforcing or permissive mode"  | tee -a ${OUTPUT}
	LOCALTEST=1
	ERROR=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking pre-exsiting cronjob" | tee -a ${OUTPUT}
become_cmd "crontab -l" | grep -E "*" &> /dev/null

if [[ $? -eq 0 ]] ; then
	echo "WARNING: Found cronjob set up in background. Please make sure cronjob will not change ip route, hosts file or firewall setting during installation"  | tee -a ${OUTPUT}
	LOCALTEST=1
	WARNING=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking size of root partition" | tee -a ${OUTPUT}

if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    ROOTSIZE=$(${BECOME_CMD} "df -k -BG \"/\" | awk '{print($4 \" \" $6)}' | grep \"/\" | cut -d' ' -f1 | sed 's/G//g'")
else 
    ROOTSIZE=$(${BECOME_CMD} df -k -BG "/" | awk '{print($4 " " $6)}' | grep "/" | cut -d' ' -f1 | sed 's/G//g')
fi
if [[ $ROOTSIZE -lt 10 ]] ; then
	echo "ERROR: size of root partition is smaller than 10G"  | tee -a ${OUTPUT}
	LOCALTEST=1
	ERROR=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking if install path: ${INSTALLPATH} have enough space (${INSTALLPATH_SIZE}GB)" | tee -a ${OUTPUT}
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    PARTITION=$(${BECOME_CMD} "df -k -BG" | grep  ${INSTALLPATH})
else 
    PARTITION=$(${BECOME_CMD} df -k -BG | grep  ${INSTALLPATH})
fi
if [[ $? -ne 0 ]]; then 
	echo "ERROR: can not find the ${INSTALLPATH} partition you specified in install_path"  | tee -a ${OUTPUT} 
	LOCALTEST=1
	ERROR=1
else
	PARTITION=$(echo $PARTITION | tail -n 1 |  awk '{print $2}' | sed 's/G//g')
	if [[ ${PARTITION} -lt ${INSTALLPATH_SIZE} ]]; then
		echo "WARNING: size of install_path ${INSTALLPATH} is smaller than requirement (${INSTALLPATH_SIZE}GB)"  | tee -a ${OUTPUT}
		LOCALTEST=1
		ERROR=1
	fi
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

if [[ $DATAPATH != "" && $DATAPATH != "DATAPATH_PLACEHOLDER" ]]; then
	LOCALTEST=0
	echo "##########################################################################################" >> ${OUTPUT} 2>&1
	echo "This is a master node, checking if data path: ${DATAPATH} have enough space (${DATAPATH_SIZE}GB)" | tee -a ${OUTPUT}
	cmd='df -k -BG | grep  ${DATAPATH}'
    if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
        PARTITION=$(${BECOME_CMD} "df -k -BG" | grep  ${DATAPATH})
    else 
        PARTITION=$(${BECOME_CMD} df -k -BG | grep  ${DATAPATH})
    fi
	if [[ $? -ne 0 ]]; then 
		echo "ERROR: can not find the ${DATAPATH} partition you specified in data_path"  | tee -a ${OUTPUT} 
		LOCALTEST=1
		ERROR=1
	else
		PARTITION=$(echo $PARTITION | tail -n 1 |  awk '{print $2}' | sed 's/G//g')
		if [[ ${PARTITION} -lt ${DATAPATH_SIZE} ]]; then
			echo "WARNING: size of data_path ${DATAPATH} is smaller than requirement (${DATAPATH_SIZE}GB)"  | tee -a ${OUTPUT}
			LOCALTEST=1
			WARNING=1
		fi
	fi
	if [[ ${LOCALTEST} -eq 0 ]]; then
		echo "PASS" | tee -a ${OUTPUT}
	fi
	echo
	echo "##########################################################################################" >> ${OUTPUT} 2>&1
fi

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking if xfs is enabled" | tee -a ${OUTPUT}
become_cmd "xfs_info ${INSTALLPATH}" | grep "ftype=1" > /dev/null 2>&1


if [[ $? -ne 0 ]] ; then
	echo "ERROR: xfs is not enabled, ftype=0, should be 1"  | tee -a ${OUTPUT}
	LOCALTEST=1
	ERROR=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0

echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking CPU core numbers and RAM size" | tee -a ${OUTPUT}
# Get CPU numbers and min frequency
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    cpunum=$(${BECOME_CMD} "cat /proc/cpuinfo" | grep '^processor' |wc -l | xargs)
else
    cpunum=$(${BECOME_CMD} cat /proc/cpuinfo | grep '^processor' |wc -l | xargs)
fi
if [[ ! ${cpunum} =~ ^[0-9]+$ ]]; then
    echo  "ERROR: Invalid cpu numbers '${cpunum}'" | tee -a ${OUTPUT}
else
    checkCPU ${cpunum} ${CPU}
    if [[ $? -eq 1 ]]; then
	LOCALTEST=1
	WARNING=1
    fi
fi
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    mem=$(${BECOME_CMD} "cat /proc/meminfo" | grep MemTotal | awk '{print $2}')
else
    mem=$(${BECOME_CMD} cat /proc/meminfo | grep MemTotal | awk '{print $2}')
fi
# Get Memory info
mem=$(( $mem/1000000 ))
if [[ ! ${mem} =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid memory size '${mem}'" | tee -a ${OUTPUT}
else
    checkRAM ${mem} ${RAM}
    if [[ $? -eq 1 ]]; then
	LOCALTEST=1
	WARNING=1
    fi
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

osName=$(grep ^ID= /etc/os-release | cut -f2 -d'"')
arch=$(uname -m)
if [[ "$osName" == "centos" || "$arch" != "x86_64" ]]; then
    if [[ ${NODETYPE} != "master" && ${NODENUMBER} != "1" ]] || [[ $# -eq 1 ]]; then
    	LOCALTEST=0
    	echo "##########################################################################################" >> ${OUTPUT} 2>&1
    	echo "Checking to confirm docker is not installed " | tee -a ${OUTPUT}
        become_cmd "which docker > /dev/null 2>&1"
        rc1=$?
        become_cmd "systemctl status docker &> /dev/null"
        
        rc2=$?
    	if [[ ${rc1} -eq 0 ]] || [[ ${rc2} -eq 0 ]]; then
    		echo "ERROR: Docker is already installed, please uninstall Docker"  | tee -a ${OUTPUT}
    		LOCALTEST=1
    		ERROR=1
    	fi


    	if [[ ${LOCALTEST} -eq 0 ]]; then
    		echo "PASS" | tee -a ${OUTPUT}
    	fi
    	echo
    	echo "##########################################################################################" >> ${OUTPUT} 2>&1
    fi
fi

#checking if docker is syslink
become_cmd "which docker > /dev/null 2>&1"
rc1=$?
if [[ ${rc1} -eq 0 ]]; then
    echo "##########################################################################################" >> ${OUTPUT} 2>&1
    echo "Checking to confirm docker is installed correctly " | tee -a ${OUTPUT}
    docker_link=$(readlink -f /var/lib/docker)
    if [[ ${docker_link} == "/var/lib/docker" ]]; then
          	echo "ERROR: Docker is not sys-link to the installer path"  | tee -a ${OUTPUT}
    		LOCALTEST=1
    		ERROR=1
    else
        echo $docker_link | grep -E "^${INSTALLPATH}.*(docker|docker_link)$" &> /dev/null
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Docker directory has incorrect symbolic link. The correct way is ${INSTALLPATH}/docker_link or ${INSTALLPATH}/docker"  | tee -a ${OUTPUT}
            LOCALTEST=1
    	    ERROR=1
        fi
    fi
    cat /etc/docker/daemon.json | grep storage-driver | grep '"devicemapper"' &> /dev/null
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    	echo "WARNING: The docker missing the damon.json from /etc/docker/daemon.json, storage driver check will be ignored"
	LOCALTEST=1
        WARNING=1
    elif [[ $? -eq 0 ]]; then
        basesize=$(cat /etc/docker/daemon.json | grep dm.basesize | awk -F '=' '{print $2}' | sed -e 's/^"//' -e 's/"$//')
        num=$(echo ${basesize} | grep -oE [0-9]+)
        scale=$(echo ${basesize} | grep -oE '[a-zA-Z]{1,2}' | awk '{print toupper($0)}')
        if [[ ${scale} == "G" ]] || [[ ${scale} == "GB" ]]; then
            if [[ ${num} -lt ${DOCKER_BASE_SIZE} ]]; then
                echo "ERROR: incorrectly docker base size. Minimum base size is ${DOCKER_BASE_SIZE}G"  | tee -a ${OUTPUT}
                LOCALTEST=1
                ERROR=1
            fi
        elif [[ ${scale} == "M" ]] || [[ ${scale} == "MB" ]]; then
            if [[ ${num} -lt $(( ${DOCKER_BASE_SIZE} * 1024)) ]]; then
                echo "ERROR: incorrectly docker base size. Minimum base size is ${DOCKER_BASE_SIZE}G"  | tee -a ${OUTPUT}
                LOCALTEST=1
                ERROR=1
            fi
        else
            echo "ERROR: Docker is config with devicemapper but dm.basesize is missing"  | tee -a ${OUTPUT}
            LOCALTEST=1
            ERROR=1
        fi
    fi
    echo "##########################################################################################" >> ${OUTPUT} 2>&1
fi

LOCALTEST=0
echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking to confirm Kubernetes is not installed" | tee -a ${OUTPUT}

become_cmd "systemctl status kubelet &> /dev/null"

if [[ $? -eq 0 ]]; then
	echo "ERROR: Kubernetes is already installed with a different version or settings, please uninstall Kubernetes"  | tee -a ${OUTPUT}
	LOCALTEST=1
	ERROR=1
else
    become_cmd "which kubectl &> /dev/null"
    
	if [[ $? -eq 0 ]]; then
		echo "ERROR: Kubernetes is already installed with a different version or settings, please uninstall Kubernetes"  | tee -a ${OUTPUT}
		LOCALTEST=1
		ERROR=1
	fi
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1
LOCALTEST=0
echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Subnet check to find if weave subnet overlaps with node subnets" | tee -a ${OUTPUT}

if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    ROUTES=$(${BECOME_CMD} "ip route" | grep -v ^default | awk '{print $1;}')
else
    ROUTES=$(${BECOME_CMD} ip route | grep -v ^default | awk '{print $1;}')
fi

if [[ "${WEAVE}" = "0" ]]; then
    echo "Please enter the cluster overlay network: "
    read WEAVE
fi

test_subnet_overlap ${WEAVE} "${ROUTES[@]}" subnet > /dev/null 2>&1
rc=$?
if [[ $rc -eq 2 ]]; then
     echo "WARNING: Non-default routing subnets exist and start at the following word in ip route: ${subnet} that the installer failed to parse. Please verify these subnets yourself." | tee -a ${OUTPUT}
     WARNING=1
     LOCALTEST=1
elif [[ $rc -eq 1 ]]; then
     echo "ERROR: The overlay network ${WEAVE} conflicts with the node routing subnet ${subnet}" | tee -a ${OUTPUT}
     ERROR=1
     LOCALTEST=1
elif [[ $rc -eq 3 ]]; then
     echo "ERROR: The overlay network ${WEAVE} is not a subnet mask in CIDR notation, for example '9.242.0.0/16'." | tee -a ${OUTPUT}
     ERROR=1
     LOCALTEST=1
fi

if [[ ${LOCALTEST} -eq 0 ]]; then
	echo "PASS" | tee -a ${OUTPUT}
fi

echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0
echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking GPU driver if desired" | tee -a ${OUTPUT}
which lspci
if [[ $? -eq 0 ]]; then
    lspci 2>&1 | grep -i nvidia
    if [[ $? -eq 0 ]]; then
        nvidia-smi 2>&1 | grep 'Driver Version' > /dev/null
        if [[ $? -ne 0 ]]; then
            echo "WARNING: The GPU driver is not functioning properly" | tee -a ${OUTPUT}
            WARNING=1
            LOCALTEST=1
        fi

        if [[ ${LOCALTEST} -eq 0 ]]; then
            echo "PASS" | tee -a ${OUTPUT}
        fi
    else
        echo "Nvidia controller not found under lspci skipping this check" | tee -a ${OUTPUT}
    fi
else
    echo "lspci does not exist, ignore the GPU check" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1
LOCALTEST=0
echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking if localhost exists and is correct" | tee -a ${OUTPUT}
if [ ! -f /etc/hosts ]; then
    echo "ERROR: No /etc/hosts file found" | tee -a ${OUTPUT}
    ERROR=1
    LOCALTEST=1
else
    # Find a line has match "[[:space:]]\+localhost[[:space:]]\+" or "[[:space:]]\+localhost$"
    getLocal=$(grep '[[:space:]]\+localhost[[:space:]]\+\|[[:space:]]\+localhost$' /etc/hosts)
    if [[ $(echo "$getLocal" | sed '/^\s*$/d' | wc -l) > 0 ]]; then
        if [[ $(echo "$getLocal" | grep "^127.0.0.1 " | sed '/^\s*$/d' | wc -l) > 0 ]]; then
            if [[ $(echo "$getLocal" | grep -E -v '^::1 |^#'| wc -l) > 1 ]]; then
                echo "ERROR: Localhost is mapped to more than one IP entry" | tee -a ${OUTPUT}
                ERROR=1
                LOCALTEST=1
            fi
        else
            echo "ERROR: There is no localhost entry mapped to IP 127.0.0.1" | tee -a ${OUTPUT}
            ERROR=1
            LOCALTEST=1
        fi
    else
        echo "ERROR: There are no localhost entries in /etc/hosts" | tee -a ${OUTPUT}
        ERROR=1
        LOCALTEST=1
    fi
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
    echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1
LOCALTEST=0
echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking if appropriate os and version" | tee -a ${OUTPUT}
osName=$(grep ^ID= /etc/os-release | cut -f2 -d'"')
if [[ "$osName" == "rhel" || "$osName" == "centos" ]]; then
    supportedVersion=("7.3" "7.4" "7.5")
    osVer=$(grep ^VERSION_ID= /etc/os-release | cut -f2 -d'"')
    if [[ "$osName" == "centos" ]]; then
        osVer=$(awk '{print $4}' /etc/centos-release | cut -d\. -f1,2)
    fi
    if [[ ! " ${supportedVersion[@]} " =~ " $osVer " ]]; then
        echo "ERROR: The OS version must be ${supportedVersion[@]}" | tee -a ${OUTPUT}
        ERROR=1
        LOCALTEST=1
    fi
else
    echo "ERROR: The OS must be Red Hat or CentOS." | tee -a ${OUTPUT}
    ERROR=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
    echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1
LOCALTEST=0
echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking if the ansible dependency libselinux-python is installed" | tee -a ${OUTPUT}
get_rpm="rpm -qa"
if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
    se=$(${BECOME_CMD} "$get_rpm" | grep libselinux-python | wc -l)
else
    se=$(${BECOME_CMD} $get_rpm | grep libselinux-python | wc -l)
fi
if [[ $se == 0 ]]; then
    echo "ERROR: The libselinux-python package needs to be installed" | tee -a ${OUTPUT}
    ERROR=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
    echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0
echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Ensuring the IPv4 IP Forwarding is set to enabled" | tee -a ${OUTPUT}
ipv4_forward=$(cat /proc/sys/net/ipv4/ip_forward)
if [[ $ipv4_forward -eq 0 ]]; then
    conf_check=$(sed -n -e 's/^net.ipv4.ip_forward//p' /etc/sysctl.conf | tr -d = |awk '{$1=$1};1')
    if [[ $conf_check -eq 1 ]]; then
        echo "ERROR: The sysctl config file (/etc/sysctl.conf) has IPv4 IP forwarding set to enabled (net.ipv4.ip_forward = 1) but the file is not loaded. Please run the following command to load the file: 'sysctl -p'." | tee -a ${OUTPUT}
    else
        echo "ERROR: The sysctl config has IPv4 IP forwarding set to disabled (net.ipv4.ip_forward = 0). IPv4 forwarding needs to be enabled (net.ipv4.ip_forward = 1). To enable IPv4 forwarding we recommend use of the following commands: 'sysctl -w net.ipv4.ip_forward=1' or 'echo 1 > /proc/sys/net/ipv4/ip_forward'." | tee -a ${OUTPUT}
    fi
    ERROR=1
    LOCALTEST=1
fi
if [[ ${LOCALTEST} -eq 0 ]]; then
    echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1

LOCALTEST=0
echo "##########################################################################################" >> ${OUTPUT} 2>&1
echo "Checking if the .kube directory exists in /root ~/" | tee -a ${OUTPUT}
if [ $USER == "root" ] 
then
   echo /root >& homedir.txt
else
   echo /root >& homedir.txt
   echo $HOME >> homedir.txt
fi


while read line
do
   checkkube
   if [[ $? == 1 ]]; then
        ERROR=1
        LOCALTEST=1
   fi
done <homedir.txt

become_cmd "rm -f homedir.txt"
become_cmd "rm -f /$HOME/homedir.txt"

if [[ ${LOCALTEST} -eq 0 ]]; then
    echo "PASS" | tee -a ${OUTPUT}
fi
echo
echo "##########################################################################################" >> ${OUTPUT} 2>&1
osName=$(grep ^ID= /etc/os-release | cut -f2 -d'"' | cut -f2 -d'=')
if [[ $centos_repo -eq 0 && "$arch" == "x86_64" && "$osName" == "rhel" ]]; then
    LOCALTEST=0
    echo "##########################################################################################" >> ${OUTPUT} 2>&1
    echo "Checking if docker exists and is configured properly" | tee -a ${OUTPUT}
    which docker > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Docker is not installed on this node. Please install docker 1.12 or 1.13.1" | tee -a ${OUTPUT}
        ERROR=1
        LOCALTEST=1
    else 
        version=$(docker -v | grep -E '1.13.1|1.12' | wc -l)
        if [[ $version -eq 0 ]]; then
            echo "ERROR: The correct version of docker is not installed. Please uninstall and reinstall docker 1.13.1 or 1.12." | tee -a ${OUTPUT}
            ERROR=1
            LOCALTEST=1
        else
	    docker_info=""
	    if [[ "$(whoami)" != "root" && ${pb_run} -eq 1 ]]; then
                docker_info=$(${BECOME_CMD} "docker info 2> /dev/null")
            else
                docker_info=$(${BECOME_CMD} docker info 2> /dev/null)
            fi
	    storage_driver=$(echo "${docker_info}" | grep "Storage Driver" | sed 's/.*://' | tr -d '[:space:]')
	    docker_root=$(echo "${docker_info}" | grep "Docker Root Dir" | sed 's/.*://' | tr -d '[:space:]') 
            root_size=$(df -k -BG $docker_root | tail -1 | awk '{print $4}' | sed 's/G//')
            if [[ $root_size < 150 ]]; then
                echo "ERROR: Docker is not configured with 150GB or greater freespace in it's root directory." | tee -a ${OUTPUT}
                ERROR=1
                LOCALTEST=1
            fi
            if [[ "$storage_driver" != "overlay" && "$storage_driver" != "devicemapper" ]]; then
                echo "ERROR: The storage driver $storage_driver is not supported for docker configuration." | tee -a ${OUTPUT}
                ERROR=1
                LOCALTEST=1
            fi
            if [[ "$storage_driver" == "devicemapper" ]]; then
                loop_lvm=$(echo "${docker_info}" | grep "Data loop file" | wc -l)
                if [[ $loop_lvm > 0 ]]; then
                    echo "ERROR: The loop logical volume manager (loop-lvm) is not supported for docker configuration." | tee -a ${OUTPUT}
                    ERROR=1
                    LOCALTEST=1
                fi 
            fi
        fi
    fi
    if [[ ${LOCALTEST} -eq 0 ]]; then
        echo "PASS" | tee -a ${OUTPUT}
    fi
    echo
    echo "##########################################################################################" >> ${OUTPUT} 2>&1
    LOCALTEST=0
    echo "##########################################################################################" >> ${OUTPUT} 2>&1
    echo "Checking if packages and dependencies are available" | tee -a ${OUTPUT}
    # packages array contains package information in the form "package_name#parent_package#version_number#pre_installable" 
    # The values for version number can be empty if they are not being checked for
    # The values for pre_installable are "i" if the package can be installed before hand or "" if it cannot be installed before dsx install
    packages=("socat#kubelet##i" \
    "keepalived#none##" \
    "haproxy#none##" \
    "rsync#none##i" \
    "attr#glusterfs-server##i" \
    "gssproxy#glusterfs-server##i" \
    "keyutils#glusterfs-server##i" \
    "libbasicobjects#glusterfs-server##i" \
    "libcollection#glusterfs-server##i" \
    "libevent#glusterfs-server##i" \
    "libini_config#glusterfs-server##i" \
    "libnfsidmap#glusterfs-server##i" \
    "libpath_utils#glusterfs-server##i" \
    "libref_array#glusterfs-server##i" \
    "libtirpc#glusterfs-server##i" \
    "libverto-libevent#glusterfs-server##i" \
    "nfs-utils#glusterfs-server##i" \
    "psmisc#glusterfs-server##i" \
    "quota#glusterfs-server##i" \
    "quota-nls#glusterfs-server##i" \
    "rpcbind#glusterfs-server##i" \
    "tcp_wrappers#glusterfs-server##i")
    if [[ "${NODETYPE}" != "master" ]]; then
        packages=("${packages[@]:0:1}" "${packages[@]:3}")
    fi 
    for i in "${!packages[@]}"; do 
        check_package_availability "${packages[$i]}"
        return_value=$?
	if [[ $return_value -ne 0 ]]; then
            LOCALTEST=$return_value
        fi
        if [[ $ERROR -eq 0 ]]; then
            ERROR=$return_value
        fi
    done
    if [[ ${LOCALTEST} -eq 0 ]]; then
        echo "PASS" | tee -a ${OUTPUT}
    fi
    echo
    echo "##########################################################################################" >> ${OUTPUT} 2>&1
fi

#log result
if [[ ${ERROR} -eq 1 ]]; then
	echo "Finished with ERROR, please check ${OUTPUT}"
    exit 2
elif [[ ${WARNING} -eq 1 ]]; then
	echo "Finished with WARNING, please check ${OUTPUT}"
    exit 1
else
	echo "Finished successfully! This node meets the requirement" | tee -a ${OUTPUT}
    exit 0
fi
