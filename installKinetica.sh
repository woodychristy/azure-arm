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
LICENSE_KEY=${10}
CLOUD=${11}


declare -i NUM_GPU=0


#Ansible file list of hosts
INVENTORY_FILE_DIR="/etc/ansible/"
INVENTORY_FILE=$INVENTORY_FILE_DIR"hosts"

MAIN_YML_FILE="main.yml"

GPUDB_CONF_FILE="/opt/gpudb/core/etc/gpudb.conf"
GPUDB_HOSTS_FILE="/opt/gpudb/core/etc/hostsfile"


ODBC_INI="/opt/gpudb/connectors/odbcserver/client/etc/odbc.ini"
GISFED_ODBC_INI="/opt/gpudb/connectors/odbcserver/bin/GISFederal.GPUdbODBC.ini"
HTTPD_NO_AUTH_CONF="/opt/gpudb/httpd/conf/noauth.conf"
HTTPD_DATA_CONF="/opt/gpudb/httpd/conf/data.conf"
GADMIN_PROPERTIES="/opt/gpudb/tomcat/webapps/gadmin/WEB-INF/classes/gaia.properties"
REVEAL_CONFIG_PY="/opt/gpudb/connectors/caravel/etc/config.py"
REVEAL_DEFAULT_JSON="/opt/gpudb/connectors/caravel/etc/default.json"

#Certificates
SSL_BASE_DIR="/opt/gpudb/ssl"
SSL_CERT_FILE=$SSL_BASE_DIR"/cert.pem"
SSL_KEY_FILE=$SSL_BASE_DIR"/key.pem"

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
    
    #Resize the file system to be the same as underlying disk
    
    echo "Resizing filesystem to take entire $device"
    resize2fs ${device}

  fi
}

END

#Setup ssh user to do passworld less ssh script

cat > /tmp/sshUserSetup.sh << 'END'

#!/bin/bash
LOG_FILE="/tmp/kinetica-ssh-setup.log"

# manually set EXECNAME because this file is called from another script and it $0 contains a 
# relevant path
EXECNAME="sshUserSetup.sh"

# logs everything to the $LOG_FILE
log() {
  echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}"
}




export SSHPASS="$1"
export SUDO_CMD="echo ${SSHPASS}|sudo -S"

INVENTORY_FILE_DIR="/etc/ansible/"
INVENTORY_FILE=$INVENTORY_FILE_DIR"hosts"

#Remove existing keys
[ -e ~/.ssh/id_rsa ] && rm ~/.ssh/id_rsa*
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

SSH_USER_HOME=$(eval echo ~)
SSH_KEY_DIR=$SSH_USER_HOME/.ssh
PUB_KEYFILE=$SSH_KEY_DIR/id_rsa.pub
AUTH_KEYFILE=$SSH_KEY_DIR/authorized_keys
KNOWN_HOSTS_FILE=$SSH_KEY_DIR/known_hosts

declare -a DST_IPs


q=0
    while read h; do
     DST_IPs[$q]=$h
     let q=$q+1
done< $INVENTORY_FILE


if [ ! -f "$AUTH_KEYFILE" ]; then
    log "Creating : $AUTH_KEYFILE"
    cat "$PUB_KEYFILE" >> "$AUTH_KEYFILE"
elif ! grep -F "$(cat "$PUB_KEYFILE")" "$AUTH_KEYFILE" > /dev/null ; then
    log "Updating : $AUTH_KEYFILE"
    cat "$PUB_KEYFILE" >> "$AUTH_KEYFILE"
fi


chmod 644 "$AUTH_KEYFILE"

touch "$KNOWN_HOSTS_FILE"
chmod 644 "$KNOWN_HOSTS_FILE"

SSHPASS_CMD="sshpass -e"


for i in "${DST_IPs[@]}"; do
   #get keys by just logging in

    $SSHPASS_CMD ssh -tt -o StrictHostKeyChecking=no "$i" hostname
    #Make directory if it doesn't exist
   

    $SSHPASS_CMD ssh -tt "$i" mkdir "$SSH_KEY_DIR"
    
    log "---------------------------------------------------------"
    log "Copying ssh keys to $i"
    log "---------------------------------------------------------"

    $SSHPASS_CMD  rsync -avr "$SSH_KEY_DIR/." "$i:$SSH_KEY_DIR/."


    # Make these hosts known to us, gets all public keys for all users.
    KNOWN_HOST_STR=$(ssh-keyscan -t rsa "$i")

    if ! grep -F "$KNOWN_HOST_STR" "$KNOWN_HOSTS_FILE" > /dev/null; then
        echo "$KNOWN_HOST_STR" >> "$SSH_KEY_DIR/known_hosts"
    fi

    
done

# After assembling the list of 'known_hosts', redistribute the list to everybody.
for i in "${DST_IPs[@]}"; do
    $SSHPASS_CMD  rsync -ar "$SSH_KEY_DIR/." "$i:$SSH_KEY_DIR/."
done


#Now we need to do this for GPUDB user



