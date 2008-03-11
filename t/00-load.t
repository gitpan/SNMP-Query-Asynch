#!perl

use Test::More tests => 1;

BEGIN {
	use_ok( 'SNMP::Query::Asynch' );
}

diag( "Testing SNMP::Query::Asynch $SNMP::Query::Asynch::VERSION, Perl $], $^X" );
