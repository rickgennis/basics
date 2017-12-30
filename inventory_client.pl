#!/usr/bin/perl -w

use strict;
use IO::Socket;

use constant SERVER_HOST => 'inventory.pi.int';
use constant SERVER_PORT => 3456;


sub get_distro() {
    my @aVersionFiles = ('/etc/debian_version', '/etc/SuSE-release');

    foreach my $sFile (@aVersionFiles) {
        if (-e $sFile) {
            open(DEBIAN, $sFile) || next;
	    my $sDistro = <DEBIAN>;
    	    close(DEBIAN);

    	    chomp($sDistro);
	    $sDistro =~ s/linux\s+//i;
	    $sDistro =~ s/\s*\(.+\)//;
    	    return $sDistro;
        }
    }

    return '';
}



sub get_kernel() {
    open(UNAME, '/bin/uname -r |') || return '';
    my $sKernel = <UNAME>;
    close(UNAME);
    chomp($sKernel);

    open(UNAME, '/bin/uname -m |') || return $sKernel;
    $sKernel .= ' ' . <UNAME>;
    close(UNAME);
    chomp($sKernel);

    return $sKernel;
}



sub get_eth_mac_addresses() {
    my $sVMWareA = '00:0c:29';
    my $sVMWareB = '00:50:56';
    my @aMacIds = ();
    my %hMacIdDeDup = ();

    open(IFCONFIG, '/sbin/ifconfig -a |') || return '';
    while (<IFCONFIG>) {
	next unless /hwaddr|ether/i;

	if (/(hwaddr|ether)\s+(..:..:..:..:..:..)/i) {
	    my $sMAC = $2;
	    next if ($sMAC =~ /ff:ff:ff:ff/i or $sMAC =~ /00:00:00:00/);
	    next if ($sMAC =~ /$sVMWareA/i or $sMAC =~ /$sVMWareB/);

	    push(@aMacIds, $sMAC) unless exists $hMacIdDeDup{$sMAC};
	    $hMacIdDeDup{$sMAC} = 1;
	}
    }
    close(IFCONFIG);

    return @aMacIds;
}



sub get_cpu_info() {
    my $iNumCPUs;
    my $iSpeed;
    my $sDescription;

    open(CPUINFO, '/proc/cpuinfo') || return '';
    while (<CPUINFO>) {
	if (/^processor\s+:\s+(\d+)/i) { 
	    $iNumCPUs = $1 + 1; 
	}

        if (/^model name\s+:\s*(.*)$/i) {
	    $sDescription = $1;
	    $sDescription =~ s/\s{2,}/ /g;
	}

	if (/^cpu mhz\s+:\s*(.*)$/i) {
	    $iSpeed = int($1);
	}
    }
    close(CPUINFO);

    return "$iNumCPUs/$iSpeed: $sDescription";
}



sub get_total_memory() {
    my $iMem = '';

    open(MEMINFO, '/proc/meminfo') || return '';
    while (<MEMINFO>) {
	if (/MemTotal\s*:\s*(\d+)/i) {
	    $iMem = $1;
	    last;
	}
    }
    close(MEMINFO);

    return $iMem;
}



sub get_hostname() {
    my $sHostname = '';

    open(HOSTNAME, '/bin/hostname |') || return '';
    while (<HOSTNAME>) {
        chomp();
	$sHostname = $_ unless /^\s*$/;
    }
    close(HOSTNAME);

    return $sHostname;
}



sub get_disk_info() {
    my @aDevices;
    my %hDiskCapacity;

    # count up the local disks (mounts that are physical disks)
    # we're using a hash at the end so dups will fall out automatically

    open(MOUNTS, '/bin/cat /proc/mounts |') || return ();
    while (<MOUNTS>) {
	next unless /^\//;

	if (/^(\S+)/) {
	    push(@aDevices, $1);
	}
    }
    close(MOUNTS);

    # pass each device to fdisk to determine its true size
    foreach my $sDevice (@aDevices) {
        my $sBaseDevice = '';

	if ($sDevice =~ /(.*\d+\D\d+)p\d+/) {
	    $sBaseDevice = $1;
	}
	elsif ($sDevice =~ /(\/dev\/md\d+)/) {
	    $sBaseDevice = $1;
	}
	elsif ($sDevice =~ /(.*)\d+/) {
	    $sBaseDevice = $1;
	}

	if ($sBaseDevice) {
	    open(FDISK, "/sbin/fdisk -l $sBaseDevice |") or next;
	    while (<FDISK>) {
		if (/^Disk .+: (\S+)\s+GB/) {
		    $hDiskCapacity{$sBaseDevice} = $1;
		    last;
		}
	    }
	    close(FDISK);
	}
    }

    @aDevices = ();
    foreach my $sDisk (sort keys %hDiskCapacity) {
	push(@aDevices, "$sDisk: " . $hDiskCapacity{$sDisk} . "G");
    }

    return @aDevices;
}



sub get_xen_info() {
    my $sXenInfo = '';

    (-e "/usr/sbin/xm" && open(XM, "/usr/sbin/xm list |")) || return "";
    while (<XM>) {
	$sXenInfo .= $_;
    }
    close(XM);

    $sXenInfo =~ s/\n/\*\*/g;
    return $sXenInfo;
}



sub connect_to_server() {
    my $tSocket;
    my $iRetries = 0;

    while (!($tSocket = new IO::Socket::INET(PeerAddr => SERVER_HOST, PeerPort => SERVER_PORT, Proto => 'tcp')) && $iRetries++ < 5) {
	sleep(10 * int(rand(600)));
    }	

    # if we still don't have a connection let's just quietly die
    # cron will eventually kick us off again
    exit(1) unless $tSocket;

    return $tSocket;
}




#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
#   M A I N
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

my $tSocket = connect_to_server();

print $tSocket "eth\t" . join(',', get_eth_mac_addresses()) . "\n";
print $tSocket "cpu\t" . get_cpu_info() . "\n";
print $tSocket "hostname\t" . get_hostname() . "\n";
print $tSocket "memory\t" . get_total_memory() . "\n";
print $tSocket "disks\t" . join("**", get_disk_info()) . "\n";
print $tSocket "xeninfo\t" . get_xen_info() . "\n";
print $tSocket "distro\t" . get_distro() . "\n";
print $tSocket "kernel\t" . get_kernel() . "\n";

close($tSocket);

