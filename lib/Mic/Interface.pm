package Mic::Interface;
use strict;

sub import {
    my ($class, %arg) = @_;

    my $caller_pkg = (caller)[0];
    $Mic::Spec_for{$caller_pkg}{interface} = \%arg;
    strict->import();
}

1;

__END__

=head1 NAME

Mic::Interface

=head1 SYNOPSIS

    package Example::Usage::SetInterface;

    use Mic::Interface
        object => {
            add => {},
            has => {},
        },
        class => { new => {} }
    ;

    1;

=head1 DESCRIPTION

Defines a reusable interface.

See L<Mic/Interface Sharing> for an example.
