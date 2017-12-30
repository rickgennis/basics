#!/usr/bin/perl -w
#
# {ansible managed - do not edit}
#
# 4/6/17
#
# If MySQL slaving breaks with an error of the type:
#
# 	Last_IO_Error: Got fatal error 1236 from master when reading data from binary log: 
#	'Client requested master to start replication from impossible position; the first 
#	event 'mysql-bin.024471' at 50885597, the last event read from 'mysql-bin.024471' 
#	at 4, the last byte read from 'mysql-bin.024471' at 4.'
#
# This script will restore slaving with no data loss.

use strict;

use constant MYSQL => '/usr/bin/mysql';

my $sMasterLogBase;
my $iMasterLogNumber;
my $iPrevMasterPos;
my $bSuccess = 0;
my $bBlankStateFound = 0;
my $bNullSecondsFound = 0;

open(MYS, MYSQL . " -e 'SHOW SLAVE STATUS\\G' |") || die "cannot execute " . MYSQL;

while (<MYS>) {
	if (/\sMaster_Log_File:\s(\D+)(\d+)$/) {
		$sMasterLogBase = $1;
		$iMasterLogNumber = $2; 
	}

	if (/\sRead_Master_Log_Pos:\s(\d+)$/) {
		$iPrevMasterPos = $1;
	}

	if (/\sSlave_IO_State:\s*$/) {
		$bBlankStateFound = 1;
	}

	if (/\sSeconds_Behind_Master:\sNULL$/) {
		$bNullSecondsFound = 1;
	}

	if (/Last_IO_Error:.*start replication from impossible position/) {
		if (defined $sMasterLogBase && $sMasterLogBase && defined $iMasterLogNumber && $iMasterLogNumber && $bBlankStateFound && $bNullSecondsFound) {

			print "Current Master Log: $sMasterLogBase$iMasterLogNumber\n";
			print "Current Master Pos: $iPrevMasterPos\n";

			$iMasterLogNumber++;

			print "New Master Log: $sMasterLogBase$iMasterLogNumber\n";
			print "New Master Pos: 4\n";

			print "Stopping slave... ";
			system(MYSQL . " -e 'STOP SLAVE'");

			print "\nUpdating master log file and position... ";
			system(MYSQL . " -e 'CHANGE MASTER TO MASTER_LOG_FILE=\'$sMasterLogBase$iMasterLogNumber\', MASTER_LOG_POS=4'");

			print "\nRestarting slave... ";
			system(MYSQL . " -e 'START SLAVE'");
			print "\nDone.\n";
			$bSuccess = 1;

			last;
		}
	}
}
close(MYS);

unless ($bSuccess) {
	print "The specific error condition this fix is for was not found.\n";
	print "No action taken.\n";
}
