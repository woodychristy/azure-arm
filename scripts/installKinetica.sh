#!/bin/bash

LOG_FILE="/tmp/kinetica-install.log"

#Debugging need to set this world writeable

# manually set EXECNAME because this file is called from another script and it $0 contains a 
# relevant path
EXECNAME="installKinetica.sh"

# logs everything to the $LOG_FILE
log() {
  echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}"
}

# cluster name prefix which is hostname prefix
VM_NAME_PREFIX=$1
#total number of vms in the cluster
declare -i NUM_VMS=$2

#Setup variables passed in
HEAD_NODE_IP=$3
ENABLE_ODBC=$4
ENABLE_CARAVEL=$5
ENABLE_KIBANA=$6
SSH_USER=$7
SSH_PASSWORD=$8
#Upper Case Instance type for lookup
declare -u INSTANCE_TYPE=$9
declare -i NUM_GPU=0

#Azure specific host postfix for number VMNAMExxxxx where x would be length 6 replaced with 000000 for the first node and 999999 for the 1 millionth
declare -i VMSS_NUM_LENGTH=6
#Anaible file list of hosts
INVENTORY_FILE_DIR="/etc/ansible/"
INVENTORY_FILE=$INVENTORY_FILE_DIR"hosts"

MAIN_YML_FILE="main.yml"

#Time out in seconds to wait for all machines to come up
declare -i HOST_CHECK_TIMEOUT=300

#Formatting drives script

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

#Setup ssh user to do passworld less ssh script

cat > /tmp/sshUserSetup.sh << 'END'


LOG_FILE="/tmp/kinetica-ssh-setup.log"

# manually set EXECNAME because this file is called from another script and it $0 contains a 
# relevant path
EXECNAME="sshUserSetup.sh"

# logs everything to the $LOG_FILE
log() {
  echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}"
}




export SSHPASS="$1"
VM_NAME_PREFIX=$2
VMSS_NUM_LENGTH=6
declare -i NUM_VMS=$3



#Remove existing keys
[ -e ~/.ssh/id_rsa ] && rm ~/.ssh/id_rsa*
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

SSH_USER_HOME=$(eval echo ~)
SSH_KEY_DIR=$SSH_USER_HOME/.ssh
PUB_KEYFILE=$SSH_KEY_DIR/id_rsa.pub
AUTH_KEYFILE=$SSH_KEY_DIR/authorized_keys
KNOWN_HOSTS_FILE=$SSH_KEY_DIR/known_hosts

declare -a DST_IPs

    i=0
    while [ $i -lt "$NUM_VMS" ]; do
      DST_IPs[$i]=$VM_NAME_PREFIX$(printf %0${VMSS_NUM_LENGTH}d $i)
      let i=$i+1
    done


if [ ! -f $AUTH_KEYFILE ]; then
    log "Creating : $AUTH_KEYFILE"
    cat $PUB_KEYFILE >> $AUTH_KEYFILE
elif ! grep -F "$(cat $PUB_KEYFILE)" $AUTH_KEYFILE > /dev/null ; then
    log "Updating : $AUTH_KEYFILE"
    cat $PUB_KEYFILE >> $AUTH_KEYFILE
fi

#sudo chown $SSH_USER:$SSH_USER $AUTH_KEYFILE
chmod 644 $AUTH_KEYFILE

touch $KNOWN_HOSTS_FILE
#sudo chown $SSH_USER:$SSH_USER $KNOWN_HOSTS_FILE
chmod 644 $KNOWN_HOSTS_FILE

# Attempt to do passwordless ssh if they have 'sshpass' installed,cat
# else they will hopefully have passwordless ssh already configured
# or they will have to type the password over and over.

SSHPASS_CMD="sshpass -e"


for i in ${DST_IPs[@]}; do
   #get keys by just logging in

    $SSHPASS_CMD ssh -o StrictHostKeyChecking=no $i hostname
   
    log "---------------------------------------------------------"
    log "Copying ssh keys to $i"
    log "---------------------------------------------------------"

    $SSHPASS_CMD  rsync -avr "$SSH_KEY_DIR/." "$i:$SSH_KEY_DIR/."


    # Make these hosts known to us, gets all public keys for all users.
    KNOWN_HOST_STR=$(ssh-keyscan -t rsa $i)

    if ! grep -F "$KNOWN_HOST_STR" $KNOWN_HOSTS_FILE > /dev/null; then
        echo $KNOWN_HOST_STR >> $SSH_KEY_DIR/known_hosts
    fi

    
done

# After assembling the list of 'known_hosts', redistribute the list to everybody.
for i in $DST_IPs; do
    $SSHPASS_CMD  rsync -ar "$SSH_KEY_DIR/." "$i:$SSH_KEY_DIR/."
done


#Now we need to do this for GPUDB user



GPUDB_USER_HOME=$(eval echo ~gpudb)
GPUDB_KEY_DIR=$GPUDB_USER_HOME/.ssh
GPUDB_TMP_SSH_FOLDER="/tmp/gpudbssh"
GPUDB_TMP_AUTH_KEYFILE=$GPUDB_TMP_SSH_FOLDER/authorized_keys
GPUB_TMP_KEYFILE=$GPUDB_TMP_SSH_FOLDER/id_rsa.pub

#Remove existing keys
[ -e $GPUDB_USER_HOME/.ssh/id_rsa ] && rm $GPUDB_KEY_DIR/id_rsa*

