use strict;
use warnings;
use Module::Build;

# TODO need to fix Build dist on windows.
# Luckily, this works: Build dist --tar C:\cygwin\bin\tar.exe --gzip C:\cygwin\bin\gzip.exe

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
        'perl'    => 5.006,
        'version' => 0,
        'SNMP'    => '>= 5.0301, != 5.0401',
    },
    
    #create_readme      => 1, # TODO Must look this up again
    PL_files           => {},
    create_makefile_pl => 'passthrough',    
);

$builder->create_build_script();
