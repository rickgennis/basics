#!/bin/bash
#
# {ansible managed - do not edit}
#
# 11/2016 RGE
#
# Create a large contiguous dump that can be used to seed a new slave.
# mysqldump provides the --master-data and --dump-slave options to automatically
# record the binary log position of the master and slaves, respectively.  But
# our goal is to perform a single dump that can be used to seed a slave to
# the current server (which is a slave) or the current server's master.  So
# we --somewhat confusingly-- use the --master-data flag to have mysql write
# binary log data for this server (even though we're a slave), and then insert
# this server's master binary log data ourselves.  The result is a dump file
# with two CHANGE MASTER lines at the top, either of which can be uncommented,
# depending on which machine you want to slave to.
#
# Because simply commenting a line in a 5G+ file can take some time, see the
# /usr/local/bin/recomment_dump_master script for a faster approach.
#


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Setup variables
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

BACKUP_DIR=/usr/local/backups/slave_seed
KEEP_DAYS=3
OUTFILE=slave_dump

# these vars are interpolated via perl so the @ sign needs to be escaped
REPLICA_USR='replica'
REPLICA_PW='D\@d0e5'

THIS_HOST=`/bin/hostname -s`
SCRIPT=`/usr/bin/basename $0`
LOG="/usr/bin/logger -t $SCRIPT"
TMP=/tmp/dump_errors.out.$$

SLAVESTATUS=`/usr/bin/mysql -e 'SHOW SLAVE STATUS\G'`
MASTER_HOST=`/bin/echo "${SLAVESTATUS}" | /bin/grep Master_Host | /usr/bin/awk '{print $2}'`
MASTER_LOG=`/bin/echo "${SLAVESTATUS}" | /bin/grep Relay_Master_Log_File | /usr/bin/awk '{print $2}'`
MASTER_POS=`/bin/echo "${SLAVESTATUS}" | /bin/grep Exec_Master_Log_Pos | /usr/bin/awk '{print $2}'`

if [ ! $MASTER_HOST ]
then
	/bin/echo "Cannot determine MySQL MASTER on ${THIS_HOST}" | /usr/bin/mail -s "$SCRIPT errors on $THIS_HOST" root@ds.npr.org
	$LOG "unable to determine MySQL MASTER (are we a configured slave?)"
	MASTER_HOST="unknown"
fi

MSG="\n#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#\n# This dump file can be used to slave to ${THIS_HOST} or ${MASTER_HOST}.  Uncomment\n# the desired line below.  Use the recomment_dump_master script to swap\n# the comment easily.\n#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#\n\n"

# Setup table exclusions
EXCLUDES="";
for DB in mysql information_schema; do
  	for I in `/usr/bin/mysql -e "SHOW TABLES FROM ${DB}"`; do
       		EXCLUDES="${EXCLUDES} --ignore_table=${DB}.${I} ";
    	done;
done;


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Ensure dump directories exist
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

/bin/mkdir -p $BACKUP_DIR
if [ ! -d $BACKUP_DIR ]
then
	$LOG "cannot access or create ${BACKUP_DIR}; aborting backup"
        /bin/echo -e "Cannot access or create ${BACKUP_DIR} on ${THIS_HOST}.\nAborting backup." | /usr/bin/mail -s "$SCRIPT errors on $THIS_HOST" root@ds.npr.org
	exit
fi


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Prune old backups
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "pruning dumps older than ${KEEP_DAYS} days from ${BACKUP_DIR}"

/usr/bin/find ${BACKUP_DIR} \
     -type f \
     -mtime +${KEEP_DAYS} \
     -name "${OUTFILE}*" \
     -delete


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Stop slaving
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "suspending slaving"
/usr/bin/mysqladmin stop-slave 2> $TMP
if [ -s $TMP ]
then
        ERR=`/bin/cat $TMP`
        ALLERRS="${ALLERRS}mysqladmin stop-slave error: $ERR\n"
        /bin/echo "mysqldump error: $ERR" | $LOG
        /bin/rm $TMP
fi


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Export all users/grants except root & debian users
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "exporting users and grants"

