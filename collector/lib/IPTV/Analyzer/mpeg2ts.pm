#
# Perl IPTV/Analyzer utility module based on the iptables module mpeg2ts
#  see "perldoc IPTV/Analyzer/mpeg2ts.pm"
#

package IPTV::Analyzer::mpeg2ts;

use strict;
use warnings;

use Config::File;
use Data::Dumper;

# debian-package: libdata-compare-perl
use Data::Compare;

use DBI;

use File::Basename; # dirname() for config file loading

# Trick to get the version number, from Version.pm, which is generated
# by configure script.
use IPTV::Analyzer::Version;

use IPTV::Analyzer::Config;
use IPTV::Analyzer::snmptrap;

###
# Global setting
our $cfg; # config

# The global state hash contain the previous read state from the proc
# file.  This is used for comparison, to detect when new drops occur.
#
our %global_state;

# Global database handle
our $dbh;

# Global heartbeat state, hack to update all streams on heartbeat
our $global_heartbeat_state = 0;

###
# Logging system
use Log::Log4perl qw(get_logger :levels);
our $logger = get_logger(__PACKAGE__);

sub TIEHANDLE {
    my $class = shift;
    bless [], $class;
}

sub PRINT {
    my $self = shift;
    $Log::Log4perl::caller_depth++;
#    ERROR @_;
#    $logger->log($ERROR, @_);
    $logger->log($ERROR, join("",(@_[0..$#_])));
    $Log::Log4perl::caller_depth--;
}


BEGIN {
     use Exporter ();
     our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

     # Package version
     $VERSION     = $IPTV::Analyzer::Version::VERSION;

     @ISA         = qw(Exporter);
     @EXPORT      = qw(
                        parse_line
                        parse_file
                        process_input_queue
                        process_inputs
                        db_connect
                        db_disconnect
                        db_commit
                        db_get_probe_id
                        db_create_probe_id
                        get_probe_id
		        validate_config
		        heartbeat_update
		        heartbeat_state_active
		        heartbeat_state_clear
		        heartbeat_state_read
		        close_daemon_sessions
		        close_stream_sessions
                      );
}


INIT {
    # Get the config settings, possible side effect load config.
    # -----------------------
    # This module rely on the $cfg config object is globally
    # available, due to historical reasons.  But it causes confusion
    # that the config file is loaded, when someone calles "use" on
    # this module, as this result in the module being executed via the
    # BEGIN section.  Try to use the INIT section and "get_config", and
    # rely on the Config.pm module to load it for us.

    # get_config() will load the config, if not already loaded.
    $cfg = IPTV::Analyzer::Config::get_config();
}

sub read_input_key($$) {
    my $input_key = shift;
    my $subkey    = shift;
    my $subvalue;
    if ( exists $cfg->{'input'}->{$input_key} ) {
	$subvalue = $cfg->{'input'}->{$input_key}->{$subkey};
    } else {
	$logger->error("Cannot find the input_key:[$input_key] in config");
    }
    return $subvalue;
}

###
# Parsing lines from the mpeg2ts proc file.  The syntax for the proc
# output is "key:value" constructs, seperated by a space.
#
sub parse_line($) {
    my $line = shift;
    my %hash;

    # Split string on whitespaces, this will produce an array with
    # strings with a "key:value" construction.
    my @elems = split('\s+', $line);
    # print Dumper(\@elems) . "\n";

    # Process all the "key:value" strings from in the array
    foreach my $elem (@elems) {

	# If the line starts with a "#" then its special info.
	if ($elem =~ m/^\#/) {
	    # Note: Has been obsoleted by the proc file will
	    #  contain a key "info:xxx"
	    # $hash{'special'} = "info";
	    next;
	}

	# Skip invalidate input
	# if ($elem !~ m/^.*:.*$/) {
	if (index($elem, ":") < 0) {
	    my $log = "Skip element($elem) MUST contain colon separator";
	    $logger->error($log);
	    next;
	}

	# Split the "key:value" construct on by the colon and only
	#  split on the first colon (or two elements), this allows us
	#  to potentially have colon in values.
	my ($key, $value) = split(':', $elem, 2);
	$hash{$key} = $value;
    }
    #print "HASH:" . Dumper($hash) . "\n";
    return \%hash;
}

sub parse_line_perl_map($) {
    my $line = shift;
    my %hash = map {split (':', $_, 2)} (split (/\s+|\#/, $line));
    #print "perl-guru-hacks " . Dumper(\%hash);
    return \%hash;
}

# For the sole purpose of making it completely unreadable
#  here is the perl one-liner parser
sub parse_line_perl_oneliner($) {
    return {map {split (':', $_, 2)} (split (/\s+|\#/, shift))};
}

###
# Parsing several lines
#
sub parse_stdin() {
    my @queue;
    while (<>) {
	my $line = $_;
	my $hashref = parse_line($line);
	push(@queue, $hashref);
    }
    return @queue;
}

sub parse_file($) {
    my $filename = shift;
    my @queue;

    $logger->debug("Reading file: $filename");

    if (! open(FILE, "<", $filename)) {
	$logger->fatal("Skip; can't open $filename: $!");
	return;
    }

    my @input = <FILE>;

    foreach my $line (@input) {
	chomp $line;

	next if ($line =~ m/^$/ );

	$logger->debug("INPUT-line: $line");
	my $hashref = parse_line($line);
	push(@queue, $hashref);
    }
    #print "QUEUE:" . Dumper(\@queue) . "\n";
    return @queue;
}

###
# IDEA: the master plan ;-)
#
# proc file is parsed, and resulting hash constructs, are placed into
# an array.
#
# This array-hash is then processed, and compared with previous
# collected data, (if no previous data, then simply store this data).
#
# If newly collected data differ from previous data, then write an
# record to the datebase.

# Generate a hash key for the global_state
sub get_state_hashkey($)
{
    my $hashref = shift;
    #print "get_state_hashkey input:" . Dumper($hashref) . "\n";

    my $key;
    if (exists $hashref->{'info'} ) {
	$key .=$hashref->{'info'} . "_info";
    }
    if (exists $hashref->{'dst'} ) {
	$key .=$hashref->{'dst'} . "__";
    }
    if (exists $hashref->{'src'} ) {
	$key .=$hashref->{'src'};
    }
    # Also hash on source port as some streamers change this port,
    # which causes the kernel module (v.0.2.0) to record two lines in
    # proc for this stream, which confused this collector.
    if (exists       $hashref->{'sport'} ) {
	$key .= ":" .$hashref->{'sport'};
    }
    if (defined $key) {
	return $key;
    } else {
	print "Wrong input!!! " . Dumper($hashref) . "\n";
	$logger->logcroak("Empty key generate, this is wrong!");
    }
}

# Compare two hashes against each other
sub compare_proc_hash($$)
{
    my $globalref = shift;
    my $inputref  = shift;

    my $global_key = get_state_hashkey($inputref);
    # $logger->info("Generated key:$global_key");

    # First check if the hash exists in the global state
    if (not exists $globalref->{$global_key}) {
	$logger->debug("Cannot find hashkey:[$global_key] in global_state");
	return 0;
    }

    # Things to ignore in the hash compare
    my $ignore = {
	'ignore_hash_keys' =>
	    [ "prev_id", "stream_session_id",
	      "last_update", # timestamp of last DB insert
	      "event_state" ] # keeping an event type state
    };

    # Compare: Returns 0 if the structures differ, else returns 1.
    my $res = Compare($globalref->{$global_key}, $inputref, $ignore);

    # Check if heartbeat is requested
    my $heartbeat = heartbeat_state_read();
    if ($heartbeat) {
	$res = 0; # Indicate need for update
    }

    return $res;
}

sub store_into_global_state($$)
{
    my $globalref = shift;
    my $inputref  = shift;

    my $global_key = get_state_hashkey($inputref);

    # Delete the contents by undefining the hash
    # (thinks this helps perls garbage collector(?))
    delete $globalref->{$global_key};

    # Store the data by assigning the input hash ref
    $globalref->{$global_key} = $inputref;

    #print "store_into_global_state: " .
    #	Dumper($globalref->{$global_key}) . "\n";
}

sub get_last_poll($)
{
    my $globalref = shift;
    my $last_poll;
    # The hashkey name 'time_info' is made by get_state_hashkey()
    if (exists $globalref->{'time_info'}) {
	$last_poll = $globalref->{'time_info'}{'now'};
    }
    return $last_poll;
}

sub get_time_info_created($)
{
    my $globalref = shift;
    my $created = 0;
    # The hashkey name 'time_info' is made by get_state_hashkey()
    if (exists $globalref->{'time_info'}) {
	$created = $globalref->{'time_info'}{'created'};
    }
    return $created;
}

sub get_time_info_delta($)
{
    my $globalref = shift;
    my $value = 0;
    # The hashkey name 'time_info' is made by get_state_hashkey()
    if (exists $globalref->{'time_info'}) {
	$value = $globalref->{'time_info'}{'delta'};
    }
    return $value;
}


sub get_version_info($)
{
    my $globalref = shift;
    my $version = "0.0.0-0";
    # The hashkey name 'version_info' is made by get_state_hashkey()
    if (exists $globalref->{'version_info'}) {
	$version = $globalref->{'version_info'}{'version'};
    }
    return $version;
}

sub process_input_queue($@)
{
    # First arg is a hashkey that identifies the input proc file
    my $probe_input = shift || $logger->logcroak("Missing input key");
    my $queueref = shift; # Array ref with hash

    # The input proc file must be specified in the config file
    if (not exists $cfg->{'input'}->{$probe_input} ) {
	$logger->logconfess("Cannot find the input_key:[$probe_input] in config");
    }

    # Check the existence of the $probe_input key in %global_state
    if (not exists $global_state{$probe_input}) {
	$global_state{$probe_input}{'created'} = localtime;
    }
    my $globalref = $global_state{$probe_input};
    #print "globalref:" . Dumper($globalref) . "\n";
    #print "process_input_queue input:" . Dumper($queueref) . "\n";

    # Lookup the previous timestamp from "info:time"
    my $last_poll = get_last_poll($globalref);

    # Find the current timestamp from this read "info:time"
    my $probe_time;
    my $created_new = 0;
    foreach my $hash (@{$queueref}) {
	# This is currently array elem two, but this foreach loop also
	# works if the layout changes.
	if (exists $hash->{'info'}) {
	    if( $hash->{'info'} eq "time" ) {
		$probe_time  = $hash->{'now'};
		$created_new = $hash->{'created'};
		last; # exit the foreach loop
	    }
	}
    }
    #print STDERR "last_poll:$last_poll probe_time:$probe_time\n";

    # Detect if kernel/module/iptables where reloaded, and
    #  reset_daemon_session(). E.g. check the info:time
    #  created:timestamp differ from the last stored timestamp.
    my $created_last = get_time_info_created($globalref);
    if ($created_last > 0 && $created_last != $created_new) {
	my $log = "Looks like iptables mpeg2ts rule was reloaded behind our back";
	$logger->warn("input[$probe_input] $log");
	reset_daemon_session($globalref);
	my $daemon_session_id = get_daemon_session($globalref, $probe_input);

	# Reset and DB close the stream_session_id's
	close_stream_sessions_for_inputkey($probe_input);
	# The close_stream_session also cleanup/delete the previous
	# data stored in $globalref, this should result in the the
	# input the input processing recreates the necessary new
	# streams.
    }

    my $changes = 0;

    # Process all the array hash elements
    foreach my $hash (@{$queueref}) {
	# print "process_input_queue hash:" . Dumper($hash) . "\n";

	if (exists $hash->{'info'}) {
	    # Special info, e.g. not a drop data record
	    # (next compare also works for special info)
	}

	my $res = compare_proc_hash($globalref, $hash);
	if ($res == 0) {
	    # Data changed (or didn't exist in global_state)

	    # Only record/count changes on real data records
	    if (!exists $hash->{'info'}) {
		$changes++;
	    }

	    # 1. Write changes to DB
	    db_insert($globalref, $hash, $probe_input, $probe_time, $last_poll);

	    # Side effects: db_insert() modifies $hash for next round
	    # - Save "prev_id" (the autoinc id)
	    # - Save "last_update" time in the hash (uses $probe_time)

	    # 2. Update the global state
	    store_into_global_state($globalref, $hash);

	} elsif ($res == 1) {
	    # Nothing to do, data didn't change
	    $logger->debug("Nothing to do, data didn't change");
	} else {
	    $logger->logcarp("This state should not be reached!");
	}
    }

    # Write / commit data to DB
    #  call commit if something changed
    if ($changes > 0) {
	db_commit();
    }

    #print "GLOBAL_STATE:" . Dumper(\%global_state) . "\n";
}

sub process_inputs() {

    # The config $cfg input has been checked by validate_config()
    my $inputs = $cfg->{'input'};

    # Walk through each input file
    foreach my $key (keys %{$inputs}) {
	my $file = $inputs->{$key}->{'procfile'};
	my $log = "Processing input File:[$file] Key:[$key]";
	#$logger->info($log);

	# Remove quotes as the file exists test doesn't like these
	$file =~ s/(\"|\')//g;
	# Check that the file exists
	if ( ! -f $file ) {
	    my $log = "Input File:[$file] does not exists - skipping!";
	    $log   .= " (Notice, daemon chdir's to /)";
	    $logger->error($log);
	    next;
	}
	my @input_queue = parse_file($file);

	my $elems = scalar(@input_queue);
	$log .= " Elems[$elems]";
	$logger->info($log);

	process_input_queue($key, \@input_queue);
    }
}

sub heartbeat_state_active()
{
    $global_heartbeat_state = 1;
}

sub heartbeat_state_clear()
{
    $global_heartbeat_state = 0;
}

sub heartbeat_state_read()
{
    return $global_heartbeat_state;
}

sub heartbeat_update()
{
    # The config $cfg input has been checked by validate_config()
    my $inputs = $cfg->{'input'};

    my $log = "Heartbeat: Tick";
    # Walk through each input file
    foreach my $key (keys %{$inputs}) {
	$logger->info("$log for input[$key]");
	heartbeat_daemon_session($key);
    }
}

sub close_daemon_sessions()
{
    # The config $cfg input has been checked by validate_config()
    my $inputs = $cfg->{'input'};

    $logger->warn("Closing all daemon_sessions");

    # Walk through each input file
    foreach my $input_key (keys %{$inputs}) {

	if (exists          $global_state{$input_key}) {
	    my $globalref = $global_state{$input_key};
	    reset_daemon_session($globalref);
	}
    }
}

sub restart_daemon_sessions()
{
    # The config $cfg input has been checked by validate_config()
    my $inputs = $cfg->{'input'};

    $logger->warn("Restart all daemon_sessions");

    # Walk through each input file
    foreach my $input_key (keys %{$inputs}) {

	if (exists          $global_state{$input_key}) {
	    my $globalref = $global_state{$input_key};
	    reset_daemon_session($globalref);
	    my $new_id = get_daemon_session($globalref, $input_key);
	}
    }
}

sub close_stream_sessions()
{
    # The config $cfg input has been checked by validate_config()
    my $inputs = $cfg->{'input'};

    my $log = "Closing all stream_sessions";
    $logger->info($log);

    # Walk through each input file
    foreach my $input_key (keys %{$inputs}) {
	close_stream_sessions_for_inputkey($input_key);
    }
    db_commit();
}


sub close_stream_sessions_for_inputkey()
{
    my $input_key = shift;

    if (exists          $global_state{$input_key}) {
	my $globalref = $global_state{$input_key};

	my $log = "Closing all stream sessions for input[$input_key]";
	$logger->info($log);

	# Walk through the recorded streams
	foreach my $stream_key (keys %{$globalref}) {

	    my $hashref = $globalref->{$stream_key};
	    # The stream is stored in a hash
	    if (ref($hashref) eq 'HASH') {

		# Find streams by looking for 'stream_session_id'
		if (exists            $hashref->{'stream_session_id'}) {
		    my $stream_id   = $hashref->{'stream_session_id'};
		    my $last_log_id = $hashref->{'prev_id'};
		    #print "This is a stream id:$stream_id\n";
		    #print Dumper($hashref);
		    if (defined $stream_id) {
			db_close_stream_session($stream_id, $last_log_id);
		    }
		    # Guess this line has no real effect as we delete
		    # the hole hash below... but better be safe.
		    $hashref->{'stream_session_id'} = undef;
		    # Cleanup/delete all the contents for the input
		    # line as its not valid in the next run.
		    delete $globalref->{$stream_key};
		    #$logger->error(Dumper($globalref->{$stream_key}));
		}
	    }
	}
    }
}

###
# Database stuff

sub db_connect()
{
    # Connect to DB
    my $dsn = "DBI:mysql:$cfg->{dbname}:$cfg->{dbhost}";

    $dbh = DBI->connect($dsn, $cfg->{dbuser}, $cfg->{dbpass},
			{ RaiseError => 0, AutoCommit => 0 })
	or $logger->logcroak("Problem connecting to DB $!");

    my $res = db_prepare_log_insert();
    return $dbh;
}

# NOTICE: the global variable!
our $insert_log_event;

sub db_prepare_log_insert()
{
    # Create/prepare an insert object
    my $insert_query =
	"INSERT INTO log_event " .
	"(probe_id, daemon_session_id, stream_session_id, " .
	" skips, discontinuity," .
	" delta_skips, delta_discon," .
	" event_type," .
	" packets, delta_packets, " .
	" payload_bytes, delta_payload_bytes, " .
	" pids, delta_poll," .
	" multicast_dst, ip_src," .
	" delta_update, last_update, " .
	" probe_time, last_poll) " .
	"VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?," .
	" FROM_UNIXTIME(?), FROM_UNIXTIME(?), FROM_UNIXTIME(?))";

    my $res = $insert_log_event = $dbh->prepare($insert_query);
    if (not $res) {
	$logger->logcroak("DB problems on prepare insert statement $!");
    }
    return $res;
}

sub db_commit()
{
    if (! $dbh->commit()) {
	# Detect if the "MySQL server has gone away" and do a
	# reconnect at this point.
	my $log = "DB Commit failed, trying to reconnect! Error: ";
	$logger->logcluck($log . $dbh->errstr);
	db_reconnect();
    }
}

sub db_reconnect() {
    # Because we use AutoCommit => 0 we have to implement reconnection
    #  our self...
    #
    my $dsn = "DBI:mysql:$cfg->{dbname}:$cfg->{dbhost}";
    my $log = "DB Trying to reconnect! Error: ";
    $logger->warn($log . $dbh->errstr);
    $dbh->rollback() || $logger->error("Rollback failed");
    db_disconnect();
    sleep(1);

    # Reconnect loop
    # Use cfg file options for db_reconnect_{delay,tries}
    my $delay = $cfg->{'db_reconnect_delay'} || 30;
    my $tries = $cfg->{'db_reconnect_tries'} || 10;
    my $i;
    for ($i=0; $i < $tries; $i++) {

	# Connect to DB
	$dbh = DBI->connect($dsn, $cfg->{dbuser}, $cfg->{dbpass},
			    { RaiseError => 0, AutoCommit => 0 });
	if ($dbh) {
	    #$i = $tries;
	    $logger->error("DB reconnect successful!");
	    last;
	} else {
	    # Wait before retry
	    my $log = "DB reconnect failed, trying again in $delay sec (try:$i)";
	    $logger->error($log);
	    sleep($delay);
	}
    }

    # Die hard if it wasn't possible to reconnect
    if (!$dbh) {
	    $logger->logcroak("DB reconnect FAILED -- giving up!");
    } else {
	# We are reconnected, but we cannot trust our current/last
	# stored reading.  Thus, we reset the daemon_sessions and
	# stream_sessions.
	restart_daemon_sessions();

	# Closing the stream sessions also cleans up the in memory
	# data records, thus resulting in new sessions being recreated
	# in the next run of reading the input files.
	close_stream_sessions();

	# Then prepare our log insert again
	my $res = db_prepare_log_insert();
    }
}


sub db_disconnect()
{
    $dbh->disconnect();
}

sub get_probe_id
{
    my $input_key = shift || $logger->logcroak("Need input_key as input");
    my $probe_ip  = shift || $cfg->{'probe_ip'};

    my $id;
    if (exists $global_state{'probe_id'}{"$probe_ip"}{"$input_key"}) {
	$id =  $global_state{'probe_id'}{"$probe_ip"}{"$input_key"};
    } else {
	$id = db_get_probe_id($input_key, $probe_ip);
	if ($id < 0) {
	    $id = db_create_probe_id($input_key, $probe_ip);
	}
	if (defined $id && $id >= 0 ) {
	    # Cache the info
	    $global_state{'probe_id'}{"$probe_ip"}{"$input_key"} = $id;
	}
    }
    return $id;
}

sub db_get_probe_id
{
    my $input_key = shift;
    my $probe_ip  = shift || $cfg->{'probe_ip'};

    my $shortloc = read_input_key($input_key, "shortloc");
    my $switch   = read_input_key($input_key, "switch");

    my $query =
	"SELECT * FROM probes " .
	"WHERE ip = ?       AND input = ? " .
	"  AND shortloc = ? AND switch = ? " .
	"LIMIT 1" ;

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    $sql->execute($probe_ip, $input_key, $shortloc, $switch)
	or $logger->logcroak("Can't execute the query: $query Error:"
			     . $sql->errstr);
    # Indicate failure
    my $id = -1;

    my $log = "in DB for input:[$input_key] IP:[$probe_ip]";
    $log   .= " shortloc:[$shortloc] switch:[$switch]";

    my $result = $sql->fetchall_hashref('id');
    foreach my $key (keys %{$result}) {
	$id = $key;
	$logger->info("Found probe ID:[$id] $log");
    }

    # Things to ignore in the hash compare
    my $ignore = {
	'ignore_hash_keys' =>
	    [ "id", "name", "ip", "input" ]
    };

    # Trick to see how many rows were selected
    # $rows = $sth->rows;

    if ($id < 0) {
	$logger->info("Cannot find a probe_id $log");
    } else {
	# An ID existed, check to see if it needs updating
	#
	# Make a compare with the rest of the optional parameters,
	# and if they differ, then UPDATE the optional values.
	#

	my $cmp = Compare($result->{$id},
			  $cfg->{'input'}->{$input_key}, $ignore);

	if ($result->{$id}->{'name'} ne $cfg->{'probe_name'}) {
	    # Special case to allow updating the probe_name in DB
	    $cmp = 0;
	    my $l = "Probe ID:[$id] name changed from ";
	    $l .= $result->{$id}->{'name'} . " to ";
	    $l .= $cfg->{'probe_name'};
	    $logger->warn($l);
	}
	#print "DB:" . Dumper($result->{$id}) . "\n";
	#print "IN:" . Dumper($cfg->{'input'}->{$input_key}) . "\n";
	#print "CFG:" .Dumper($cfg) . "\n";
	if ($cmp == 0) {
	    # Data changed
	    $logger->info("Config data changed for $log");
	    # Log the old values
	    my $old = "Probe ID:[$id] OLD values:";
	    foreach my $key (sort keys %{$result->{$id}}) {
		my $value = $result->{$id}->{$key};
		$old .= " ${key}:[$value]";
	    }
	    $logger->info($old);

	    # Log the new values
	    my $new = "Probe ID:[$id] NEW values:";
	    my $hashref = $cfg->{'input'}->{$input_key};
	    foreach my $key (sort keys %{$hashref}) {
		my $value = $hashref->{$key};
		$new .= " ${key}:[$value]";
	    }
	    $logger->info($new);

	    # UPDATE record
	    db_update_probe_id($id, $input_key);
	}
    }
    return $id;
}

sub db_create_probe_id($$)
{
    my $input_key = shift;
    my $probe_ip  = shift || $cfg->{'probe_ip'};

    #print Dumper($cfg->{'input'}->{$input_key}) . "\n";

    # Required
    my $name     = $cfg->{'probe_name'};
    my $shortloc = read_input_key($input_key, "shortloc");
    my $switch   = read_input_key($input_key, "switch");

    # Optional
    my $description=read_input_key($input_key, "description");
    my $location  = read_input_key($input_key, "location");
    my $address   = read_input_key($input_key, "address");
    my $distance  = read_input_key($input_key, "distance");
    my $input_ip  = read_input_key($input_key, "input_ip");
    my $input_dev = read_input_key($input_key, "input_dev");
    my $procfile  = read_input_key($input_key, "procfile");
    my $switchport= read_input_key($input_key, "switchport");
    my $switchtype= read_input_key($input_key, "switchtype");
    my $hidden    = read_input_key($input_key, "hidden");

    my $query =
	"INSERT INTO probes " .
	" (input, ip, name, shortloc, switch," .
	"  description, location, address, distance," .
	"  input_ip, input_dev, " .
	"  procfile, switchport, switchtype, hidden )" .
	" VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

    my $log = "Creating new probe id for input:$input_key";
    $log   .= " (ip:$probe_ip, name:$name,";
    $log   .= " shortloc:$shortloc, switch:$switch)";
    $logger->info($log);

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    $sql->execute($input_key, $probe_ip, $name, $shortloc, $switch,
		  $description, $location, $address, $distance,
		  $input_ip, $input_dev,
		  $procfile, $switchport, $switchtype, $hidden)
	or $logger->logcroak("Can't execute the query: $query Error:"
			     . $sql->errstr);

    my $id = $dbh->{'mysql_insertid'};
    db_commit();
    return $id;
}


sub db_update_probe_id($$$)
{
    my $id        = shift;
    my $input_key = shift;
    my $probe_ip  = shift || $cfg->{'probe_ip'};

    #print Dumper($cfg->{'input'}->{$input_key}) . "\n";

    # Required
    my $name     = $cfg->{'probe_name'};
    my $shortloc = read_input_key($input_key, "shortloc");
    my $switch   = read_input_key($input_key, "switch");

    # Optional
    my $description=read_input_key($input_key, "description");
    my $location  = read_input_key($input_key, "location");
    my $address   = read_input_key($input_key, "address");
    my $distance  = read_input_key($input_key, "distance");
    my $input_ip  = read_input_key($input_key, "input_ip");
    my $input_dev = read_input_key($input_key, "input_dev");
    my $procfile  = read_input_key($input_key, "procfile");
    my $switchport= read_input_key($input_key, "switchport");
    my $switchtype= read_input_key($input_key, "switchtype");
    my $hidden    = read_input_key($input_key, "hidden");

    my $query =
	"UPDATE probes SET " .
	" description = ?, location = ?, address = ?, distance = ?," .
	" input_ip = ?, input_dev = ?, name = ?," .
	" procfile = ?, switchport = ?, switchtype = ?, hidden = ?" .
	" WHERE ip = ?       AND input = ? " .
	"  AND  shortloc = ? AND switch = ? " .
	" LIMIT 1";
#	" WHERE id = ? " .

    my $log = "UPDATE probe id:$id for input:$input_key";
    $log   .= " (ip:$probe_ip, name:$name,";
    $log   .= " shortloc:$shortloc, switch:$switch)";
    $logger->info($log);

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    $sql->execute($description, $location, $address, $distance,
		  $input_ip, $input_dev, $name,
		  $procfile, $switchport, $switchtype, $hidden,
		  $probe_ip, $input_key,  $shortloc, $switch)
	or $logger->logcroak("Can't execute the query: $query Error:"
			     . $sql->errstr);
    db_commit();
}

sub db_create_daemon_session($$)
{
    my $input_key = shift;
    my $globalref = shift;
    my $daemon_pid = $$;

    my $probe_id = get_probe_id($input_key);

    # my $globalref = $global_state{$input_key};
    my $created = get_time_info_created($globalref);
    my $version = get_version_info($globalref);

    my $query =
	"INSERT INTO daemon_session " .
	" (probe_id, daemon_pid, mpeg2ts_created, mpeg2ts_version)" .
	" VALUES (?, ?, FROM_UNIXTIME(?), ?)";

    my $log = "Creating new daemon_session for probe_id:[$probe_id]";
    $log   .= " pid:[$daemon_pid]";
    $log   .= " input:[$input_key]";

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    $sql->execute($probe_id, $daemon_pid, $created, $version)
	or $logger->logcroak("Can't execute the query($probe_id, $daemon_pid): "
			     . "$query Error:" . $sql->errstr);

    my $id = $dbh->{'mysql_insertid'};

    $log .= " daemon_session_id:[$id]";
    $log .= " mpeg2ts_ver:[$version]";
    $log .= " mpeg2ts_created:[$created]";
    $logger->info($log);

    db_commit();
    return $id;
}

sub db_close_daemon_session($)
{
    my $daemon_session_id = shift;

    my $query =
	"UPDATE daemon_session SET " .
	" stop_time = CURRENT_TIMESTAMP() " .
	" WHERE id = ?" .
	" LIMIT 1";

    my $log = "SQL-UPDATE daemon_session with stop_time";
    $log   .= " (id:$daemon_session_id)";

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    my $cnt = 0;
    ($cnt = $sql->execute($daemon_session_id))
	or $logger->error("Can't execute the query: ${query}" .
			  "($daemon_session_id) Error: " . $sql->errstr);

    if ($cnt < 1) {
	$logger->error("Failed " . $log);
    } else {
	$logger->debug($log);
    }
    db_commit();
}

sub db_heartbeat_daemon_session($)
{
    my $daemon_session_id = shift;
    my $daemon_pid = $$;

    my $query =
	"UPDATE daemon_session SET " .
	" heartbeat = CURRENT_TIMESTAMP() " .
	" WHERE id = ? AND daemon_pid = ?" .
	" LIMIT 1";

    my $log = "Heartbeat UPDATE daemon_session";
    $log   .= "(id:$daemon_session_id)";

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    my $cnt = 0;
    ($cnt = $sql->execute($daemon_session_id, $daemon_pid))
	or $logger->error("Can't execute the query: ${query}" .
			  "($daemon_session_id) Error: " . $sql->errstr);

    if (defined $cnt && $cnt == 1) {
	$logger->debug($log);
    } else {
	$logger->error("Failed " . $log);
    }
    db_commit();
}

sub heartbeat_daemon_session($)
{
    my $input_key = shift;
    my $globalref = $global_state{$input_key};

    if (ref($globalref) ne 'HASH') {
	my $log = "Heartbeat: Cannot find state on input[$input_key]";
	$logger->warn($log);
    }

    my  $daemon_session_id = get_daemon_session($globalref, $input_key);
    if ($daemon_session_id) {
	db_heartbeat_daemon_session($daemon_session_id);
    } else {
	my $log = "Heartbeat failed: No daemon_session_id found";
	$log   .= " for input[$input_key]";
	$logger->warn($log);
    }
}

sub reset_daemon_session($)
{
    my $globalref = shift;
    if (exists $globalref->{'daemon_session_id'}) {
	my $daemon_session_id = $globalref->{'daemon_session_id'};
	delete $globalref->{'daemon_session_id'};
	$logger->info("Reset daemon_session_id:[$daemon_session_id]");
	db_close_daemon_session($daemon_session_id);
    }
}

sub get_daemon_session($$)
{
    my $globalref = shift;
    my $input_key = shift;
    #
    #my $globalref = $global_state{$input_key};

    my $daemon_session_id;
    if (exists               $globalref->{'daemon_session_id'}) {
	$daemon_session_id = $globalref->{'daemon_session_id'};
    } else {
	$daemon_session_id =
	    db_create_daemon_session($input_key, $globalref);
	$globalref->{'daemon_session_id'} = $daemon_session_id;
    }
    return $daemon_session_id;
}


sub db_close_stream_session($$)
{
    my $stream_session_id = shift;
    my $last_log_id = shift || 0;

    my $query =
	"UPDATE stream_session SET " .
	" stop_time = CURRENT_TIMESTAMP(), " .
	" logid_end = ? " .
	" WHERE id = ?" .
	" LIMIT 1";

    my $log = "SQL-UPDATE stream_session with stop_time";
    $log   .= " (id:$stream_session_id logid_end:$last_log_id)";

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    my $cnt = 0;
    ($cnt = $sql->execute($last_log_id, $stream_session_id))
	or $logger->error("Can't execute the query: ${query}" .
			  "($stream_session_id) Error: " . $sql->errstr);

    if ($cnt < 1) {
	$logger->error("Failed " . $log);
    } else {
	$logger->debug($log);
    }
    #db_commit();
}

sub db_update_stream_session_logid($$)
{
    my $stream_session_id = shift;
    my $logid_begin = shift;

    my $query =
	"UPDATE stream_session SET " .
	" logid_begin = ? " .
	" WHERE id = ?" .
	" LIMIT 1";

    my $log = "SQL-UPDATE stream_session with logid_begin";
    $log   .= " (id:$stream_session_id, logid:$logid_begin)";

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    my $cnt = 0;
    ($cnt = $sql->execute($logid_begin, $stream_session_id))
	or $logger->error("Can't execute the query" .
			  "($logid_begin, $stream_session_id):\n${query}" .
			  "\nError: " . $sql->errstr);

    if ($cnt < 1) {
	$logger->error("Failed " . $log);
    } else {
	$logger->debug($log);
    }
    return $cnt;
}

sub db_create_stream_session($$$$)
{
    my $inputref          = shift;
    my $probe_id          = shift;
    my $daemon_session_id = shift;
    my $input_key         = shift;

    # Extract info from $inputref
    my $multicast_dst = $inputref->{'dst'};
    my $ip_src        = $inputref->{'src'};
    my $port_dst      = $inputref->{'dport'};
    my $port_src      = $inputref->{'sport'};

    my $query =
	"INSERT INTO stream_session " .
	" (probe_id, daemon_session_id, " .
	"  multicast_dst, ip_src, port_dst, port_src)" .
	" VALUES (?, ?, ?, ?, ?, ?)";

    my $log = "Creating new stream_session for";
    $log   .= " channel:[$multicast_dst] ";
    $log   .= " input:[$input_key] ";
    $log   .= " probe_id:[$probe_id]";

    my $sql = $dbh->prepare($query)
	or $logger->logcroak("Can't prepare $query:" . $dbh->errstr . "($!)");

    $sql->execute($probe_id, $daemon_session_id, $multicast_dst,
		  $ip_src, $port_dst, $port_src)
	or $logger->logcroak("Can't execute the query(" .
			     "$probe_id, $daemon_session_id, $multicast_dst, " .
			     "$ip_src, $port_dst, $port_src):\n" .
			     "$query\nError: " . $sql->errstr);

    my $id = $dbh->{'mysql_insertid'};

    $log .= " stream_session_id:[$id]";
    $log .= " ip_src:[$ip_src]";
    $logger->info($log);

    #db_commit();
    return $id;
}

sub snmptrap_no_signal($$$)
{
    my $severity_name = shift; # clear/critical
    my $probe_input   = shift;
    my $inputref      = shift;

    # extract stream id data from $inputref
    my $mc_dst = $inputref->{'dst'} || "0.0.0.0";
    my $ip_src = $inputref->{'src'} || "0.0.0.0";

    # Extract the TIMETICKS for the trap
    my $globalref = $global_state{$probe_input};
    # timeticks is in hundredths of seconds
    my $timeticks = int(get_time_info_delta($globalref) * 100);

    # Located in snmptrap.pm module
    my $res = send_snmptrap("no_signal", $severity_name, $probe_input,
			    $timeticks, $mc_dst, $ip_src);
    # TODO: log snmptrap events and failure
}

sub detect_event_type($$$$$$$)
{
    my $inputref      = shift;
    my $event_state   = shift;
    my $probe_input   = shift;
    my $delta_discon  = shift;
    my $delta_skips   = shift;
    my $delta_packets = shift;
    my $new_stream    = shift;

    my $log = "Event on Input:[$probe_input] ";

    # The event_types are defined in Config.pm
    # Lookup below event types, as they always come into use in code path
    #  - Stream have stopped transmitting data
    my $event_no_signal  = lookup_event("no_signal");
    #  - The event_state changed since last poll
    my $event_transition =  lookup_event("transition");

    # Detect the different event types
    # --------------------------------
    my $event_type = 0;

    # - Detect new stream
    if ($new_stream) {
	$event_type |= lookup_event("new_stream");
    }
    # - Detect drops
    if (($delta_discon > 0) || ($delta_skips > 0)) {
	$event_type |= lookup_event("drop");
    }
    # - Detect no-signal (based on $delta_packets only)
    if (defined $delta_packets) {
	if ($delta_packets == 0) {
	    $event_type |= $event_no_signal;
	}
	# This should not happen check
	if ($delta_packets < 0) {
	    $logger->error("$log - negative delta packets");
	    $event_type = lookup_event("invalid");
	}
    }
    if ($event_type == 0) {
	# Assume this is a heartbeat check, if no event is detected.
	$event_type = lookup_event("heartbeat");
    }

    # Compare to previous event_state
    # -------------------------------

    #  stream id data
    my $mc_dst = $inputref->{'dst'} || "0.0.0.0";
    my $ip_src = $inputref->{'src'} || "0.0.0.0";
    $log .= "$ip_src->$mc_dst:";

    # Different "no-signal" state transitions
    #  where is only care about some of them
    # -----
    # (1) signal    -> no-signal (react)
    # (2) no-signal -> no-signal (don't care)
    # (3) no-signal -> signal    (react)
    # (4) signal    -> signal    (don't care)
    #
    if ( $event_state & $event_no_signal ) {
	# Previous state had no-signal detected
	if ( !($event_type & $event_no_signal) ) {
	    # Current state have signal
	    # = transition: (3) no-signal -> signal
	    $logger->warn("$log no-signal -> signal (send snmptrap)");
	    snmptrap_no_signal("clear", $probe_input, $inputref);
	}
    } else {
	# Previous state had signal
	if ( $event_type & $event_no_signal ) {
	    # Current state have no-signal
	    # = transition: (1) signal -> no-signal
	    $logger->warn("$log signal -> no-signal (send snmptrap)");
	    snmptrap_no_signal("critical", $probe_input, $inputref);
	}
    }

    # Store the event "state" for next round
    $inputref->{'event_state'} = $event_type;

    # IDEA: Track general transitions.
    #  For drop events, this could be use for filtering events
    #  for channels with excessive drops, in every poll cycle.
    #
    if ($event_state != $event_type) {
	$event_type |= $event_transition;
    }

    return $event_type;
}

sub db_insert($$$$$)
{
    my $globalref   = shift;
    my $inputref    = shift;
    my $probe_input = shift;
    my $probe_time  = shift || 0;
    my $last_poll   = shift || 0;

    my $log = "Detected change on Input:[$probe_input] ";

    # Check that the insert statement is prepared
    if (not $insert_log_event) {
	$logger->logcroak("DB error, forgot to connect to DB?!?");
    }

    # Get the probe id via $probe_input, and DB create if not exist
    my $probe_id = get_probe_id($probe_input);

    # TODO: Check for a valid data record

    # Skip special info for now...
    if (exists $inputref->{'info'}) {
	# Special info, e.g. not a drop data record
	my $l = $log . "special info:[" . $inputref->{'info'} . "] skip";
	$logger->debug($l);
	return 1; # skip
    }

    # Extract data from hash input
    my $multicast_dst = $inputref->{'dst'};
    my $ip_src        = $inputref->{'src'};
    my $skips         = $inputref->{'skips'};
    my $discontinuity = $inputref->{'discontinuity'};
    my $port_dst      = $inputref->{'dport'};
    my $port_src      = $inputref->{'sport'};
    my $pids          = $inputref->{'pids'};
    # Get packets and payload_bytes, and handle undef
    my $packets       = $inputref->{'packets'} || 0;
    my $payload_bytes = $inputref->{'payload_bytes'} || 0;

    # Lookup the globalref
    my $global_key  = get_state_hashkey($inputref);
    #
    my $delta_skips  = 0; # Must not be NULL in DB
    my $delta_discon = 0; # Must not be NULL in DB

    my $delta_packets = undef;
    my $delta_payload_bytes = 0;

    # The stream session is must be found or created later
    my $stream_session_id = undef;
    my $new_stream_session= 0;

    my $prev_id = 0;
    my $last_update = undef;
    my $event_state = 0;

    # Use/look at the previous stored data
    # ------------------------------------
    if (exists        $globalref->{$global_key}) {
	# Get a ref to the previous stored data
	my $prevref = $globalref->{$global_key};

	# Extract the previous event_state
	if (exists $prevref->{'event_state'}) {
	    $event_state = $prevref->{'event_state'};
	}

	# Find the previous insert id (if possible)
	if (exists     $prevref->{'prev_id'}) {
	    $prev_id = $prevref->{'prev_id'};
	}

	# Find the timestamp of the last db update/insert (if possible)
	if (exists         $prevref->{'last_update'}) {
	    $last_update = $prevref->{'last_update'};
	}

	# Calculate the delta skips and discontinuity at this point
	if( my $prev_skips = $prevref->{'skips'}) {
	    $delta_skips = $skips - $prev_skips;
	}
	if( my $prev_discon = $prevref->{'discontinuity'}) {
	    $delta_discon = $discontinuity - $prev_discon;
	}

	# Calculate the delta packets and payload_bytes
	if( my $prev_packets = $prevref->{'packets'}) {
	    $delta_packets = $packets - $prev_packets;
	    # Set variable to indicate $delta_packets is valid? or use undef?
	}
	if( my $prev_payload_bytes = $prevref->{'payload_bytes'}) {
	    $delta_payload_bytes = $payload_bytes - $prev_payload_bytes;
	}

	# Extract prev/stored stream_session_id
	if (exists               $prevref->{'stream_session_id'}) {
	    $stream_session_id = $prevref->{'stream_session_id'};
	}

	# Test for delta values being negative.  This is not allowed
	# by the DB as the values are UNSIGNED, but it will only give
	# a DB warning.  This situation can be caused by reloading the
	# netfilter rules while the collector daemon is running.
	#
	# If negative delta occurs, create a new stream_session_id!
	if (($delta_skips < 0) || ($delta_discon < 0)) {
	    if (defined $stream_session_id) {
		db_close_stream_session($stream_session_id, $prev_id);
	    }
	    # reset_stream_session();
	    $stream_session_id = undef;

	    $delta_skips  = 0;
	    $delta_discon = 0;
	}
    }
    # Extract the daemon_session_id here, and create if it didn't exist
    my $daemon_session_id =
	get_daemon_session($globalref, $probe_input);
    #print Dumper($globalref);

    # stream_session_id: Create a new if needed
    if (not defined $stream_session_id) {
	$stream_session_id =
	    db_create_stream_session($inputref, $probe_id,
				     $daemon_session_id, $probe_input);
	$new_stream_session = 1;
    }
    # We need to store the stream_session_id for next run, as the
    #  $globalref->{$global_key} ($prevref) will be overwritten by
    #  $inputref later
    $inputref->{'stream_session_id'} = $stream_session_id;

    # delta_poll: seconds since last poll
    my $delta_poll = undef;
    $delta_poll = $probe_time - $last_poll if $last_poll;

    # delta_update: seconds since last event record in database
    my $delta_update = undef;
    $delta_update = $probe_time - $last_update if $last_update;

    my $event_type = detect_event_type($inputref, $event_state, $probe_input,
				       $delta_discon, $delta_skips,
				       $delta_packets, $new_stream_session);

    if (!defined($delta_packets)) {
	# DB don't want NULL/undef in delta_packets
	$delta_packets = 0;
    }
    if ($delta_packets < 0) {
	$logger->error("$log - correcting negative delta packets");
	$delta_packets = 0;
	$delta_payload_bytes = 0;
    }

    $log .= "stream:[$multicast_dst]";
    $log .= " skips:[$skips] discon:[$discontinuity]";
    $log .= " event:[$event_type]";
    $log .= " delta_skips:[$delta_skips]"   if ($delta_skips  > 0);
    $log .= " delta_discon:[$delta_discon]" if ($delta_discon > 0);
    $log .= " delta_packets:[$delta_packets]" if ($delta_packets > 0);
    $log .= " delta_payload_bytes:[$delta_payload_bytes]"
	if ($delta_payload_bytes > 0);
    $log .= " delta_update:[$delta_update]" if ($delta_update);
    $log .= " delta_poll:[$delta_poll]"     if ($delta_poll);
    $logger->info($log);


    my $res = $insert_log_event->execute(
	$probe_id, $daemon_session_id, $stream_session_id,
	$skips, $discontinuity,
	$delta_skips, $delta_discon,
	$event_type,
	$packets, $delta_packets,
	$payload_bytes, $delta_payload_bytes,
	$pids, $delta_poll,
	$multicast_dst, $ip_src, # Redundant due to stream_session
	$delta_update, $last_update,
	$probe_time, $last_poll
	);

    #print STDERR "DB last_poll:$last_poll probe_time:$probe_time val:$delta_poll\n";


    # Extract the autoincrement id for this insert and save it for the
    # next time we need to store an records for the same stream/hash.
    #
    my $autoinc_id = $dbh->{'mysql_insertid'};
    $inputref->{'prev_id'} = $autoinc_id;

    # Save "last_update" the last time we inserted a record in the DB.
    $inputref->{'last_update'} = $probe_time;
    # FIXME: Add a timestamp per line in proc file, as the use of
    #  "probe_time"/info:time "now" is not 100% accurate, as time pass
    #  while reading each line from the proc file/kernel.

    if (not $res) {
	$logger->fatal("DB error on INSERT (record lost: $log)");
	# Reconnect to DB if the insert failed
	db_reconnect();
    }

    # Hack to update the "logid_begin" in the stream_session table,
    #  this could perhaps be handled DB side, by a DB tricker?
    if ($new_stream_session && $res) {
	db_update_stream_session_logid($stream_session_id, $autoinc_id);
    }
    return $res;
}


1;
__END__
# Below is documentation for the module.
#  One way of reading it: "perldoc IPTV/Analyzer/mpeg2ts.pm"

=head1 NAME

IPTV::Analyzer::mpeg2ts - collector utility for the iptables module mpeg2ts

=head1 SYNOPSIS

This modules provides common functions and utilities for the IPTV analyzer
which is based upon the iptables module mpeg2ts.

=head1 DESCRIPTION

The main purpose of the module is to provide parsing facilities for
the proc file output from the mpeg2ts kernel netfilter/iptables module.

The syntax for the proc output is "key:value" constructs, seperated by
a space.  This is done to easy machine/script parsing and still human
readable.

=head1 DEPENDENCIES

The module uses the module L<Config::File> for reading all config
files and the module L<Log::Log4perl> for the logging facility.

The module uses a default config file called: C<collector.conf>, which
is located in C</etc/iptv-analyzer/>.

=head1 CONFIG

Example of the config file: /etc/iptv-analyzer/collector.conf

 # DB setup
 dbhost = localhost
 dbname = tvprobedb
 dbuser = tvprobeuser
 dbpass = tvprobepasswd
 
 # Identification of the probe
 #
 # The probe_ip is the main identifier together with input[hashkey].
 # The probe_ip is normally the management IP.  The IP of the
 # measurement interface can (optionally) be specified together with
 # the "input[xxx][input_ip]".
 #
 probe_ip   = 10.10.10.42
 probe_name = tvprobe42
 
 # Input files to parse
 # --------------------
 # The keys used for identifying an input in the DB is:
 #  1. probe_ip
 #  2. the input[hashkey] e.g. 'rule_eth42'
 #  3. the short location [shortloc] value
 #  4. the switch name [switch] value
 #
 # If any of these keys are changed, an new DB record will be created,
 # with a new id number in the table 'probes'.  Its allowed to update the
 # other keys without changing the id.
 #
 # Required option, which proc file to read
 input[rule_eth42][procfile]  = /proc/net/xt_mpeg2ts/rule_test
 #
 # Required options that identifies this input
 input[rule_eth42][shortloc]  = alb
 input[rule_eth42][switch]    = albcs35
 #
 # Optional update-able config settings
 input[rule_eth42][description]= Main signal
 input[rule_eth42][distance]   = 1
 input[rule_eth42][location]   = Serverrum A
 input[rule_eth42][address]    = Herstedvang 8, 2620 Albertslund
 input[rule_eth42][switchport] = e0/0
 input[rule_eth42][switchtype] = Foundry FLS
 input[rule_eth42][input_ip]   = 192.168.16.42
 input[rule_eth42][input_dev]  = eth42
 input[rule_eth42][hidden]     = no

=head1 AUTHOR

Jesper Dangaard Brouer, E<lt>netoptimizer@brouer.comE<gt>.

=head2 Authors SVN version information

 $LastChangedDate$
 $Revision$
 $LastChangedBy$

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009-2013 by Jesper Dangaard Brouer.

This file is licensed under the terms of the GNU General Public
License 2.0. or newer. See <http://www.gnu.org/licenses/gpl-2.0.html>.

=cut
