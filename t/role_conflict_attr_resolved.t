use strict;
use Test::Lib;
use Test::Most;
use Minion;

{
    package Lawyer;

    our %__Meta = (
        role => 1,
        has  => { clients => { default => sub { [] } } } 
    );
}

{
    package Server;

    our %__Meta = (
        role => 1,
        has  => { clients => { default => sub { [] } } } 
    );

    sub serve {
        my ($self) = @_;
    }
}

{
    package BusyDudeImpl;

    our %__Meta = (
        has  => { clients => { default => sub { [] } } } 
    );
}

{
    package BusyDude;

    our %__Meta = (
        interface => [qw( serve )],
        roles => [qw( Lawyer Server )],
        implementation => 'BusyDudeImpl'
    );
    Minion->minionize;
}

package main;

ok(1, 'No role conflicts');

done_testing();