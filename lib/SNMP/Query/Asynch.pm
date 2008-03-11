# -*- mode: perl -*-
#
# Copyright (c) 2008 Stephen R. Scaffidi <sscaffidi@cpan.org>
# All rights reserved.
#
# This program is free software; you may redistribute it and/or modify it
# under the same terms as Perl itself.
#
# Current RCS Info:
#
#       $Id: Asynch.pm 36 2008-03-11 16:42:51Z hercynium $
#  $HeadURL: https://rtg-utilities.svn.sourceforge.net/svnroot/rtg-utilities/SNMP-Asynch/lib/SNMP/Query/Asynch.pm $
#     $Date: 2008-03-11 12:42:51 -0400 (Tue, 11 Mar 2008) $
#   $Author: hercynium $
# $Revision: 36 $
#
package SNMP::Query::Asynch;

# Pragmas
use strict;
use warnings;

# Standard
use Carp;

# Cpan
use SNMP;

# See chap 17, pg. 404, PBP (Conway 2005)
# use version; our $VERSION = qv('0.1_32');
use version; our $VERSION = qv(sprintf "0.1_%d", q$Revision: 36 $ =~ /: (\d+)/);


# This comes in handy so we don't pass bogus
# parameters to SNMP::Session->new()
use vars qw(@valid_sess_params);
@valid_sess_params = qw(
      DestHost
      Community
      Version
      RemotePort
      Timeout
      Retries
      RetryNoSuch
      SecName
      SecLevel
      SecEngineId
      ContextEngineId
      Context
      AuthProto
      AuthPass
      PrivProto
      PrivPass
      AuthMasterKey
      PrivMasterKey
      AuthLocalizedKey
      PrivLocalizedKey
      VarFormats
      TypeFormats
      UseLongNames
      UseSprintValue
      UseEnums
      UseNumeric
      BestGuess
      NonIncreasing
    );

#----------------------------------------------------------
# Constructor
sub new {
    my $class = shift;
    my $self = bless {}, $class;

    $self->{query_stack}          = [];
    $self->{results}              = [];
    $self->{max_in_flight}        = 10;
    $self->{current_in_flight}    = 0;

    $self->{this_run_issued}      = 0;
    $self->{this_run_finished}    = 0;

    $self->{grand_total_issued}   = 0;
    $self->{grand_total_finished} = 0;

    return $self;
}

#---------------------------------------------------------

# Verifies that the named parameter is a subref
sub _check_param_callback {
    my $self       = shift;
    my $param_name = shift;    # string, hash key
    my $params     = shift;    # hashref
    return 1 unless exists $params->{$param_name};
    croak "Bad parameter for [$param_name] - not a CODE ref"
      if ref $params->{$param_name} ne 'CODE';
    return 1;
}

#---------------------------------------------------------

# TODO Fill in the code and use in the add_XXX() or _make_XXX_query() methods
# Verifies that the named parameter is something the SNMP
# module can use as a VarBind or VarBindList.
sub _check_param_varbinds {
    my $self       = shift;
    my $param_name = shift;    # string, hash key
    my $params     = shift;    # hashref
    return;
}

#---------------------------------------------------------

sub add_getbulk {
    my $self   = shift;
    my $params = shift;

    my $query_stack = $self->{query_stack};

    # These are required for all query ops so make sure they're present.
    my $varbinds = $params->{VarBinds}
      || croak "Bad or missing parameter [VarBinds]";
    my $query_type = $params->{QueryType}
      || croak "Bad or missing parameter [QueryType]";

    # Make sure our callback params are valid.
    $self->_check_param_callback( 'PreCallback',   $params );
    $self->_check_param_callback( 'PostCallback',  $params );

    if ( $query_type eq 'getbulk' ) {
        my $query       = $self->_make_getbulk_query($params);
        my $query_stack = $self->{query_stack};
        push @$query_stack, $query;
    }
    else {
        croak "Attempt to add using unknown query type: $query_type\n";
    }

    return;
}


#---------------------------------------------------------

