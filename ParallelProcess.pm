package ParallelProcess;

# 10/17/2017 RGE
#
# Define the jobs you want run in parallel via the addJob() function.
# 
#	addJob("rest a bit", "sleep 5");
#	addJob("create list", "/bin/ls > /tmp/foo*");
#	addJob("copy file after list is created", "/bin/cp /tmp/foo /tmp/bar", PendingPreviousJob);
# 
# Then kick them off with the parallelProcess() function.  You specify
# how many jobs should run in parallel.  If not specified it defaults
# to 10.
# 	parallelProcess(10);
#
# Logging goes to both STDOUT and syslog.
#
# Additionally, the 'SummaryAtTop' directive can be used to alter the
# logging order.  It applies to STDOUT.
#
#	parallelProcess(10, SummaryAtTop);
#
#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

use Time::HiRes;
use Sys::Syslog qw(:standard :macros);
use base 'Exporter';
our @EXPORT = ('parallelProcess', 'addJob', 'PendingPreviousJob', 'SummaryAtTop');
use constant PendingPreviousJob => -1;
use constant SummaryAtTop => -1;
use constant FinalMessage => 1;

use warnings;
use strict;

my $sTempLogName = "/tmp/.pp.log.$$";
my %hJobs;
my %hChildProcs;
my %hErrors;
my @aLogMessages;
my $g_bSummaryAtTop = 0;


sub prettyDuration($;$) {
    my $iInitialSeconds = shift;
    my $bDropSeconds = shift || 0;

    my %hConversion = (
        31557600 => 'year',
        2419200 => 'month',
        604800 => 'week',
        86400 => 'day',
        3600 => 'hour',
        60 => 'minute',
        1 => 'second');

    my $sResult = '';
    my $iWorkingValue = $iInitialSeconds;
    foreach my $iDiv (reverse sort { $a <=> $b } keys %hConversion) {
        last if ($bDropSeconds && $iDiv == 1 && $sResult ne '');

        my $iValue = int($iWorkingValue / $iDiv);
        if ($iValue >= 1) {
            $iWorkingValue = $iWorkingValue % $iDiv;
            $sResult .= ($sResult ? ', ' : '') . $iValue . ' ' . $hConversion{$iDiv} . ($iValue == 1 ? '' : 's');
        }
    }

    return $sResult ? $sResult : '0 seconds';
}


sub logMsg($;$) {
	my $sMsg = shift;
	my $bFinalMsg = shift || 0;

	syslog(LOG_NOTICE, $sMsg);

	if ($bFinalMsg) {
		print "$sMsg\n";
		
		if ($g_bSummaryAtTop && open(LOG, $sTempLogName)) {
			local $/;
			my @aData = <LOG>;
			close(LOG);
			unlink($sTempLogName);

			foreach (@aData) {
				print;
			}
		}

		return;
	}

	if ($g_bSummaryAtTop) {
		if (open(LOG, ">>", $sTempLogName)) {
			print LOG localtime(time) . " $sMsg\n";
			close(LOG);
		}
	}
	else {
		print localtime(time) . " $sMsg\n";
	}
}


sub forkChild($) {
	my $iJobId = shift;
	my $iChildPID = fork();

	# in the parent
	if ($iChildPID) {
		$hChildProcs{$iChildPID} = Time::HiRes::time() . ';start;;' . $iJobId;
		$hJobs{$iJobId}->{'state'} = 'running';
	}

	# in the child
	else {
		logMsg($hJobs{$iJobId}->{'name'} . " starting as pid $$");
		my $iReturnCode = 0;
		my $iResult = system($hJobs{$iJobId}->{'command'} . ($g_bSummaryAtTop ? " 2> /tmp/.pp.$$.$iJobId" : ''));
		if ($iResult == -1) {
			logMsg($hJobs{$iJobId}->{'name'} . " ERROR launching [" . $hJobs{$iJobId}->{'command'} . "]");
			$iReturnCode = 127;
		}
		else {
			$iReturnCode = $iResult >> 8;
			if ($iReturnCode == 127) {
				logMsg($hJobs{$iJobId}->{'name'} ." ERROR launching [" . $hJobs{$iJobId}->{'command'} . "]");
			}
			elsif ($iReturnCode != 0) {
				logMsg($hJobs{$iJobId}->{'name'} ." ERROR; return code $iReturnCode from [" . $hJobs{$iJobId}->{'command'} . "]");
			}
		}

		exit($iReturnCode);
	}
}


sub averageTime() {
	my $iOverallElapsed = 0;
	my $iOverallCount = 0;

	my %hGroupedElapsed;

	foreach my $iJobId (keys %hJobs) {
		if (defined $hJobs{$iJobId}->{'elapsed'}) {

			if ($hJobs{$iJobId}->{'prereq'} > 0) {
				my $iTempJobId = $iJobId;

				while ($hJobs{$iTempJobId}->{'prereq'} > 0) {
					last unless defined($hJobs{$hJobs{$iTempJobId}->{'prereq'}});
					$iTempJobId = $hJobs{$iTempJobId}->{'prereq'};
				}

				$hGroupedElapsed{$iTempJobId} += $hJobs{$iJobId}->{'elapsed'};
			}
			else {
				$hGroupedElapsed{$iJobId} += $hJobs{$iJobId}->{'elapsed'};
			}

			$iOverallElapsed += $hJobs{$iJobId}->{'elapsed'};
			$iOverallCount++;
		}
	}

	my $iGroupedTotal = 0;
	$iGroupedTotal += $_ foreach values(%hGroupedElapsed);

	return($iOverallElapsed / $iOverallCount, keys(%hGroupedElapsed) > 0 ? $iGroupedTotal / keys(%hGroupedElapsed) : 0);
}