GPUDB_USER_HOME=$(eval echo ~gpudb)
GPUDB_KEY_DIR=$GPUDB_USER_HOME/.ssh
GPUDB_TMP_SSH_FOLDER="/tmp/gpudbssh"
GPUDB_TMP_AUTH_KEYFILE=$GPUDB_TMP_SSH_FOLDER/authorized_keys
GPUB_TMP_KEYFILE=$GPUDB_TMP_SSH_FOLDER/id_rsa.pub



mkdir -p $GPUDB_TMP_SSH_FOLDER

ssh-keygen -t rsa -N "" -f $GPUDB_TMP_SSH_FOLDER/id_rsa
#Make a copy of good known hosts file 
cp "$KNOWN_HOSTS_FILE" "$GPUDB_TMP_SSH_FOLDER/."
#Need to replace user with gpudb
sed -i "s/${USER}/gpudb/g" $GPUB_TMP_KEYFILE
cat $GPUB_TMP_KEYFILE > $GPUDB_TMP_AUTH_KEYFILE

for i in "${DST_IPs[@]}"; do

  ssh -tt "$i"  mkdir -p $GPUDB_TMP_SSH_FOLDER
  ssh -tt "$i"  eval ${SUDO_CMD} chmod 755 $GPUDB_TMP_SSH_FOLDER
#Remove existing keys
  ssh -tt "$i"  [ -e "$GPUDB_USER_HOME/.ssh/id_rsa" ] && rm "$GPUDB_KEY_DIR/id_rsa*"


  #copy

  rsync -avr "$GPUDB_TMP_SSH_FOLDER/." "$i:$GPUDB_TMP_SSH_FOLDER/."


  #copy
  ssh -tt "$i" eval ${SUDO_CMD} cp $GPUDB_TMP_SSH_FOLDER/* "$GPUDB_KEY_DIR/."
   #permissions

  ssh -tt "$i" eval ${SUDO_CMD} chown -R gpudb:gpudb "$GPUDB_KEY_DIR/."
  ssh -tt "$i" eval ${SUDO_CMD} chmod -R 644 "$GPUDB_KEY_DIR/"
  ssh -tt "$i" eval ${SUDO_CMD} chmod  744 "$GPUDB_KEY_DIR"
  ssh -tt "$i" eval ${SUDO_CMD} chmod 600 "$GPUDB_KEY_DIR/id_rsa"
  #wait till everything is all done
  wait
  
done

#cleanup
for i in "${DST_IPs[@]}"; do
  ssh -tt "$i" eval ${SUDO_CMD} rm -rf $GPUDB_TMP_SSH_FOLDER
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
  P2.XLARGE) NUM_GPU=1
  ;;
  P2.8XLARGE) NUM_GPU=8
  ;;
  P2.16XLARGE) NUM_GPU=16
  ;;

  esac

}

setupPersist(){
  eval $SUDO_CMD mkdir -p /data0/gpudb/persist
  eval $SUDO_CMD chown -R gpudb:gpudb /data0/gpudb

}



setupGPUDBConf(){

  if [ "$HEAD_NODE_IP" == "USE_FIRST_NODE" ]
  then

    sed -i -E "s/head_ip_address =.*/head_ip_address = ${FIRST_NODE}/g" $GPUDB_CONF_FILE
  else
    HEAD_NODE_IP=host ${HEAD_NODE_IP} | awk '/has address/ { print $4 }'
    sed -i -E "s/head_ip_address =.*/head_ip_address = ${HEAD_NODE_IP}/g" $GPUDB_CONF_FILE
  fi
  sed -i -E "s/enable_caravel =.*/enable_caravel = ${ENABLE_CARAVEL}/g" $GPUDB_CONF_FILE
  sed -i -E "s/enable_odbc_connector =.*/enable_odbc_connector = ${ENABLE_ODBC}/g" $GPUDB_CONF_FILE
  sed -i -E "s:persist_directory = .*:persist_directory = /data0/gpudb/persist:g" $GPUDB_CONF_FILE
  sed -i -E "s:license_key =.*:license_key = ${LICENSE_KEY}:g" $GPUDB_CONF_FILE
  


  declare -a HOST_NAMES

 
    i=0
     while read h; do
     HOST_NAMES[$i]=$h
     let i=$i+1
    done< $INVENTORY_FILE


#Setup ranks

#Setup rank 0
sed -i -E "s/rank0.numa_node = .*/rank0.numa_node = 0/g" $GPUDB_CONF_FILE

#Remove the other settings
sed -i -E "s/rank.*.taskcalc_gpu =.*//g" $GPUDB_CONF_FILE


#Remove empty lines at end of file

sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/ba' $GPUDB_CONF_FILE

#Setup the rest
declare -i RANKNUM=1
declare -i NODECOUNTER=0

