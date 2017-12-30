#!/bin/bash
#
# {ansible managed - do not edit}
#
# promote db from slave database to master database. 


HOSTNAME=`/bin/hostname`
CURRENTUSER=`id -un`


if [ "$CURRENTUSER" != 'root' ]; then
 echo "Invalid user: This script ($0) must be run as root (current user: ${CURRENTUSER})"
 exit 1
fi


echo "You're about to promote this database from slave to master."
echo -n "Are the shared VIPs down on the previous master or the previous master is inaccessible? (y/n): "
read CONTINUE
if [[ $CONTINUE != "y" ]] && [[ $CONTINUE != "Y" ]]
then
	echo "Aborting promotion."
	exit 1
fi


echo -e "\n***** Promoting database to master..."
/usr/bin/mysql < /usr/local/bin/db_promote_to_master.sql


echo "***** Bringing up the shared VIPs..."
/sbin/ifup eth0:0
/sbin/ifup eth0:1 2> /dev/null

echo "***** Sending out grat arps..."
PRIMARY_VIP=`/sbin/ip -o address | /bin/grep eth0:0 | /usr/bin/awk '{print $4}' | /usr/bin/awk -F/ '{print $1}'`
AUX1_ETH_EXISTS=`/sbin/ifconfig -s | /bin/grep eth0:1`

/usr/lib/heartbeat/send_arp -i 50 -r 10 -p /var/run/heartbeat/send_arp eth0:0 $PRIMARY_VIP auto 192.168.140.255 255.255.255.0
if [ "$AUX1_ETH_EXISTS" ]
then
	AUX_VIP1=`/sbin/ip -o address | /bin/grep eth0:1 | /usr/bin/awk '{print $4}' | /usr/bin/awk -F/ '{print $1}'`
	/usr/lib/heartbeat/send_arp -i 50 -r 10 -p /var/run/heartbeat/send_arp eth0:1 $AUX_VIP1 auto 192.168.140.255 255.255.255.0
fi


echo "***** Updating cron to no longer run dumps..."
/usr/local/bin/cronedit.pl --disable --user mysql /usr/local/bin/dump_mysql.sh
/usr/local/bin/cronedit.pl --disable --user mysql /usr/local/bin/dump_slaving_mysql.sh


echo "***** Sending reminder email..."
echo -e "$HOSTNAME has been promoted to master.\n\n" \
        "1. Update 'drupalslaves' definition in nag:/etc/nagios3/hostgroups.cfg.\n" \
	"2. Update 'mysql-backups-dump' definition in nag:/etc/nagios3/hostgroups.cfg.\n" \
	"3. Restart nagios.\n" \
        "4. Run /usr/local/bin/import_slave_dump.sh with a recent dump file on the new slave.\n\n" \
        "Do this NOW before you forget!" \
        | /usr/bin/mail -s "DB FAILED OVER (To Do List)!" ops@ds.npr.org

echo "***** Promotion complete.  See ops email."