# NOTE This method has gotten long and complex. 
# TODO Refactor, but think carefully. 
#
# I see a couple of places where I can create closure-based memory leaks, and
# knowing myself, I could end up doing it inadvertenly at any time. It's code
# like this where some more experienced hackers could help me *big time*
sub _make_getbulk_query {
    my $self = shift;
    my $query_info = shift;

    # These params are required for a getbulk query op.
    my $non_repeaters =
      exists $query_info->{NonRepeaters}
      ? $query_info->{NonRepeaters}
      : croak "Bad or missing parameter [NonRepeaters]";
    my $max_repeaters =
      exists $query_info->{MaxRepeaters}
      ? $query_info->{MaxRepeaters}
      : croak "Bad or missing parameter [MaxRepeaters]";

    # Currently, these are validated in the add() method, so no need here.
    my $preop_callback  = $query_info->{PreCallback};
    my $postop_callback = $query_info->{PostCallback};
    my $batch_callback  = $query_info->{BatchCallback};

    # TODO I may want to add a method to validate
    # and/or transform the VarBinds parameter
    my $varbinds = $query_info->{VarBinds};

    # Parse out the parameters for creating the session.
    # I really think I should be validating them better here...
    # Maybe I need a separate subroutine...
    # TODO write the routine described above.
    my %sess_params;
    $sess_params{$_} = $query_info->{$_}
      for grep { exists $query_info->{$_} } @valid_sess_params;

    my $batch_size = $query_info->{BatchSize};

    return sub {

        # I wonder if this should be before or after the counter increments?
        $preop_callback->() if $preop_callback;

        $self->{current_in_flight}++;
        $self->{this_run_issued}++;
        $self->{grand_total_issued}++;

        my $callback = sub {

            my $bulkwalk_results = shift;

            # Store the results and info about the query for later...
            push @{ $self->{results} }, $query_info, $bulkwalk_results;

            # NOTE should I do this callback here, or somewhere else? hmmmmm....
            $postop_callback->() if $postop_callback;
            
            # Am I introducing a bug with the increments 
            # here and the SNMP::finish() down below?
            $self->{current_in_flight}--;
            $self->{this_run_finished}++;
            $self->{grand_total_finished}++;

            $self->{BatchCallback}()
              if $self->{BatchSize}
                  && ( $self->{this_run_finished} % $self->{BatchSize} == 0 );

            if ( scalar @{ $self->{query_stack} } ) {
                my $next_query = pop @{ $self->{query_stack} };
                return $next_query->();
            }
            $self->{current_in_flight} <= 0 ? return SNMP::finish() : return 1;
        };

        my $sess = SNMP::Session->new(%sess_params);

        my $operation_id = $sess->bulkwalk( $non_repeaters, $max_repeaters,
                                            $varbinds, [$callback] );
                                            
        # Why, yes. I am being sneaky here. Since $query_info is referenced
        # within the $callback closure, any data stored in the hash it points
        # to should be available, regardless of whether is was stored before 
        # or after the closure definition.
        $query_info->{OperationId} = $operation_id;
        
        return; # No need to return anything, AFAICT.
    };
}

#---------------------------------------------------------



sub current_in_flight    { return shift->{current_in_flight} }
sub this_run_issued      { return shift->{this_run_issued} }
sub this_run_finished    { return shift->{this_run_finished} }
sub grand_total_issued   { return shift->{grand_total_issued} }
sub grand_total_finished { return shift->{grand_total_finished} }

sub shuffle { } # TODO Implement with List::Util::shuffle

#---------------------------------------------------------

sub execute {
    my $self   = shift;
    my $params = shift;

    # The KeepLast option can come in handy if, for example, another
    # thread or process is working on the contents of the results
    # array from a previous execution and may not finish before the
    # next execution.
    @{ $self->{results} } = ()
      unless (

        # I'll make my OWN idioms from now on, HAHA! (You can explicitly
        # set keeplast or it will use the object's default)
        defined $params->{KeepLast} ? $params->{KeepLast} : $self->{KeepLast}
      );

    # Install 'batch' callback if applicable...
    $self->{BatchCallback} = $params->{BatchCallback}
        if $self->_check_param_callback( 'BatchCallback', $params );
    $self->{BatchSize} = $params->{BatchSize};
    

    # Determine our maximum concurrency level for this run
    my $max_in_flight = $params->{InFlight} || $self->{max_in_flight};

    # Make a copy of the stack in case we want to run the same query
    my $query_stack_ref  = $self->{query_stack};
    my @query_stack_copy = @{ $self->{query_stack} };

    # Set some counters
    $self->{current_in_flight} = 0;
    $self->{this_run_issued}   = 0;
    $self->{this_run_finished} = 0;

    # Begin issuing operations
    while ( scalar @$query_stack_ref ) {
        my $query = pop @$query_stack_ref;
        $query->();
        last if $self->{current_in_flight} >= $max_in_flight;
    }

    # Wait for the ops to complete, or time-out (if specified)
    $params->{MasterTimeout}
      ? SNMP::MainLoop( $params->{MasterTimeout}, &SNMP::finish() )
      : SNMP::MainLoop();

    # Reset the stack for the next run.
    $self->{query_stack} = \@query_stack_copy;

    return $self->get_results_ref();
}

