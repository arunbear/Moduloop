package Minion;

use strict;
use 5.008_005;
use Carp;
use Hash::Util qw( lock_keys );
use Module::Runtime qw( require_module );
use Package::Stash;

our $VERSION = 0.000_001;

my $Class_count = 0;

sub minionize {
    my (undef, $spec) = @_;

    my $cls_stash;
    if ( ! $spec ) {
        my $caller_pkg = (caller)[0];
        $cls_stash = Package::Stash->new($caller_pkg);
        $spec  = $cls_stash->get_symbol('%__Meta');
        $spec->{name} = $caller_pkg;
    }
    $spec->{name} ||= "Minion::Class_${\ ++$Class_count }";
    $cls_stash    ||= Package::Stash->new($spec->{name});
    
    my $obj_stash;

    if ( $spec->{implementation} && ! ref $spec->{implementation} ) {
        my $pkg = $spec->{implementation};
        $obj_stash = _get_stash($pkg);

        $spec->{implementation} = { 
            package => $pkg, 
            methods => $obj_stash->get_all_symbols('CODE'),
            has     => {
                %{ $obj_stash->get_symbol('%__Meta')->{has} || { } },
            },
        };
        for (keys %{ $spec->{implementation}{methods} }) {
            $obj_stash->remove_symbol("&$_"); # repopulated later per interface
        }        
    }
    else {
        $obj_stash = Package::Stash->new("$spec->{name}::__Minion");
    }
    
    my $class_meta = $cls_stash->get_symbol('%__Meta') || {};
    $spec->{implementation}{has} = {
        %{ $spec->{implementation}{has} || { } },
        %{ $class_meta->{has} || { } },
    };
    _compose_roles($spec);

    my $private_stash = Package::Stash->new("$spec->{name}::__Private");
    _add_object_maker($spec, $cls_stash, $private_stash, $obj_stash);
    _add_class_methods($spec, $cls_stash);
    _add_methods($spec, $obj_stash, $private_stash);
    _check_role_requirements($spec);
    _check_interface($spec);
    return $spec->{name};
}

sub _compose_roles {
    my ($spec, $roles, $from_role) = @_;
    
    $roles ||= $spec->{roles};
    $from_role ||= {};
    
    for my $role ( @{ $roles } ) {
        
        my $stash = _get_stash($role);
        my $meta = $stash->get_symbol('%__Meta');
        assert($meta->{role}, "$role is not a role");
        $spec->{required}{$role} = $meta->{requires};
        _compose_roles($spec, $meta->{roles} || [], $from_role);
        
        _add_role_items($spec, $from_role, $role, $meta->{has}, 'has');
        _add_role_items($spec, $from_role, $role, $stash->get_all_symbols('CODE'), 'methods');
    }
}

sub _check_role_requirements {
    my ($spec) = @_;

    foreach my $role ( keys %{ $spec->{required} } ) {

        my $required = $spec->{required}{$role};

        foreach my $name ( @{ $required->{methods} } ) {
            defined $spec->{implementation}{methods}{$name}
              or confess "Method '$name', required by role $role, is not implemented.";
        }
        foreach my $name ( @{ $required->{attributes} } ) {
            defined $spec->{implementation}{has}{$name}
              or confess "Attribute '$name', required by role $role, is not defined.";
        }
    }
}

sub _check_interface {
    my ($spec) = @_;
    my $count = 0;
    foreach my $method ( @{ $spec->{interface} } ) {
        defined $spec->{implementation}{methods}{$method}
          or confess "Interface method '$method' is not implemented.";
        ++$count;
    }
    $count > 0 or confess "Cannot have an empty interface.";
}

sub _get_stash {
    my $pkg = shift;

    my $stash = Package::Stash->new($pkg); # allow for inlined pkg

    if ( ! $stash->has_symbol('%__Meta') ) {
        require_module($pkg);
        $stash = Package::Stash->new($pkg);
    }
    return $stash;
}

sub _add_role_items {
    my ($spec, $from_role, $role, $item, $type) = @_;

    for my $name ( keys %$item ) {
        if (my $other_role = $from_role->{$name}) {
            confess "Cannot have '$name' in both $role and $other_role";
        }
        else{
            if ( ! $spec->{implementation}{$type}{$name} ) {
                $spec->{implementation}{$type}{$name} = $item->{$name};
                $from_role->{$name} = $role;
            }
        }            
    }
}

sub _add_object_maker {
    my ($spec, $stash, $private_stash, $obj_stash) = @_;

    $stash->add_symbol("&__new__", sub {
        shift;
        my %obj = ('!' => $private_stash->name);

        while ( my ($attr, $meta) = each %{ $spec->{implementation}{has} } ) {
            $obj{"__$attr"} = ref $meta->{default} eq 'CODE'
              ? $meta->{default}->()
              : $meta->{default};
        }
        bless \ %obj => $obj_stash->name;            
        lock_keys(%obj);
        return \ %obj;
    });
}

sub _add_class_methods {
    my ($spec, $stash) = @_;

    if ( ! exists $spec->{class_methods}{new} ) {
        $spec->{class_methods}{new} = sub {
            my $class = shift;
            my ($arg);

            if ( scalar @_ == 1 ) {
                $arg = shift;
            }
            elsif ( scalar @_ > 1 ) {
                $arg = { @_ };
            }
            my $obj = $class->__new__;
            for my $name ( keys %{ $spec->{has} } ) {
                assert(defined $arg->{$name}, "Param '$name' was not provided.");
                my $meta = $spec->{has}{$name};

                while ( my ($desc, $code) = each %{ $meta->{assert} || { } } ) {
                    assert($code->($arg->{$name}),  "Attribute '$name' is not $desc");
                }
                $obj->{"__$name"} = $arg->{$name};
            }
            return $obj;
        };
    }
    foreach my $sub ( keys %{ $spec->{class_methods} } ) {
        $stash->add_symbol("&$sub", $spec->{class_methods}{$sub});
    }
}

sub _add_methods {
    my ($spec, $stash, $private_stash) = @_;

    my %in_interface = map { $_ => 1 } @{ $spec->{interface} };

    while ( my ($name, $meta) = each %{ $spec->{implementation}{has} } ) {
        next unless $in_interface{$name};

        if ( $meta->{reader} ) {
            my $name = $meta->{reader} == 1 ? $name : $meta->{reader};
            $spec->{implementation}{methods}{$name} = sub { $_[0]->{"__$name"} };
        }
    }

    while ( my ($name, $sub) = each %{ $spec->{implementation}{methods} } ) {
        my $use_stash = $in_interface{$name} ? $stash : $private_stash;
        $use_stash->add_symbol("&$name", $sub);
    }
}

sub assert {
    my ($val, $desc) = @_;
    $val or confess "Assertion failed: $desc";
}

1;
__END__

=encoding utf-8

=head1 NAME

Minion - build your minions.

=head1 SYNOPSIS

  use Minion;

  my %Class = (
      name => 'Counter',
      has  => {
          count => { default => 0 },
      }, 
      methods => {
          next => sub {
              my ($self) = @_;

              $self->{count}++;
          }
      },
  );

  Minion->minionize(\ %Class);
  my $counter = Counter->new;

  ok $counter->next == 0;
  ok $counter->next == 1;
  ok $counter->next == 2;

=head1 DESCRIPTION

Minion is library for building minions.

=head1 AUTHOR

Arun Prasaad E<lt>arunbear@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2014- Arun Prasaad

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the terms of the GPL v3.

=head1 SEE ALSO

=cut
