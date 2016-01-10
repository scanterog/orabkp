#!/bin/bash
#
# Oracle data pump export script with remote copy and email notification
# Copyright 2015, 2016 Samuel Cantero <scanterog@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License,
# or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

if [ $# -lt 1 ]; then
	echo "Usage: $0 [CONFIGURATION_FILE]\n"
	echo "The CONFIGURATION_FILE contains all the information needed to perform locally an Oracle Data Pump Export "
        echo "and to send a copy to a remote location."
	exit 1
else
	if [ ! -f $1 ]; then
		echo "Configuration file not valid."
		exit 1
	fi
fi

# advisory locks
lock() {
	#create the lock file
	eval "exec $LOCKFD>$LOCKFILE"
	#acquire the lock
	flock -n $LOCKFD && return 0 || return 1
}

# Parse config file before sourcing.
load_config_file() {
	# Parsed config file to source (temp file).
	CONFIG_FILE="/tmp/orabkp.conf"

	# Avoid the execution of arbitrary code when config is sourced.
	# Delete lines with ; and & separators.
	# Delete empty lines and lines starting with '#'.

	egrep '^\w*=[^;&]*$' $1 > $CONFIG_FILE

	source $CONFIG_FILE
}

# $1: subject
# $2: message
# $3: attached file
send_email_notification() {
	if [ -n "$3" ]; then
		return `echo "$2" | mail -a "$3" -s "$1" "$MAIL_TO_ADDR"`
	else
		return `echo "$2" | mail -s "$1" "$MAIL_TO_ADDR"`
	fi
}

# In this implementation, Oracle Data Pump can be executed in FULL mode or in SCHEMA mode.
# By default, it executes the script in FULL mode.
# To execute this script in SCHEMA mode, the ORACLE_EXPDP_FULL variable value must be set in "No"
# and the value of the variable ORACLE_SCHEMA must be defined.
oracle_expdp() {
	outexpdp=1
	if [[ $ORACLE_EXPDP_FULL =~ ^[Nn][Oo]$ && ! -z $ORACLE_SCHEMA ]]; then
		MODE="SCHEMA"
		echo "[`date`]: Starting Oracle Data Pump Export in $MODE mode" >> $LOGFILE 			
		expdp $ORACLE_USER/$ORACLE_PWD@$ORACLE_SID SCHEMAS=$ORACLE_SCHEMA DIRECTORY=$ORACLE_DATAPUMP_DIR DUMPFILE=$ORA_DUMPFILE LOGFILE=$ORA_LOGFILE
		outexpdp=$?
		cat $BACKUP_DIR/$ORA_LOGFILE >> $LOGFILE
		echo "[`date`]: End of Oracle Data Pump Export started in $MODE mode" >> $LOGFILE 			
	else
		MODE="FULL"
		expdp $ORACLE_USER/$ORACLE_PWD@$ORACLE_SID FULL=yes DIRECTORY=$ORACLE_DATAPUMP_DIR DUMPFILE=$ORA_DUMPFILE LOGFILE=$ORA_LOGFILE
		outexpdp=$?
		cat $BACKUP_DIR/$ORA_LOGFILE >> $LOGFILE
		echo "[`date`]: End of Oracle Data Pump Export started in $MODE mode" >> $LOGFILE
	fi
	if [ $outexpdp -ne 0 ]; then
		echo "[`date`]: (ERROR) - Oracle Data Pump Export for \"$ORACLE_SID\" in $MODE mode has failed." >> $LOGFILE
		echo "[`date`]: (END) - Oracle Database Backup (orabkp) has terminated with an error." >> $LOGFILE
		subject="$(hostname): Error in Oracle Data Pump Export."
		msg="Please check the attached log file."
		send_email_notification "$subject" "$msg" "$LOGFILE"
		cat $LOGFILE >> $GLOBAL_LOGFILE
		clean
		exit 1	
	else
		echo "[`date`]: Oracle Data Pump Export for \"$ORACLE_SID\" has succesfully completed in $MODE mode." >> $LOGFILE
	fi
}

# Copy Oracle Dump and Log File to remote server 
remote_copy() {
	echo "[`date`]: Sending Oracle Dump and Log File to remote server." >> $LOGFILE
	if  [ $(whoami) == $SSH_USER  ]; then	
		scp "$BACKUP_DIR/$ORA_DUMPFILE $BACKUP_DIR/$ORA_LOGFILE '$SSH_USER@$SSH_SERVER:$SSH_RDIR'"
	else
		su - $SSH_USER -c "scp $BACKUP_DIR/$ORA_DUMPFILE $BACKUP_DIR/$ORA_LOGFILE '$SSH_USER@$SSH_SERVER:$SSH_RDIR'"
	fi
	if [ $? != 0 ] ; then
		echo "[`date`]: (ERROR) - The copy to the remote server $SSH_SERVER has failed." >> $LOGFILE
	else
		echo "[`date`]: The copy to the remote server $SSH_SERVER has successfully completed." >> $LOGFILE
	fi	
}

# Delete files older than RETENTION_DAYS days.
retention_policy() {
	echo "[`date`]: Removing files older than $RETENTION_DAYS days." >> $LOGFILE
	find $BACKUP_DIR -type f -mmin +$(($RETENTION_DAYS*1440)) -exec rm -f {} \; &>> $LOGFILE
}

# Clean temp files
clean() {
	echo "[`date`]: Removing $CONFIG_FILE temp file." >> $GLOBAL_LOGFILE
	rm -f "$CONFIG_FILE"
	echo "[`date`]: Removing $LOGFILE file of running execution. Keeping $GLOBAL_LOGFILE." >> $GLOBAL_LOGFILE
	rm -f "$LOGFILE"
}

#########################
# MAIN
#########################

LOGDIR="/var/log/orabkp"
LOGFILE="$LOGDIR/$(hostname)_orabkp.log"
GLOBAL_LOGFILE="$LOGDIR/orabkp.log"
LOCKDIR="/var/lock/orabkp"
LOCKFILE="$LOCKDIR/orabkp.lock"
LOCKFD=500

mkdir -p $LOGDIR
mkdir -p $LOCKDIR

lock
if [ $? -eq 1 ]; then
	msg="(ERROR) Only one instance of Oracle Database Backup (orabkp) can run at one time."
	echo "[`date`]: $msg" >> $LOGFILE
	echo $msg;
	exit 1
fi

echo "[`date`]: (BEGIN) - Oracle Database Backup (orabkp) starting with config file $1." >> $LOGFILE

load_config_file $1

export PATH=$PATH:$ORACLE_HOME/bin
export ORACLE_HOME=$ORACLE_HOME
export ORACLE_SID=$ORACLE_SID
ORA_DUMPFILE=$(date +%d-%b-%Y_%I-%M)-$BACKUP_NAME-$HOSTNAME-$BACKUP_ENV.dmp
ORA_LOGFILE=$(date +%d-%b-%Y_%I-%M)-$BACKUP_NAME-$HOSTNAME-$BACKUP_ENV.log

oracle_expdp

remote_copy

retention_policy 

echo "[`date`]: (END) - Oracle Database Backup (orabkp) has successfully terminated." >> $LOGFILE

if [[ $NOTIFY_ON_SUCCESS =~ ^[Yy][Ee][Ss]$ ]]; then
	subject="$(hostname): Oracle Database Backup has successfully terminated"
	msg="Please check the attached log file"
	send_email_notification "$subject" "$msg" "$LOGFILE"
fi

cat $LOGFILE >> $GLOBAL_LOGFILE
clean

exit 0	
