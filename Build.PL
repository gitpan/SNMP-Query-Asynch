use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    dist_name           => 'SNMP-Query-Asynch',
    dist_author         => 'Steve Scaffidi <sscaffidi@cpan.org>',
    dist_version_from   => 'lib/SNMP/Query/Asynch.pm',
    dist_abstract       => 'lib/SNMP/Query/Asynch.pm',

    module_name         => 'SNMP::Query::Asynch',
    license             => 'perl',

    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'SNMP-Query-Asynch-*' ],
    
    requires => {
        'perl' => 5.006,
        'SNMP' => 5.03, # Figure out how to exclude 5.04
        #'Other::Module' => '>= 1.2, != 1.5, < 2.0',
    },
    
    #create_readme      => 1, # TODO Must look this up again
    PL_files           => {},
    create_makefile_pl => 'passthrough',    
);

$builder->create_build_script();
