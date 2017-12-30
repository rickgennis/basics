#!/usr/bin/perl -w

use strict;
use IO::Socket;
use IO::Select;
use Proc::Daemon;
use POSIX ();
use Sys::Syslog qw(:standard :macros);
use DBI;

use constant SERVER_PORT => 3456;

our $g_bAbort = 0;


sub process_socket($$) {
    my $tSocket = shift;
    my $tClientAddr = shift;
    my $sClientIP = '';

  eval {
    local $SIG{ALRM} = sub { die "alarm\n"; };

    my $tDbh = DBI->connect('DBI:mysql:inventory:localhost:3306', 'mysql', '', { RaiseError => 1}) or
        return syslog(LOG_INFO, "Unable to connect to dbname=inventory");

    # lookup the remote IP address for this socket - who's connecting to us
    my ($iClientPort, $tClientIP) = sockaddr_in($tClientAddr);
    $sClientIP = inet_ntoa($tClientIP);
    my $sClientHost = gethostbyaddr($tClientIP, AF_INET);
    syslog(LOG_INFO, "processing update from $sClientIP" . (length($sClientHost) ? " ($sClientHost)" : ""));
    
    my $iSystemId = 0;
    my $sRemoteData;

    while (defined ($sRemoteData = <$tSocket>)) {

        if ($sRemoteData =~ /(\w+)\t(.*)/) {
	    my $sCommand = $1;
	    my $sData = $2;
	    
	    # Ethernet MACs - we use these to uniquely id the system
	    if ($sCommand =~ /eth/) {
		$sData =~ tr/A-Z/a-z/;
		my @aMACs = split(/,/, $sData);
		my $tSth = $tDbh->prepare("SELECT system_id FROM system WHERE macs LIKE ?");

		# look up each MAC supplied by the client in the db
		foreach my $sMAC (@aMACs) {
		    $tSth->execute('%'.$sMAC.'%');
		    my $rRow = $tSth->fetchrow_hashref();

		    # if the MAC exists in the table, we want to remember the system id
		    if ($rRow && exists $rRow->{system_id}) {
			$iSystemId = $rRow->{system_id};
		    }
		    else {
		        # otherwise we need to add it to the table
			my $tSth2 = $tDbh->prepare("INSERT INTO system (macs) VALUES (?)");
			$tSth2->execute($sData);
			$tSth2->finish();

			# and then remember the new system id
			$tSth->execute($sMAC);
			my $rRowNew = $tSth->fetchrow_hashref();
			$iSystemId = $rRowNew->{system_id};
		    }
		}
		$tSth->finish();
		next;
	    }

	    next unless $iSystemId;

	    if ($sCommand =~ /cpu/) {
		if ($sData =~ m,(\d+)/(\d+):\s+(.*),) {
		    my $tSth = $tDbh->prepare("UPDATE system SET proc_num = ?, proc_speed = ?, proc_desc = ? WHERE system_id = ?");
		    $tSth->execute($1, $2, $3, $iSystemId);
		    $tSth->finish();
		}
		next;
	    }

	    if ($sCommand =~ /hostname/) {
	        my $tSth = $tDbh->prepare("UPDATE system SET hostname = ? WHERE system_id = ?");
		$tSth->execute($sData, $iSystemId);
		$tSth->finish();
		next;
	    }

	    if ($sCommand =~ /kernel/) {
	        my $tSth = $tDbh->prepare("UPDATE system SET kernel = ? WHERE system_id = ?");
		$tSth->execute($sData, $iSystemId);
		$tSth->finish();
		next;
	    }

	    if ($sCommand =~ /disks/) {
		$sData =~ s/\*\*/\n/g;
	        my $tSth = $tDbh->prepare("UPDATE system SET disks = ? WHERE system_id = ?");
		$tSth->execute($sData, $iSystemId);
		$tSth->finish();
		next;
	    }

	    if ($sCommand =~ /xeninfo/) {
		$sData =~ s/\*\*/\n/g;
	        my $tSth = $tDbh->prepare("UPDATE system SET xeninfo = ? WHERE system_id = ?");
		$tSth->execute($sData, $iSystemId);
		$tSth->finish();
		next;
	    }

	    if ($sCommand =~ /memory/) {
	        my $tSth = $tDbh->prepare("UPDATE system SET memory = ? WHERE system_id = ?");
		$tSth->execute($sData, $iSystemId);
		$tSth->finish();
		next;
	    }

	    if ($sCommand =~ /distro/) {
	        my $tSth = $tDbh->prepare("UPDATE system SET distro = ? WHERE system_id = ?");
		$tSth->execute($sData, $iSystemId);
		$tSth->finish();
		next;
	    }
        }
    }

    if ($iSystemId) {
	my $tSth = $tDbh->prepare("UPDATE system SET remote_ip = ? WHERE system_id = ?");
	$tSth->execute($sClientIP, $iSystemId);
	$tSth->finish();
    }
    
    $tDbh->disconnect();

  };

  if ($@ eq "alarm\n" ) {
    syslog(LOG_INFO, "aborting read from $sClientIP");
  }
}



#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
#  M A I N
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

# open syslog
openlog('inventory_server', 'pid', 'local0');

# open listening socket 
my $tListenSocket = IO::Socket::INET->new(LocalPort => SERVER_PORT, Proto => 'tcp', Listen => 1, Reuse => 1) || exit(5);

# fork into background and become a daemon
my $tDaemon = Proc::Daemon->new(work_dir => '/tmp', 
				pid_file => '/tmp/.inventory_server.pid', 
				dont_close_fd => [ fileno($tListenSocket) ]);
my $iDaemonPid = $tDaemon->Init;
if ($iDaemonPid) {
    $tListenSocket->close();
    closelog();
    exit(0);
}

syslog(LOG_INFO, "deamon started");

# prepare the socket for select()
my $tSockSelect = IO::Select->new();
$tSockSelect->add($tListenSocket);

while (1) {
    $g_bAbort = 0;

    my @aReadyHandles = $tSockSelect->can_read();
    foreach my $tHandle (@aReadyHandles) {

    # if it's the ListenSocket that's ready for a read that means
    # we have a new connection.  given that we process a socket
    # completely and then close it, this is the only type we can
    # possibly get.
    #
    # also note, because we're too lazy to fork off another proc to handle
    # this connection, other clients will have to wait while we process
    # this connection.  bummer for them.  retries are built-in client-side.

        if ($tHandle == $tListenSocket) {
	    my ($sNewSocket, $tClientAddr) = $tListenSocket->accept();
	    alarm(8);
	    process_socket($sNewSocket, $tClientAddr);
	    alarm(0);
	    $sNewSocket->close();
        }
    }
}

