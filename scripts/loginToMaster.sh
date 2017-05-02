LOG_FILE="/tmp/kinetica-install.log"
# logs everything to the $LOG_FILE
log() {
  echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}"
}

echo $1 >> "${LOG_FILE}"