for i in "${HOST_NAMES[@]}"; do

  #Set rank0 IP to internal hostname

  if [ $NODECOUNTER -eq 0 ]
  then
   sed -i -E "s/rank0_ip_address =.*/rank0_ip_address = $i/g" $GPUDB_CONF_FILE
  fi

  case "$INSTANCE_TYPE" in
    STANDARD_NC6)
     echo "rank$RANKNUM.taskcalc_gpu = 0" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
      ;;
    STANDARD_NC12) 
     echo "rank$RANKNUM.taskcalc_gpu = 0" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 1" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
      ;;
    STANDARD_NC24)
     echo "rank$RANKNUM.taskcalc_gpu = 0" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 1" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 2" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 3" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
      ;;
     P2.XLARGE)
      echo "rank$RANKNUM.taskcalc_gpu = 0" >>$GPUDB_CONF_FILE
      RANKNUM=$RANKNUM+1
     ;;
     P2.8XLARGE)
     echo "rank$RANKNUM.taskcalc_gpu = 0" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 1" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 2" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 3" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 4" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 5" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 6" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 7" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     ;;
     P2.16XLARGE)
     echo "rank$RANKNUM.taskcalc_gpu = 0" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 1" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 2" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 3" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 4" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 5" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 6" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 7" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 8" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 9" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 10" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 11" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 12" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 13" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 14" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     echo "rank$RANKNUM.taskcalc_gpu = 15" >>$GPUDB_CONF_FILE
     RANKNUM=$RANKNUM+1
     ;;

  esac

  #skip node 1 else add to hosts file


   if [ $NODECOUNTER -gt 0 ]
   then
      echo "$i slots=$NUM_GPU max_slots=$NUM_GPU" >>"$GPUDB_HOSTS_FILE"
   else
      let FIRST_HOST_GPU=$NUM_GPU+1
      echo "$i slots=$FIRST_HOST_GPU max_slots=$FIRST_HOST_GPU" >"$GPUDB_HOSTS_FILE"
   fi
   
  
  NODECOUNTER=$NODECOUNTER+1

done
sed -i -E "s/number_of_ranks =.*/number_of_ranks = $RANKNUM/g" $GPUDB_CONF_FILE

}


getHostnames(){
case "$CLOUD" in
    AWS)
      eval ${SUDO_CMD} echo "$FIRST_NODE" >>$INVENTORY_FILE
    ;;
    AZURE)
    i=0
    while [ $i -lt "$NUM_VMS" ]; do
      MACHINE_NAME=$VM_NAME_PREFIX$(printf %0${VMSS_NUM_LENGTH}d $i)
      #Populate inventory file
      eval ${SUDO_CMD} echo "$MACHINE_NAME" >>$INVENTORY_FILE
      let i=$i+1
    done
    ;;
esac


}



getFirstNode(){
   log "------- Determining if first node -------"
    host=$( hostname -s )
    log "FIRST_NODE:""$FIRST_NODE"
    log " Hostname:""$host"

    if [[ "$host" == "$FIRST_NODE" ]]
     then
       log "------- First node! Generating hostnames and running install -------"
       eval ${SUDO_CMD} mkdir -p $INVENTORY_FILE_DIR
       #delete inventory file if it exists
       [ -e $INVENTORY_FILE ]  && rm $INVENTORY_FILE
       getHostnames 
       checkAllNodesUp
       setNumGPU
       log "Found the following number of GPUS: $NUM_GPU"
       if [[ $NUM_VMS -gt 1 ]]
       then
         log "Sleeping 30 seconds to ensure networks are up"
         sleep 30
       fi


       setupGPUDBConf

    else
       log "------- Not the first node exiting -------"
    fi
}


azure(){
log "------- prepareDrives.sh starting -------"
#Debugging need to set this world writeable
chmod 777 $LOG_FILE
#set perms
export SUDO_CMD="echo ${SSH_PASSWORD}|sudo -S "


eval ${SUDO_CMD} chmod +x ./inputs2.sh
#password is in cache. 
sudo bash -c "source ./inputs2.sh; prepare_unmounted_volumes"

log "------- prepareDrivess.sh succeeded -------"

setupPersist
getFirstNode

}

awsSingleNode(){
log "------- prepareDrives.sh starting -------"
#Debugging need to set this world writeable
chmod 777 $LOG_FILE
log "AWS Installer"
export SUDO_CMD="sudo "

#set perms
eval ${SUDO_CMD} chmod +x ./inputs2.sh
sudo bash -c "source ./inputs2.sh; prepare_unmounted_volumes"

log "------- prepareDrivess.sh succeeded -------"
setupPersist
#resize EBS persist volume
 eval $SUD_CMD resize2fs /dev/xvdb


}

FIRST_NODE=""
case "$CLOUD" in
    AWS)
    declare -i VMSS_NUM_LENGTH=0
    FIRST_NODE=$( hostname -s )
    awsSingleNode
    ;;
    AZURE)
    #Azure specific host postfix for number VMNAMExxxxx where x would be length 6 replaced with 000000 for the first node and 999999 for the 1 millionth
    declare -i VMSS_NUM_LENGTH=6
    FIRST_NODE=$VM_NAME_PREFIX$(printf %0${VMSS_NUM_LENGTH}d 0)
    azure
    ;;
esac


# always `exit 0` on success
exit 0