mkdir -p $GPUDB_TMP_SSH_FOLDER

ssh-keygen -t rsa -N "" -f $GPUDB_TMP_SSH_FOLDER/id_rsa
#Make a copy of good known hosts file 
cp $KNOWN_HOSTS_FILE $GPUDB_TMP_SSH_FOLDER/.
cat $GPUB_TMP_KEYFILE > $GPUDB_TMP_AUTH_KEYFILE

for i in ${DST_IPs[@]}; do

  ssh $i  mkdir -p $GPUDB_TMP_SSH_FOLDER
  ssh $i  chmod 755 $GPUDB_TMP_SSH_FOLDER 
  #copy

  rsync -avr "$GPUDB_TMP_SSH_FOLDER/." "$i:$GPUDB_TMP_SSH_FOLDER/."

  #permissions
  ssh $i sudo chmod -R 644 $GPUDB_TMP_SSH_FOLDER/
  ssh $i sudo chmod 600 $GPUDB_TMP_SSH_FOLDER/id_rsa
  ssh $i sudo cp -r $GPUDB_TMP_SSH_FOLDER/. $GPUDB_KEY_DIR/.
  ssh $i sudo chown -R gpudb:gpudb $GPUDB_KEY_DIR/.
  ssh $i sudo rm -rf $GPUDB_TMP_SSH_FOLDER
done

log "All done."




END

chmod 755 /tmp/sshUserSetup.sh 


checkAllNodesUp(){
  #initialize
   NUM_LIVE_HOSTS=0;
   START_TIME=$SECONDS
   declare -i ELAPSED_TIME=0
while [[ "$NUM_LIVE_HOSTS" -lt "$NUM_VMS" && "$ELAPSED_TIME" -lt "$HOST_CHECK_TIMEOUT" ]];
 do
     #reset counter
     NUM_LIVE_HOSTS=0;
   while read -r HOST_TO_CHECK; 
    do
      if ping -c 2 -w 2 "$HOST_TO_CHECK" &>/devnull
         then
         log "$HOST_TO_CHECK" " is alive"
         let NUM_LIVE_HOSTS=$NUM_LIVE_HOSTS+1
      else
         log "$HOST_TO_CHECK" " is not alive" 
      fi
   done<$INVENTORY_FILE
   log "Found "$NUM_LIVE_HOSTS " live hosts. Expected ""$NUM_VMS" " live hosts"
    let ELAPSED_TIME=$((SECONDS - START_TIME))
   #Reset NUM_LIVE_HOSTS for loop
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

setNumGPU(){
  #From instance type set num GPU
  case "$INSTANCE_TYPE" in
  STANDARD_NC6) NUM_GPU=1
    ;;
  STANDARD_NC12) NUM_GPU=2
    ;;
  STANDARD_NC24) NUM_GPU=4
  ;;
  esac

}


setupMainYml(){

  sed -i "s/kineticadb_head_ip_address: \"\"/kineticadb_head_ip_address: \"${HEAD_NODE_IP}\"/g" $MAIN_YML_FILE
  sed -i "s/kineticadb_enable_caravel: \"\"/kineticadb_enable_caravel: \"${ENABLE_CARAVEL}\"/g" $MAIN_YML_FILE
  sed -i "s/kineticadb_enable_odbc_connector: \"\"/kineticadb_enable_odbc_connector: \"${ENABLE_ODBC}\"/g" $MAIN_YML_FILE
  sed -i "s/kineticadb_enable_kibana_connector: \"\"/kineticadb_enable_kibana_connector: \"${ENABLE_KIBANA}\"/g" $MAIN_YML_FILE
  sed -i "s/kineticadb_enable_kibana_connector: \"\"/kineticadb_enable_kibana_connector: \"${ENABLE_KIBANA}\"/g" $MAIN_YML_FILE

}

launchAnsible(){

#enter cmd line to launch ansible here
  log "Launching ansible"
}

getHostnames(){
    i=0
    while [ $i -lt "$NUM_VMS" ]; do
      MACHINE_NAME=$VM_NAME_PREFIX$(printf %0${VMSS_NUM_LENGTH}d $i)
      #Populate inventory file
      sudo echo "$MACHINE_NAME" >>$INVENTORY_FILE
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
       setNumGPU
       setupMainYml
       log "Found the following number of GPUS: $NUM_GPU"
       log "Sleeping 30 seconds to ensure networks are up"
       sleep 30
       log "------- sshUserSetup.sh starting -------"
       touch /tmp/kinetica-ssh-setup.log
       chmod 777 /tmp/kinetica-ssh-setup.log
       sudo su $SSH_USER bash -c "source /tmp/sshUserSetup.sh $SSH_PASSWORD $VM_NAME_PREFIX $NUM_VMS 2>&1>>/tmp/kinetica-ssh-setup.log" 2>&1>>$LOG_FILE
       log "------- sshUserSetup.sh finished -------"
       
       launchAnsible
    else
       log "------- Not the first node exiting -------"
    fi
}



log "------- prepareDrives.sh starting -------"
#Debugging need to set this world writeable
chmod 777 $LOG_FILE

sudo bash -c "source ./inputs2.sh; prepare_unmounted_volumes"

log "------- prepareDrivess.sh succeeded -------"
 


getFirstNode 




# always `exit 0` on success
exit 0