sub addJob($$;$) {
	my $sName = shift;
	my $sCommand = shift;
	my $iPreReqId = shift || 0;
	my $iNumJobs = keys(%hJobs);

	my %hJob = (	'id' => $iNumJobs + 1,
			'name' => $sName,
			'command' => $sCommand,
			'prereq' => ($iPreReqId == PendingPreviousJob) ? $iNumJobs : $iPreReqId
		   ); 
	
	$hJobs{$iNumJobs + 1} = \%hJob;
	return($iNumJobs + 1);
}


sub nextRunableJob() {
	for my $rhJob (sort { $a <=> $b } keys %hJobs) {
		my %hThisJob = %{$hJobs{$rhJob}};

		# skip jobs that are running or completed
		next if (defined $hThisJob{'state'} && ($hThisJob{'state'} eq 'running' || $hThisJob{'state'} eq 'completed'));

		# skip jobs that require a prerequisite job that hasn't completed yet
		next if ($hThisJob{'prereq'} && (!defined($hJobs{$hThisJob{'prereq'}}{'state'}) || $hJobs{$hThisJob{'prereq'}}{'state'} ne 'completed'));

		return $hThisJob{'id'};
	}

	return 0;
}


sub parallelProcess(;$$) {
	my $iMaxConcurrent = shift || 10;
	my $bSummaryAtTop = shift || 0;
	$g_bSummaryAtTop = ($bSummaryAtTop == SummaryAtTop);
	my $iInitialTime = Time::HiRes::time();

	logMsg("Starting " . keys(%hJobs) . " jobs with a max of $iMaxConcurrent concurrently");

	# kick off initial jobs 
	my $iIndex = 0;
	while (($iIndex++ < $iMaxConcurrent) && (my $iJobId = nextRunableJob())) {
		forkChild($iJobId);
	}

	# wait for a running job to finish
	while (keys %hChildProcs) {
    	my $iKid = waitpid(-1, 0);
		my ($iRC, $iSig, $bCore) = ($? >> 8, $? & 127, $? & 128);
		my $iEndTime = Time::HiRes::time();

		my $iStartTime;
		my $iJobId;
		my $sData = $hChildProcs{$iKid};
		if ($sData =~ /(.+);start;;(.*)/) {
			$iStartTime = $1;
			$iJobId = $2;
		}
		my $iElapsed = sprintf("%.2f", $iEndTime - $iStartTime);

		delete($hChildProcs{$iKid});
		$hJobs{$iJobId}->{'state'} = 'completed';

		my $sStdErrFile = "/tmp/.pp.$iKid.$iJobId";
		if (-e "$sStdErrFile") {
			if (open(my $FH, "<", $sStdErrFile)) {
				my $sErrors;
				{
					local $/;
					$sErrors = <$FH>;
				}
				close($FH);
				chomp($sErrors);

				logMsg($hJobs{$iJobId}->{'name'} . ": $sErrors") if ($sErrors);
			}
			unlink($sStdErrFile);
		}

		if ($iRC == 0) {
			$hJobs{$iJobId}->{'elapsed'} = $iElapsed;
			logMsg($hJobs{$iJobId}->{'name'} . " completed as pid $iKid (" . prettyDuration($iElapsed, 1) . ")");
		}
		else {
			$hErrors{$iJobId} = $iRC;
		}

		# kick off additional jobs if ready/remaining
		# due to prereqs we may be running less than $iMaxConcurrent jobs right now
		# and be able to kick off more than one here
		my $iCurrentlyRunning = keys(%hChildProcs);
		while ($iCurrentlyRunning++ < $iMaxConcurrent && (my $iJobId = nextRunableJob())) {
			forkChild($iJobId);
		}
	}

	# produce end summary
	my ($iOverallAverage, $iGroupedAverage) = averageTime();
	my $iJobs = keys(%hJobs);
	my $iErrors = keys(%hErrors);
	my $sSummary1 ="Successfully completed " . ($iJobs - $iErrors) . " out of $iJobs job" . ($iJobs == 1 ? '': 's') . " in " . prettyDuration(Time::HiRes::time() - $iInitialTime, 1) . '.';
	my $sSummary2 = "Average time per job was " . prettyDuration($iOverallAverage, 1) . ($iOverallAverage != $iGroupedAverage && $iGroupedAverage != 0 ? "; average time per grouped job was " . prettyDuration($iGroupedAverage, 1) : '') . '.';

	if ($g_bSummaryAtTop) {
		my $sErrs = '';
		if ($iErrors) {
			$sErrs = "Errors occurred on $iErrors job" . ($iErrors == 1 ? '' : 's') . ':' . "\n";
			foreach my $iJobId (keys %hErrors) {
				$sErrs .= "     " . $hJobs{$iJobId}->{'name'} . ($hErrors{$iJobId} == 127 ? ' failed to execute' : ' returned exit code ' . $hErrors{$iJobId}) . "\n";
			}
		}
		logMsg($sSummary1 . "\n" . $sSummary2 . "\n" . $sErrs, FinalMessage);
	}
	else {
		logMsg($sSummary1);
		logMsg($sSummary2);

		if ($iErrors) {
			logMsg("Errors occurred on $iErrors job" . ($iErrors == 1 ? '' : 's') . ':');
			foreach my $iJobId (keys %hErrors) {
				logMsg("     " . $hJobs{$iJobId}->{'name'} . ($hErrors{$iJobId} == 127 ? ' failed to execute' : ' returned exit code ' . $hErrors{$iJobId}));
			}
		}
	}
}

1;