#---------------------------------------------------------

#  Returns a reference to the results array from executing the query.
sub get_results_ref {
    return shift->{results};
}

1;
__END__

=pod

=head1 NAME

SNMP::Query::Asynch - Fast asynchronous execution of batches of SNMP queries

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

 use SNMP::Query::Asynch;
  
 my @varbinds = qw(
        ifDescr ifInOctets ifOutOctets ifAlias ifType
        ifName  ifInErrors ifOutErrors ifSpeed
        ifAdminStatus      ifOperStatus
    );
 
 my $query = SNMP::Query::Asynch->new();
 
 # You should create and populate @hosts to make this synposis code work. 
 # It's an AoH, fairly simple. For example...
 my @hosts = create_hosts_array('snmp_hosts.csv');
 
 foreach my $host (@hosts) {
     
     # Add a getbulk operation to the queue.
     $query->add_getbulk({            
             # Params passed to directly to SNMP::Session->new()
             DestHost     => $host->{HOSTIP},
             Community    => $host->{COMMUNITY},
             Version      => $host->{SNMPVER},  # getbulk only supports 2 or 3.

             # Params concerning the type of query operation
             # See POD for SNMP::Session->getbulk() in this case.
             MaxRepeaters => 20,
             NonRepeaters => 0, 
 
             # The varbinds to be operated on - can be a reference to anything 
             # supported by the corresponding query operation in SNMP::Session.
             VarBinds     => \@varbinds, 
         });
     
 }
 
 # Execute the queries that were added, get a reference to the results array.
 my $results = $query->execute({ 
         InFlight      => 50, # Simultaneous operations
         MasterTimeout => 60, # Seconds until unfinished operations are aborted.
     });
 
 # See what the results look like.
 use Data::Dumper; 
 print Dumper $results;


=head1 DESCRIPTION

This module allows for a fairly simple, streamlined means of executing large
numbers of SNMP operations as fast as your systems can handle. It extensively
uses net-snmp's asynchronous operation interfaces and callbacks to keep as much
data flowing as you need. 

Perl's support of closures and anonymous subroutines provide the means for 
sophisticated, elegant control of query operations before and after execution. 
There are also facilities to install callbacks that are run after pre-set 
numbers (batches) of operations are completed . 

These callbacks can be used to log progress, update the user, transfer results
from memory to disk (or even another thread or process!) or anything you can
think of! If there's some feature you desire, do not hesitate to ask me!!!

Please be aware - my primary design concern is speed and flexibility. I have 
certain non-scientific, subjective benchmarks I use to decide if some 
modification is worth-while, but so far the design of the internals of this 
module has lent itself to feature additions and enhancements very well. 

=head1 SUBROUTINES/METHODS

=head3 new

Constructs a new query object with an empty queue.

=head2 Query Operation Addition Methods

In order to build a queue of query operations, you would repeatedly call one
or more of these methods below to add an operation to the queue.

In addition to the parameters described for each method, they all require
parameters that are passed directly to SNMP::Session->new() at execution time.
However, those parameters are somewhat validated when the methods are called, 
to try to make debugging easier for code using this module.

See the discussion below on "Required Parameters SNMP::Session->new()" for more 
information.

=head3 add_getbulk

Adds a getbulk query operation to the queue.

=head3 add_gettable - NOT YET IMPLEMENTED

Adds a gettable query operation to the queue.

=head3 add_get - NOT YET IMPLEMENTED

Adds a get query operation to the queue.

=head3 add_fget - NOT YET IMPLEMENTED

Adds an fget query operation to the queue.

=head3 add_bulkwalk - NOT YET IMPLEMENTED