GRANTFILE=/tmp/grants.sql.$$
for USER in `/usr/bin/mysql -N -e "SELECT CONCAT('''', User, '''@''', Host, '''') FROM mysql.user" | /bin/egrep -v 'root|debian'`
do
            /usr/bin/mysql -N -e "SHOW GRANTS FOR ${USER}" 2> /dev/null | sed 's/$/;/'
done > $GRANTFILE

USERFILE=/tmp/users.sql.$$
/usr/bin/mysql -N -e "SELECT CONCAT('CREATE USER IF NOT EXISTS ''', User, '''@''', Host, ''' IDENTIFIED BY PASSWORD ''', Password, ''';') FROM mysql.user WHERE User != 'root'" > $USERFILE


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Perform the slave data dump 
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "starting slave dump for ${THIS_HOST} & ${MASTER_HOST}"

# the --master-data flag makes mysqldump add the current server's binary log data.  we then use perl
# to find that line, expand it to include the host name, and add a second line (commented out) that
# allows slaving to this server's master.
# NOTE:  the comment-looking line 4 below here is a comment being added to the dump file, not a comment
# in this script.  i.e. do not edit or indent it.
DUMPTMP=${BACKUP_DIR}/${OUTFILE}.sql.tmp.$$
/usr/bin/mysqldump --flush-logs --master-data --skip-lock-tables --apply-slave-statements --routines --all-databases ${EXCLUDES} 2> $TMP \
        | /usr/bin/perl -pe "s/CHANGE MASTER TO MASTER_LOG_FILE(.*)$/${MSG}  CHANGE MASTER TO MASTER_HOST='${THIS_HOST}', MASTER_PORT=3306, MASTER_USER='${REPLICA_USR}', MASTER_PASSWORD='${REPLICA_PW}', MASTER_LOG_FILE\$1\n\
# CHANGE MASTER TO MASTER_HOST='${MASTER_HOST}', MASTER_PORT=3306, MASTER_USER='${REPLICA_USR}', MASTER_PASSWORD='${REPLICA_PW}', MASTER_LOG_FILE='${MASTER_LOG}', MASTER_LOG_POS=${MASTER_POS};/" \
    > ${DUMPTMP}

if [ -s $TMP ]
then
	ERR=`/bin/cat $TMP`
        ALLERRS="${ALLERRS}mysqldump error: $ERR\n"
        /bin/echo "mysqldump master-data error: $ERR" | $LOG
        /bin/rm $TMP
fi

$LOG "completed slave dump"


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Restart slaving
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "restarting slaving"
/usr/bin/mysqladmin start-slave 2> $TMP

if [ -s $TMP ]
then
        ERR=`/bin/cat $TMP`
        ALLERRS="${ALLERRS}mysqladmin start-slave error: $ERR\n"
        /bin/echo "mysqldump error: $ERR" | $LOG
fi
/bin/rm $TMP


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Add details for the top of the dump file
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

HEADERFILE=/tmp/header.$$
USER_LINES=`/usr/bin/wc -l ${USERFILE} | /usr/bin/awk '{ print $1}'`
GRANT_LINES=`/usr/bin/wc -l ${GRANTFILE} | /usr/bin/awk '{ print $1}'`
TOTAL_LINES=$((${USER_LINES} + ${GRANT_LINES}))
echo -e "# 'tail -${GRANT_LINES}' for grants\n# 'tail -${TOTAL_LINES}' for users & grants\n\nSET @@global.read_only := 1;\n\n" > ${HEADERFILE}


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Concat & compress dump
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

FINAL_FILE=${BACKUP_DIR}/${OUTFILE}_${THIS_HOST}-`/bin/date +%Fat%H_%M`.sql.gz
$LOG "compressing dump to ${FINAL_FILE}"
/bin/cat ${HEADERFILE} ${DUMPTMP} ${USERFILE} ${GRANTFILE} | /bin/gzip -9 > ${FINAL_FILE}
/bin/rm ${HEADERFILE} ${DUMPTMP} ${USERFILE} ${GRANTFILE} 
$LOG "completed compressing dump"


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Email out errors, if any
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

if [ "$ALLERRS" ]
then
        /bin/echo -e "$ALLERRS" | /usr/bin/mail -s "$SCRIPT errors on $THIS_HOST" ops@ds.npr.org
fi
