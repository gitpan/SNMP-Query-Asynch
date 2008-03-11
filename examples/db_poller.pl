#!perl

use strict;
use warnings;
use Data::Dumper;
use Carp;
use Parse::CSV;
use SNMP;

use SNMP::Query::Asynch;

#---------------------------------------------------------

my $csv_file = shift || die "Please specify a CSV file with SNMP host info!";

# The required columns in the loaded CSV file.
my @reqired_csv_cols = qw(HOSTIP COMMUNITY SNMPVER SNMPPORT);

my $max_inflight   = shift || 50;
my $num_cycles     = shift || 1;
my $master_timeout = 0;  # Set to number of seconds before
                         # all queries are terminated.
                         # 0 means no master timeout.

my $batch_size = 10; # Run a callback whenever this many 
                     # results have been returned

my @varbinds = qw(
        ifDescr ifInOctets ifOutOctets ifAlias ifType
        ifName  ifInErrors ifOutErrors ifSpeed
        ifAdminStatus      ifOperStatus
    );

#---------------------------------------------------------

# This probably isn't necessary, but it's the Right Thing To Do
# so the SNMP module won't be forced to do this internally instead.
# (the process is a lot more involved and careful in there, thus slower)
my $varlist = SNMP::VarList->new( map { [$_] } @varbinds );


# Load the CSV file then clean out any invalid data.
my @hosts = read_hosts_csv($csv_file, @reqired_csv_cols);
   @hosts = clean_hosts_data(\@hosts);





# This object encapsulates the desired queries to run.
my $query = SNMP::Query::AsynchMulti->new();



# We're going to install this callback to run before every query.
my $preop_callback = sub {
        warn  "+ IF/TI/GI: " . $query->current_in_flight()
            . "/"            . $query->this_run_issued()
            . "/"            . $query->grand_total_issued()
            . "\n"
        ;
    };


# We're going to install this callback to run after every query.
# Yes, I know I'm duplicating code. Would you rather I obfuscate it?
my $postop_callback = sub {
        warn  "- IF/TF/GF: " . $query->current_in_flight()
            . "/"            . $query->this_run_finished()
            . "/"            . $query->grand_total_finished()
            . "\n"
        ;
    };

# Add a query operation for each host to the $query object.
foreach my $host (@hosts)
{

    $query->add_getbulk({
            # Params concerning the SNMP Session
            DestHost     => $host->{HOSTIP},
            Community    => $host->{COMMUNITY},
            Version      => $host->{SNMPVER},
            RemotePort   => $host->{SNMPPORT},
            #Timeout      => $host->{SNMP_TIMEOUT},
            #Retries      => $host->{SNMP_RETRIES},

            # Params concerning the type of query operation
            MaxRepeaters => 20,
            NonRepeaters => 0,

            # The varbinds to be operated on
            VarBinds     => $varlist,

            # Callbacks before and after this query op.
            PreCallback  => $preop_callback,  # Do this before the query 
            PostCallback => $postop_callback, # Do this after the query
        });

    warn "Added query to: $host->{HOSTIP}\n";
}


# This will be registered as a callback that is called after a 'batch'
# of queries has completed.
my $batch_callback = sub { 
        my $results_ref = $query->get_results_ref();
        my @results; 
        push @results, pop @$results_ref 
            while scalar @$results_ref;
        print "BATCH RESULTS\n" . Dumper \@results;
    };


# Run all the added queries with up to $max_inflight
# asynchronous operations in-flight at any time.
# Lather, rinse, repeat for $num_cycles.
warn "Beginning polling cycle\n";

foreach my $iter ( 1..$num_cycles ) 
{
    sleep 30 unless $iter == 1;

    # Randomize order of queries...(not yet implemented)
    # I want this feature because I will be repeatedly polling these same 
    # devices. Using the same order every time can actually cause 'phantom'
    # capacity issues, usually caused *by* the polling. Randomizing helps
    # smooth out any potiential impact the polling order may otherwise have.
    warn "Shuffling queries (not yet implemented)\n";
    $query->shuffle(); 

    # Execute the queries that were added. See the POD for more info 
    # on the parameters given here.
    my $results = $query->execute({ 
            InFlight      => $max_inflight,
            MasterTimeout => $master_timeout,
            BatchSize     => $batch_size,
            BatchCallback => $batch_callback,
        });

    # In this case, the $batch_callback should have taken care 
    # of all the results. Therefore, this is a sanity check to 
    # make sure it worked properly.
    print Dumper $results;    
}

# TODO I probably need some error-indicator methods for AsynchMulti.
# Something that pushes error status messages onto a stack for later use.

exit;

#---------------------------------------------------------






# Read in the CSV file.
sub read_hosts_csv {
    my $file = shift;
    my @required_fields = @_;

    # Parse entries from a CSV file into hashes hash
    my $csv_parser = Parse::CSV->new(
        file   => $file,
        fields => 'auto',  # Use the first line as column headers,
                           # which become the hash keys.
    );

    my @node_cfg; # Return a reference to this
    my $line_num = 0;
    while ( my $line = $csv_parser->fetch() ) {
        $line_num++;
        my $error_flag = 0;
        foreach my $field (@required_fields) {
            if ( ! exists $line->{$field} ) {
                $error_flag = 1;
                carp "Missing field [$field] on line [$line_num] in CSV file [$file]";
            }
        }
        croak "Terminating due to errors on line [$line_num] in CSV file [$file]"
            if $error_flag;

        push @node_cfg, $line;
    }

    if ( $csv_parser->errstr() ) {
        croak "Fatal error parsing [$file]: " . $csv_parser->errstr();
    }

    return @node_cfg;
}

sub clean_hosts_data {
    my $hosts_data = shift;
    my @clean_hosts;
    foreach my $host (@$hosts_data) {
        # Maybe put in a loop to scrub leading and trailing 
        # whitespace from each field? Yeah, I know. map in 
        # void context is the devil's work, yadda, yadda.
        map { s/^\s*|\s*$//g } values %$host;

        if (
               $host->{SNMPVER}  == 2 #=~ /^1|2c?|3$/
            && $host->{SNMPPORT} =~ /^\d+$/
            && $host->{HOSTIP}   =~ /^(?:\d{1,3}\.){3}\d{1,3}$/  # Flawed, but Good Enough.
            && $host->{COMMUNITY}
           )
        {
            push @clean_hosts, $host;
        }
        else
        {
            warn "Invalid host data - skipping:\n"
               . "  " . Dumper($host) . "\n";
        }
    }
    return @clean_hosts;
}

1;
__END__
