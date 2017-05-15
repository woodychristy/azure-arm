#!/bin/bash
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.

LOG_FILE="/tmp/kinetica-install.log"

# manually set EXECNAME because this file is called from another script and it $0 contains a 
# relevant path
EXECNAME="prepareDrives.sh"

# logs everything to the $LOG_FILE
log() {
  echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}"
}

# cluster name prefix which is hostname prefix
VM_NAME_PREFIX=$1
#total number of vms in the cluster
declare -i NUM_VMS=$2
HEAD_NODE_IP=$3

#Azure specific host postfix for number VMNAMExxxxx where x would be length 6 replaced with 000000 for the first node and 999999 for the 1 millionth
declare -i VMSS_NUM_LENGTH=6
#Anaible file list of hosts
INVENTORY_FILE_DIR="/etc/ansible/"
INVENTORY_FILE=$INVENTORY_FILE_DIR"hosts"


#Time out in seconds to wait for all machines to come up
declare -i HOST_CHECK_TIMEOUT=300

cat > inputs2.sh << 'END'



prepare_unmounted_volumes()
{

  # Each line contains an entry like /dev/<device name>
  MOUNTED_VOLUMES=$(df -h | grep -o -E "^/dev/[^[:space:]]*")

  # Each line contains an entry like <device name> (no /dev/ prefix)
  # (This awk script prints the last field of every line with line number
  # greater than 2.)
  ALL_PARTITIONS=$(awk 'FNR > 2 {print $NF}' /proc/partitions)
  COUNTER=0
  for part in $ALL_PARTITIONS; do
    # If this partition does not end with a number (likely a partition of a
    # mounted volume), is not equivalent to the alphabetic portion of another
    # partition with digits at the end (likely a volume that has already been
    # mounted), and is not contained in $MOUNTED_VOLUMES, and it is not $logDevice
    if [[ ! ${part} =~ [0-9]$ && ! ${ALL_PARTITIONS} =~ $part[0-9] && $MOUNTED_VOLUMES != *$part* ]];then
      echo ${part}
      prepare_disk "/data$COUNTER" "/dev/$part"
           COUNTER=$(($COUNTER+1))
    fi
  done
  wait # for all the background prepare_disk function calls to complete
}

# This function was lifted from the file prepare_all_disks.sh in the Whirr project
# It's safe to invoke this function in parallel with different arguments because
# the append operation is atomic when the size of the appended string is <1KB. See:
# http://www.notthewizard.com/2014/06/17/are-files-appends-really-atomic/
prepare_disk()
{
  mount=$1
  device=$2

  FS=ext4
  FS_OPTS="-E lazy_itable_init=1"

  which mkfs.$FS
  # Fall back to ext3
  if [[ $? -ne 0 ]]; then
    FS=ext3
    FS_OPTS=""
  fi

  # is device mounted?
  mount | grep -q "${device}"
  if [ $? == 0 ]; then
    echo "$device is mounted"
  else
    echo "Warning: ERASING CONTENTS OF $device"
    mkfs.$FS -F $FS_OPTS $device -m 0

    # If $FS is ext3 or ext4, then run tune2fs -i 0 -c 0 to disable fsck checks for data volumes

    if [ $FS = "ext3" -o $FS = "ext4" ]; then
    /sbin/tune2fs -i0 -c0 ${device}
    fi

    echo "Mounting $device on $mount"
    if [ ! -e "${mount}" ]; then
      mkdir "${mount}"
    fi
    # gather the UUID for the specific device

    blockid=$(/sbin/blkid|grep ${device}|awk '{print $2}'|awk -F\= '{print $2}'|sed -e"s/\"//g")

    #mount -o defaults,noatime "${device}" "${mount}"

    # Set up the blkid for device entry in /etc/fstab

    echo "UUID=${blockid} $mount $FS defaults,noatime,discard,barrier=0 0 0" >> /etc/fstab
    mount ${mount}

  fi
}

END

checkAllNodesUp(){
  #initialize
   numLiveHosts=0;
   START_TIME=$SECONDS
   declare -i ELAPSED_TIME=0
while [[ "$numLiveHosts" -lt "$NUM_VMS" && "$ELAPSED_TIME" -lt "$HOST_CHECK_TIMEOUT" ]];
 do
     #reset counter
     numLiveHosts=0;
   while read -r hostToCheck; 
    do
      if ping -c 2 -w 2 "$hostToCheck" &>/devnull
         then
         log "$hostToCheck" " is alive"
         let numLiveHosts=$numLiveHosts+1
      else
         log "$hostToCheck" " is not alive" 
      fi
   done<$INVENTORY_FILE
   log "Found "$numLiveHosts " live hosts. Expected ""$NUM_VMS" " live hosts"
    let ELAPSED_TIME=$((SECONDS - START_TIME))
   #Reset numLiveHosts for loop
 done 
#if we timed out log error and throw exception

if [[ $ELAPSED_TIME -gt $HOST_CHECK_TIMEOUT ]];
  then
     log "Timed out looking for live hosts. Waited " $ELAPSED_TIME " seconds"
     exit -1
  else
     log "All nodes are up!"
fi


}



getHostnames(){

    i=0
    while [ $i -lt "$NUM_VMS" ]; do
      machineName=$VM_NAME_PREFIX$(printf %0${VMSS_NUM_LENGTH}d $i)
      #create empty inventory file
      sudo echo "$machineName" >>$INVENTORY_FILE
      let i=$i+1
    done  

}

getFirstNode(){
   log "------- Determining if first node -------"
    firstNode=$VM_NAME_PREFIX$(printf %0${VMSS_NUM_LENGTH}d 0)
    host=$( hostname -s )
    log "FirstNode:""$firstNode"
    log " Hostname:""$host"

    if [[ "$host" == "$firstNode" ]]; then
       log "------- First node! Generating hostnames and running install -------"
       sudo mkdir -p $INVENTORY_FILE_DIR
       #delete inventory file if it exists
       [ -e $INVENTORY_FILE ]  && rm $INVENTORY_FILE
       getHostnames 
       checkAllNodesUp
    else
       log "------- Not the first node exiting -------"
    fi
}



log "------- prepareDrives.sh starting -------"

sudo bash -c "source ./inputs2.sh; prepare_unmounted_volumes"

log "------- prepareDrivess.sh succeeded -------"
 

log "$VM_NAME_PREFIX"
log "$NUM_VMS"
log "$HEAD_NODE_IP"
getFirstNode 




# always `exit 0` on success
exit 0

