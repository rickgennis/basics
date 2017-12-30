#!/bin/bash
#
# {ansible managed - do not edit}
#
# MySQL dump script, must be run as user 'mysql'
#
# Delete mysql dumpfiles older than {4} days.
# Dump all databases individually, then compress them.

HOST=`hostname -s`
SCRIPT=`/usr/bin/basename $0`
LOG="/usr/bin/logger -t $SCRIPT"
DATESTAMP=`/bin/date +"%m%d"`
TMP=/tmp/dump_errors.out

BACKUP_DIR=/usr/local/backups/individual_dbs
KEEP_DAYS=4

#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

/bin/mkdir -p $BACKUP_DIR
if [ ! -d $BACKUP_DIR ]
then
	$LOG "cannot access or create ${BACKUP_DIR}; aborting backup"
	echo "Cannot access or create ${BACKUP_DIR} on ${HOST}.\nAborting backup." | /usr/bin/mail -s "$SCRIPT errors on $HOST" root@ds.npr.org
	exit
fi

#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "pruning dumps older than ${KEEP_DAYS} days from ${BACKUP_DIR}"

/usr/bin/find ${BACKUP_DIR} \
     -type f \
     -mtime +${KEEP_DAYS} \
     -exec rm -f {} \;

#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "suspending slaving"
/usr/bin/mysqladmin stop-slave 2> $TMP
if [ -s $TMP ]
then
	ERR=`/bin/cat $TMP`
	ALLERRS="mysqladmin stop-slave error: $ERR\n"
	echo "mysqladmin stop-slave error: $ERR" | $LOG 
	/bin/rm $TMP
fi

#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "commencing dumps of individual databases"

for DB in `mysql --skip-column-names -e "show databases"`; do
    if [[ ${DB} != "information_schema" ]]; then
        $LOG "dumping ${DB} to ${BACKUP_DIR}/${DB}.${DATESTAMP}.sql.gz"
        /usr/bin/mysqldump --opt \
                           --master-data=2 \
                           --single-transaction \
                           --add-drop-database \
                           -B ${DB} \
	      2> $TMP \
            | gzip -9 > ${BACKUP_DIR}/${DB}.${DATESTAMP}.sql.gz
    fi
done

if [ -s $TMP ]
then
	ERR=`/bin/cat $TMP`
	ALLERRS="${ALLERRS}mysqldump error: $ERR\n"
	echo "mysqldump error: $ERR" | $LOG 
	/bin/rm $TMP
fi
$LOG "completed dumping individual databases"

#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

$LOG "restarting slaving"
/usr/bin/mysqladmin start-slave 2> $TMP

if [ -s $TMP ]
then
	ERR=`/bin/cat $TMP`
	ALLERRS="${ALLERRS}mysqladmin start-slave error: $ERR\n"
	echo "mysqladmin start-slave error: $ERR" | $LOG 
fi
/bin/rm $TMP

#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

if [ "$ALLERRS" ]
then
	echo "$ALLERRS" | /usr/bin/mail -s "$SCRIPT errors on $HOST" root@ds.npr.org
fi

