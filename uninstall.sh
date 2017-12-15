#!/bin/bash -e

SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
AUTHORIZED_KEYS_COMMAND_FILE="/opt/authorized_keys_command.sh"
IMPORT_USERS_SCRIPT_FILE="/opt/import_users.sh"
MAIN_CONFIG_FILE="/etc/aws-ec2-ssh.conf"
CRON_FILE="/etc/cron.d/import_users"
LOCAL_MARKER_GROUP="iam-synced-users"
USERDEL_PROGRAM="/usr/sbin/userdel"

show_help() {
cat << EOF
Usage: ${0##*/} [-hv] [-p PROGRAM]
Uninstall import_users.sh and authorized_key_commands.

    -h                 display this help and exit
    -v                 verbose mode.

    -p program         Specify your userdel program to use.
                       Defaults to '/usr/sbin/userdel'


EOF
}

function log() {
    /usr/bin/logger -i -p auth.info -t aws-ec2-ssh "$@"
}

# Get previously synced users
function get_local_users() {
    /usr/bin/getent group ${LOCAL_MARKER_GROUP} \
        | cut -d : -f4- \
        | sed "s/,/ /g"
}

function delete_local_user() {
    # First, make sure no new sessions can be started
    /usr/sbin/usermod -L -s /sbin/nologin "${1}" || true
    # ask nicely and give them some time to shutdown
    /usr/bin/pkill -15 -u "${1}" || true
    sleep 5
    # Dont want to close nicely? DIE!
    /usr/bin/pkill -9 -u "${1}" || true
    sleep 1
    # Remove account now that all processes for the user are gone
    $USERDEL_PROGRAM -f -r "${1}"
    log "Deleted user ${1}"
}



while getopts :hva:i:l:s: opt
do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        v)
            set -x
            ;;
        p)
            USERDEL_PROGRAM="$OPTARG"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            show_help
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            show_help
            exit 1
    esac
done

#TODO:
#Remove /etc/cron.d/import_users
rm -f $CRON_FILE

#Remove /opt/authorized_key_command.sh
rm -f $AUTHORIZED_KEYS_COMMAND_FILE

#Remove /opt/import_users.sh
rm -f $IMPORT_USERS_SCRIPT_FILE

#Remove Main Config file
rm -f $MAIN_CONFIG_FILE

#Remove AuthorizedKeysCommand directive from /etc/ssh/sshd_config
if grep -q "AuthorizedKeysCommand ${AUTHORIZED_KEYS_COMMAND_FILE}" $SSHD_CONFIG_FILE; then
    sed -i "s:AuthorizedKeysCommand ${AUTHORIZED_KEYS_COMMAND_FILE}:#AuthorizedKeysCommand none:g" $SSHD_CONFIG_FILE
fi

if grep -q 'AuthorizedKeysCommandUser nobody' $SSHD_CONFIG_FILE; then
    sed -i "s:AuthorizedKeysCommandUser nobody:#AuthorizedKeysCommandUser nobody:g" $SSHD_CONFIG_FILE
fi

#Remove IAM users
local_users=$(get_local_users | sort | uniq)
for user in ${local_users}; do
    delete_local_user "${user}"
done

# Disable SELinux boolean
# Capture the return code and use that to determine if we have the command available
retval=0
which getenforce > /dev/null 2>&1 || retval=$?

if [[ "$retval" -eq "0" ]]; then
  retval=0
  selinuxenabled || retval=$?
  if [[ "$retval" -eq "0" ]]; then
    setsebool -P nis_enabled off
  fi
fi

# Restart sshd
# Capture the return code and use that to determine if we have the command available
retval=0
which systemctl > /dev/null 2>&1 || retval=$?

if [[ "$retval" -eq "0" ]]; then
  if [[ (`systemctl is-system-running` =~ running) || (`systemctl is-system-running` =~ degraded) ]]; then
    if [ -f "/usr/lib/systemd/system/sshd.service" ] || [ -f "/lib/systemd/system/sshd.service" ]; then
      systemctl restart sshd.service
    else
      systemctl restart ssh.service
    fi
  fi
elif [[ `/sbin/init --version` =~ upstart ]]; then
    if [ -f "/etc/init.d/sshd" ]; then
      service sshd restart
    else
      service ssh restart
    fi
else
  if [ -f "/etc/init.d/sshd" ]; then
    /etc/init.d/sshd restart
  else
    /etc/init.d/ssh restart
  fi
fi
