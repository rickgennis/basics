#!/bin/bash
#
# {ansible managed - do not edit}
#

THIS_HOST=`/bin/hostname -s`
SCRIPT=`/usr/bin/basename $0`
LOG="/usr/bin/logger -t $SCRIPT"


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Process command line options
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

for arg in "$@"
do

case $arg in
    -d)
	DROPALL=1
	;;
    *)
	FILENAME="${arg#*=}"
	shift
	;;
esac
done


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Provide syntax
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

if [ -t 0 -a ! "$FILENAME" ]
then
	echo "$0 [-d] dump_filename"
	echo "	-d  drop existing dbs & users before importing (wipe clean)"
	exit 1
fi


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Drop databases and users if requested
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

if [ $DROPALL ]
then
	$LOG "dropping all users and databases"
	if ! /usr/local/bin/db_wipe_server_clean.pl --really-force
	then
		exit 1
	fi
fi


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Do the import with some pre and post logging for timestamps
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

if [ ! "$FILENAME" ]
then
	FILENAME="-"
	$LOG "starting import from STDIN"
else
	$LOG "starting import of ${FILENAME}"
fi

/bin/cat ${FILENAME} | /usr/bin/mysql
$LOG "finished import"


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Wait a moment for slaving to start then create status email
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

sleep 5
/usr/bin/mysql -e 'SHOW SLAVE STATUS\G' | /usr/bin/mail -s "${SCRIPT} on ${THIS_HOST} status" ops@ds.npr.org


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Page @ops if it's during daytime hours
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

BEHIND=`/usr/bin/mysql -e 'SHOW SLAVE STATUS\G' | /bin/grep 'Seconds_Behind_Master:' | /usr/bin/awk '{print $1,$2}'`
HOUR=`/bin/date "+%H"`
if [ -e /usr/local/bin/dsps3/dsps ]
then
    /usr/bin/printf "%b" "${THIS_HOST} DB import complete\n$BEHIND\n@ops" | /usr/local/bin/dsps3/dsps -u nagios -f -a -s
fi


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Enable dumps if slaving succeeded
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

BEHIND_SECS=`/bin/echo $BEHIND | /usr/bin/awk '{print $2}'`
if [ $BEHIND_SECS != 'NULL' ]
then
    $LOG "enabling dumps"
    /usr/local/bin/db_enable_dumps.sh
fi

