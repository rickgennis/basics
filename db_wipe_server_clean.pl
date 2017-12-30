#!/usr/bin/perl -w
use strict;

# {ansible managed - do not edit}
#
# Wipe a MySQL/Maria server clean of data.  Remove all databases that aren't
# built-in schemas and drop all users except for root.  Grants will still persist
# but those don't generate errors if recreated.


my $bForce = defined($ARGV[0]) && $ARGV[0] eq '--really-force';

#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Determine if we're running on a master or a slave
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

sub amSlave() {
	if (open(MYSQL, '/usr/bin/mysql -e "SHOW SLAVE STATUS\G" |')) {
	        my $bSlaveFound = 0;

       	 while (<MYSQL>) {
       	         if (/Slave_IO_State/) {
       	                 $bSlaveFound = 1;
       	                 last;
       	         }
       	 }
       	 close(MYSQL);

       	 return $bSlaveFound;
	}
	else { die "Unable to execute /usr/bin/mysql"; }
}


if (!$bForce && !amSlave()) {
	print "This doesn't appear to be a configured slave.  Use --really-force to\n";
	print "proceed anyway.\n";
	exit(1);
}


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Warn what we're about to do
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
unless ($bForce) {
	print "About to COMPLETELY wipe out the MySQL databases and users on this server.\n";
	print "Proceed? ";

	my $go = <STDIN>;
	unless ($go =~ /y/i) {
		print "Aborting.\n";
		exit(1);
	}
	print "\n";
}


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Stop slaving
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
`/usr/bin/mysql -N -e 'STOP SLAVE'`;
print "Stopped slaving.\n";


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Delete all users except for root
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

open(USERS, "/usr/bin/mysql -N -e 'SELECT COUNT(*) FROM mysql.user' |") || die "Unable to execute /usr/bin/mysql";
my $iNumUsers = <USERS>;
close($iNumUsers);
chomp($iNumUsers);

`/usr/bin/mysql -N -e "DELETE FROM mysql.user WHERE User != 'root'"`;
print "Dropped $iNumUsers user" . ($iNumUsers != 1 ? 's' : '') . "\n";


#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
# Delete all databases except for the built-in schemas
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

open(DBS, "/usr/bin/mysql -N -e 'SHOW DATABASES' |") || die "Unable to execute /usr/bin/mysql";
my @aDB = <DBS>;
close(DBS);

my $iCount = 0;
my $iDbTotal = @aDB;
foreach my $sDb (sort @aDB) {
	next if $sDb =~ /performance_schema|information_schema|mysql/;
	chomp($sDb);

	++$iCount;
	print STDERR (($iDbTotal - $iCount) . "  \r");
	`/usr/bin/mysql -N -e "DROP DATABASE $sDb"`;
}

print "Dropped $iCount database" . ($iCount != 1 ? 's' : '') . "\n";

exit(0);