Adds a bulkwalk query operation to the queue.

=head3 add_getnext - NOT YET IMPLEMENTED

Adds a getnext query operation to the queue.

=head3 add_fgetnext - NOT YET IMPLEMENTED

Adds an fgetnext query operation to the queue.

=head3 add_set - NOT YET IMPLEMENTED

Adds a set query operation to the queue.

=head3 Required Parameters SNMP::Session->new()

Each query operation in the queue requires that a SNMP::Session object is 
constructed, but you can't pre-construct the SNMP::Session objects and pass 
those in because any more than 1023 of these in memory at a time will crash the 
program.

We get around this limitation by constructing only as many sessions as are 
needed to support the in-flight operations, and no more. To do that at execution 
time requires that the user specify the SNMP::Session->new() parameters whenever
they add a new query operation using the methods below.

Therefore, I have listed below the parameters for SNMP::Session->new() that will
be accepted by each of the query operation additions methods.

Because of these limitations, this module is tightly coupled with the L<SNMP> 
module. There's really no other way to go about it, at least none that I can 
think of that doesn't unacceptably degrade the execution speed.

=over 4

=item * DestHost

=item * Community

=item * Version

=item * RemotePort

=item * Timeout

=item * Retries

=item * RetryNoSuch

=item * SecName

=item * SecLevel

=item * SecEngineId

=item * ContextEngineId

=item * Context

=item * AuthProto

=item * AuthPass

=item * PrivProto

=item * PrivPass

=item * AuthMasterKey

=item * PrivMasterKey

=item * AuthLocalizedKey

=item * PrivLocalizedKey

=item * VarFormats

=item * TypeFormats

=item * UseLongNames

=item * UseSprintValue

=item * UseEnums

=item * UseNumeric

=item * BestGuess

=item * NonIncreasing

=back

=head2 execute

Executes all operations in the queue.

=head2 shuffle

Shuffles the operations in the queue so they are executed in random order.

=head2 current_in_flight

Returns the number of operations currently issued which have not yet 
been completed.

Please note: completed means that the operation was issued and either results 
data or an error condition were recieved. If the operation was interrupted 
before that happens, then is not counted as completed. This typically only 
happens when the call to execute() was interrupted by a fatal error or the
query-object's master timeout was exceeded.

=head2 this_run_issued

Returns the number of operations that have been issued during the current 
execute() call. If called after execute() has completed, returns the number 
issued during the most recent execute() call.

Each call to execute() resets this value to zero.

=head2 this_run_finished

Returns the number of operations that have been completed during the current 
execute() call. If called after execute() has completed, returns the number 
completed during the most recent execute() call.

Each call to execute() resets this value to zero.

=head2 grand_total_issued

Returns the number of operations that have been issued during all calls to
execute() since the query object was created. This value is *never* reset.

=head2 grand_total_finished

Returns the number of operations that have been completed during all calls to
execute() since the query object was created. This value is *never* reset.

=head2 get_results_ref

Returns a reference to the query object's internal results array.

NOTE: Yes, I *know* that providing access to an object's internal data is poor 
OO design, but it gets the job done right now. I do plan on converting the 
results array into it's own type of object with OO-kosher semantics, but only 
if that does not substantially impact overall speed.

That said, use this method with caution because in the future it will likely 
be changed to return something completely different than an array-ref or maybe
even be removed and replaced with a different method. I may also have a moment
of insanity and make the results-object tied so as to look like an array. But
I doubt it unless people ask for it enough.

=head1 EXPORTS

Nothing.

=head1 SEE ALSO

SNMP
SNMP::Effective
SNMP::Multi
MRTG
RTG
YATG

=head1 AUTHOR

Steve Scaffidi, C<< <sscaffidi at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-snmp-query-asynch at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=SNMP-Query-Asynch>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc SNMP::Query::Asynch

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/SNMP-Query-Asynch>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/SNMP-Query-Asynch>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=SNMP-Query-Asynch>

=item * Search CPAN

L<http://search.cpan.org/dist/SNMP-Query-Asynch>

=back

=head1 ACKNOWLEDGEMENTS

=head1 DEPENDENCIES

=head1 BUGS AND LIMITATIONS

=head1 INCOMPATIBILITIES

=head1 LICENSE AND COPYRIGHT

Copyright 2008 Steve Scaffidi, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut


