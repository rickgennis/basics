#!/usr/bin/perl -w
#
# {ansible managed - do not edit}
#

use strict;

sub updatePrompts($) {
	my $sState = shift;
	
	# update motd
	if (open(MOTD, "/etc/motd")) {
		while (<MOTD>) {
			if (/(MYSQL|MARIADB)\s(\w+)\s\(\w+\-(\w+)\)/) {
				close(MOTD);

				if (open(NEW_MOTD, ">/etc/motd")) {
					print NEW_MOTD "\n********************************************************************\n";
					print NEW_MOTD "********************************************************************\n\n";
					print NEW_MOTD "\t$1 $2 ($sState-$3)\n"; 
					print NEW_MOTD "\n********************************************************************\n";
					print NEW_MOTD "********************************************************************\n\n";
					close(NEW_MOTD);	
				}

				last;
			}
		}
	}

	# update sql prompt
	if (open(MY, "/etc/my.cnf")) {
		my @aMyContents;
		my $sHostname = `/bin/hostname` || 'Unknown';
		chomp($sHostname);

		while (<MY>) {
			if (/^\s*prompt\s*=/) {
				push(@aMyContents, "prompt=[$sHostname $sState] \\d>\\_\n");
			}
			else {
				push(@aMyContents, $_);
			}
		}

		close(MY);

		if (open(NEW_MY, ">/etc/my.cnf")) {
			foreach (@aMyContents) {
				print NEW_MY $_;
			}

			close(NEW_MY);
		}
	}
}


#-#-#  MAIN  #-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

if (open(MYSQL, '/usr/bin/mysql -e "SHOW SLAVE STATUS\G" |')) {
	my $bSlaveFound = 0;

	while (<MYSQL>) {
		if (/Slave_IO_State/) {
			$bSlaveFound = 1;
			updatePrompts('SLAVE');
			last;
		}
	}

	close(MYSQL);

	unless ($bSlaveFound) {
		updatePrompts('MASTER');
	}
}

