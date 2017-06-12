package Moduloop::Assembler;

use strict;
use Class::Method::Modifiers qw(install_modifier);
use Carp;
use Carp::Assert::More;
use Hash::Util qw( lock_keys );
use List::MoreUtils qw( any uniq );
use Module::Runtime qw( require_module );
use Params::Validate qw(:all);
use Package::Stash;
use Scalar::Util qw( reftype );
use Storable qw( dclone );
use Sub::Name;

use Exception::Class (
    'Moduloop::Error::AssertionFailure' => { alias => 'assert_failed' },
    'Moduloop::Error::MethodDeclaration',
    'Moduloop::Error::TraitConflict',
    'Moduloop::Error::ContractViolation',
);
use Moduloop::_Guts;

sub new {
    my ($class, %arg) = @_;

    my $obj = { 
        spec => $arg{-spec} || {},
    };
    bless $obj;
}

sub load_spec_from {
    my ($self, $package) = @_; 

    my $spec = $self->{spec};
    my $cls_stash = Package::Stash->new($package);

    $spec = { %$spec, %{ $cls_stash->get_symbol('%__meta__') || {} } };
    $spec->{name} = $package;
    $self->{cls_stash} = $cls_stash;
    $self->{spec} = $spec;
    return $spec;
}

sub assemble {
    my ($self) = @_;

    my $spec = $self->{spec};
    $self->{cls_stash} ||= Package::Stash->new($spec->{name});

    my $obj_stash;

    my $pkg = $Moduloop::Bound_implementation_of{ $spec->{name} } || $spec->{implementation};
    $pkg ne $spec->{name}
      or confess "$spec->{name} cannot be its own implementation.";
    my $stash = _get_stash($pkg);

    my $meta = $stash->get_symbol('%__meta__');

    $spec->{implementation} = {
        package => $pkg,
        methods => $stash->get_all_symbols('CODE'),
        has     => {
            %{ $meta->{has} || { } },
        },
        forwards => $meta->{forwards},
        traits   => $meta->{traits},
        arrayimp => $meta->{arrayimp},
        slot_offset => $meta->{slot_offset},
    };
    my $is_semiprivate = _interface($meta, 'semiprivate');

    foreach my $sub ( keys %{ $spec->{implementation}{methods} } ) {
        if ( $is_semiprivate->{$sub} ) {
            $spec->{implementation}{semiprivate}{$sub} = delete $spec->{implementation}{methods}{$sub};
        }
    }
    $obj_stash = Package::Stash->new("$spec->{implementation}{package}::__Assembled");

    _prep_interface($spec);
    _compose_traitlibs($spec);

    my $private_stash = Package::Stash->new("$spec->{name}::__Private");
    my $cls_stash = $self->{cls_stash};
    $cls_stash->add_symbol('$__Obj_pkg', $obj_stash->name);
    $cls_stash->add_symbol('$__Private_pkg', $private_stash->name);
    $cls_stash->add_symbol('%__meta__', $spec) if @_ > 0;

    _add_methods($spec, $obj_stash, $private_stash);
    _make_builder_class($spec);
    _add_class_methods($spec, $cls_stash);
    _check_traitlib_requirements($spec);
    _check_interface($spec);
    return $spec->{name};
}

sub _get_stash {
    my $pkg = shift;

    my $stash = Package::Stash->new($pkg); # allow for inlined pkg

    if ( ! $stash->has_symbol('%__meta__') ) {
        require_module($pkg);
        $stash = Package::Stash->new($pkg);
    }
    if ( ! $stash->has_symbol('%__meta__') ) {
        confess "Package $pkg has no %__meta__";
    }
    return $stash;
}

sub _interface {
    my ($spec, $type) = @_;

    $type ||= 'interface';
    my %must_allow = (
        interface   => [qw( AUTOLOAD can DOES DESTROY )],
        semiprivate => [qw( BUILD )],
    );
    if ( $type eq 'interface' && ref $spec->{$type} eq 'HASH') {
        $spec->{pre_and_post_conds} = $spec->{$type};
        $spec->{$type} = [ keys %{ $spec->{$type}{object} } ];
    }
    return { map { $_ => 1 } @{ $spec->{$type} }, @{ $must_allow{$type} } };
}

sub _prep_interface {
    my ($spec) = @_;

    return if ref $spec->{interface};
    my $count = 0;
    {

        if (my $methods = $Moduloop::Spec_for{ $spec->{interface} }{interface}) {
            $spec->{interface_name} = $spec->{interface};
            $spec->{interface} = $methods;
        }
        else {
            $count > 0
              and confess "Invalid interface: $spec->{interface}";
            require_module($spec->{interface});
            $count++;
            redo;
        }
    }
}

sub _compose_traitlibs {
    my ($spec, $traitlibs, $from_traitlib) = @_;

    if ( ! $traitlibs ) {
        $traitlibs = $spec->{implementation}{traits};
    }

    $from_traitlib ||= {};
    for my $traitlib ( keys %{ $traitlibs } ) {

        if ( $spec->{composed_traitlib}{$traitlib} ) {
            confess "Cannot compose traitlib '$traitlib' twice";
        }
        else {
            $spec->{composed_traitlib}{$traitlib}++;
        }

        my ($meta, $code_for) = _load_traitlib($traitlib);
        my $wanted_method = { map { $_ => 1 } @{ $traitlibs->{$traitlib}{methods} } };
        my $wanted_attr = { map { $_ => 1 } @{ $traitlibs->{$traitlib}{attributes} } };
        my $has = {
            map { $_ => $meta->{has}{$_} }
            grep { $wanted_attr->{$_} }
            keys %{ $meta->{has} },
        };
        $code_for = {
            map { $_ => $code_for->{$_} }
            grep { $wanted_method->{$_} }
            keys %$code_for,
        };
        $spec->{required_by_traitlib}{$traitlib} = $meta->{requires};
        _compose_traitlibs($spec, $meta->{traits} || {}, $from_traitlib);

        _add_traitlib_items($spec, $from_traitlib, $traitlib, $has);
        _add_traitlib_methods($spec, $from_traitlib, $traitlib, $meta, $code_for);
        _add_traitlib_forwards($spec, $from_traitlib, $traitlib, $meta);
    }
}

sub _load_traitlib {
    my ($traitlib) = @_;

    my $stash  = _get_stash($traitlib);
    my $meta   = $stash->get_symbol('%__meta__');
    $meta->{traitlib}
      or confess "$traitlib is not a traitlib";

    my $method = $stash->get_all_symbols('CODE');
    return ($meta, $method);
}

sub _check_traitlib_requirements {
    my ($spec, $type) = @_;

    $type ||= 'required_by_traitlib';
    my $required_by = do { my $tmp = $type; $tmp =~ s/_/ /g; $tmp };

    foreach my $traitlib ( keys %{ $spec->{$type} } ) {

        my $required = $spec->{$type}{$traitlib};

        foreach my $name ( @{ $required->{methods} } ) {

            unless (   defined $spec->{implementation}{methods}{$name}
                    || defined $spec->{implementation}{semiprivate}{$name}
                   ) {
                confess "Method '$name', $required_by $traitlib, is not implemented.";
            }
        }
        foreach my $name ( @{ $required->{attributes} } ) {
            defined $spec->{implementation}{has}{$name}
              or confess "Attribute '$name', $required_by $traitlib, is not defined.";
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

sub _add_methods {
    my ($spec, $stash, $private_stash) = @_;

    my $in_interface = _interface($spec);

    $spec->{implementation}{semiprivate}{ASSERT} = sub {
        shift;
        my ($slot, $val) = @_;

        my $slot_spec = $spec->{implementation}{has}{$slot}
          or return;
        return unless exists $slot_spec->{callbacks};

        validate(@_, {
            $slot => $slot_spec,
        });
    };
    $spec->{implementation}{methods}{DOES} = sub {
        my ($self, $r) = @_;

        if ( ! $r ) {
            my @items = (( $spec->{interface_name} ? $spec->{interface_name} : () ),
                          $spec->{name}, sort keys %{ $spec->{composed_traitlib} });
            return unless defined wantarray;
            return wantarray ? @items : \@items;
        }

        return    $r eq $spec->{interface_name}
               || $spec->{name} eq $r
               || $spec->{composed_traitlib}{$r}
               || $self->isa($r);
    };
    $spec->{implementation}{methods}{can} = sub {
        my ($self, $f) = @_;

        if ( ! $f ) {
            my @items = sort @{ $spec->{interface} };
            return unless defined wantarray;
            return wantarray ? @items : \@items;
        }
        return UNIVERSAL::can($self, $f);
    };
    _add_autoload($spec, $stash);

    while ( my ($name, $meta) = each %{ $spec->{implementation}{has} } ) {

        if ( !  $spec->{implementation}{methods}{$name}
             && $meta->{reader}
             && $in_interface->{ $meta->{reader} } ) {

            my $obfu_name = Moduloop::_Guts::obfu_name($name, $spec);
            $spec->{implementation}{methods}{ $meta->{reader} } = sub { 
                my ($self) = @_;

                if ( reftype $self eq 'HASH' ) {
                    return $self->{$obfu_name};
                }
                return $self->[ $spec->{implementation}{slot_offset}{$name} ];
            };
        }

        if ( !  $spec->{implementation}{methods}{$name}
             && $meta->{writer}
             && $in_interface->{ $meta->{writer} } ) {

            my $obfu_pkg = Moduloop::_Guts::obfu_name('', $spec);
            $spec->{implementation}{methods}{ $meta->{writer} } = sub {
                my ($self, $new_val) = @_;

                if ( reftype $self eq 'HASH' ) {
                    $self->{$obfu_pkg}->ASSERT($name, $new_val);
                    $self->{ Moduloop::_Guts::obfu_name($name, $spec) } = $new_val;
                }
                else {
                    $self->[0]->ASSERT($name, $new_val);
                    $self->[ $spec->{implementation}{slot_offset}{$name} ] = $new_val;
                }
                return $self;
            };
        }
    }
    _add_delegates($spec);

    while ( my ($name, $sub) = each %{ $spec->{implementation}{methods} } ) {
        next unless $in_interface->{$name};
        $stash->add_symbol("&$name", subname $stash->name."::$name" => $sub); 
    }
    while ( my ($name, $sub) = each %{ $spec->{implementation}{semiprivate} } ) {
        $private_stash->add_symbol("&$name", subname $private_stash->name."::$name" => $sub);
    }

    foreach my $name ( @{ $spec->{interface} } ) {
        _add_pre_conditions($spec, $stash, $name);
        _add_post_conditions($spec, $stash, $name);
    }
    _add_invariants($spec, $stash);
}

sub _add_invariants {
    my ($spec, $stash) = @_;

    return unless $Moduloop::Contracts_for{ $spec->{name} }{invariant};
    my $inv_hash =
      (!  ref $spec->{interface}
       &&  $Moduloop::Spec_for{ $spec->{interface} }{invariant})

      || $spec->{invariant}
      or return;

    $spec->{invariant_guard} ||= sub {
        # skip methods called by the invariant
        return if (caller 1)[0] eq $spec->{name};

        foreach my $desc (keys %{ $inv_hash }) {
            my $sub = $inv_hash->{$desc};
            $sub->(@_)
              or Moduloop::Error::ContractViolation->throw(
                    error => "Invariant '$desc' violated",
                    show_trace => 1,
              );
        }
    };
    foreach my $type ( qw[before after] ) {
        install_modifier($stash->name, $type, @{ $spec->{interface} }, $spec->{invariant_guard});
    }
}

sub _add_pre_conditions {
    my ($spec, $stash, $name) = @_;

    return unless $Moduloop::Contracts_for{ $spec->{name} }{pre};

    my $pre_cond_hash = $spec->{pre_and_post_conds}{object}{$name}{require}
      or return;

    my $guard = sub {
        foreach my $desc (keys %{ $pre_cond_hash }) {
            my $sub = $pre_cond_hash->{$desc};
            warn "$desc $name";
            $sub->(@_)
              or Moduloop::Error::ContractViolation->throw(
                    error => "Method '$name' failed precondition '$desc'"
              );
        }
    };
    install_modifier($stash->name, 'before', $name, $guard);
}

sub _add_post_conditions {
    my ($spec, $stash, $name) = @_;

    return unless $Moduloop::Contracts_for{ $spec->{name} }{post};

    my $post_cond_hash = $spec->{pre_and_post_conds}{object}{$name}{ensure}
      or return;

    my $guard = sub {
        my $orig = shift;
        my $self = shift;

        my $old = dclone($self);
        my $results = [$orig->($self, @_)];

        foreach my $desc (keys %{ $post_cond_hash }) {
            my $sub = $post_cond_hash->{$desc};
            $sub->($self, $old, $results, @_)
              or Moduloop::Error::ContractViolation->throw(
                    error => "Method '$name' failed postcondition '$desc'"
              );
        }
        return unless defined wantarray;
        return wantarray ? @$results : $results->[0];
    };
    install_modifier($stash->name, 'around', $name, $guard);
}

sub _make_builder_class {
    my ($spec) = @_;

    my $stash = Package::Stash->new("$spec->{name}::__Util");
    # use Data::Dump 'pp'; die pp($stash);
    $Moduloop::Util_class{ $spec->{name} } = $stash->name;

    my $constructor_spec = _constructor_spec($spec);

    my %method = (
        new_object => \&_object_maker,
    );

    $method{main_class} = sub { $spec->{name} };

    my $obfu_pkg = Moduloop::_Guts::obfu_name('', $spec);
    $method{build} = sub {
        my (undef, $obj, $arg) = @_;

        my $priv_pkg = reftype $obj eq 'ARRAY'
          ? $obj->[0]
          : $obj->{$obfu_pkg};
        if ( my $builder = $priv_pkg->can('BUILD') ) {
            $builder->($priv_pkg, $obj, $arg);
        }
    };

    $method{assert} = sub {
        shift;
        my ($slot, $val) = @_;

        return unless exists $constructor_spec->{kv_args}{$slot};
        validate(@_, {
            $slot => $constructor_spec->{kv_args}{$slot},
        });
    };

    $method{check_invariants} = sub {
        shift;
        my ($obj) = @_;

        return unless exists $spec->{invariant_guard};
        $spec->{invariant_guard}->($obj);
    };

    $method{check_postconditions} = sub {
        shift;
        my ($obj, $arg) = @_;

        return unless $Moduloop::Contracts_for{ $spec->{name} }{post};

        my $post_cond_hash = $constructor_spec->{ensure}
          or return;

        foreach my $desc (keys %{ $post_cond_hash }) {
            my $sub = $post_cond_hash->{$desc};
            $sub->($obj, $arg)
              or Moduloop::Error::ContractViolation->throw(
                    error => "Method '$constructor_spec->{name}' failed postcondition '$desc'"
              );
        }
    };

    my $class_var_stash = Package::Stash->new("$spec->{name}::__ClassVar");

    $method{get_var} = sub {
        my ($class, $name) = @_;
        $class_var_stash->get_symbol($name);
    };

    $method{set_var} = sub {
        my ($class, $name, $val) = @_;
        $class_var_stash->add_symbol($name, $val);
    };

    foreach my $sub ( keys %method ) {
        $stash->add_symbol("&$sub", $method{$sub});
        subname $stash->name."::$sub", $method{$sub};
    }
}

sub _add_class_methods {
    my ($spec, $stash) = @_;

    {
        if (!   ref $spec->{interface}
            &&  (my $s = $Moduloop::Spec_for{ $spec->{interface} }{class_methods})) {
            $spec->{class_methods} = $s;
        }
    }
    $spec->{class_methods} ||= $stash->get_all_symbols('CODE');
    _add_default_constructor($spec);

    foreach my $sub ( keys %{ $spec->{class_methods} } ) {
        $stash->add_symbol("&$sub", $spec->{class_methods}{$sub});
        subname "$spec->{name}::$sub", $spec->{class_methods}{$sub};
    }
}

sub _add_autoload {
    my ($spec, $stash) = @_;

    $spec->{implementation}{methods}{AUTOLOAD} = sub {
        my $self = shift;

        my $caller_sub = (caller 1)[3];
        my $caller_pkg = $caller_sub;
        $caller_pkg =~ s/::[^:]+$//;

        my $called = ${ $stash->get_symbol('$AUTOLOAD') };
        $called =~ s/.+:://;

        if(    exists $spec->{implementation}{semiprivate}{$called}
            && $caller_pkg eq ref $self
        ) {
            my $stash = _get_stash($spec->{implementation}{package});
            my $sp_var = ${ $stash->get_symbol('$__') };
            my $priv_pkg = reftype $self eq 'ARRAY'
              ? $self->[0]
              : $self->{$sp_var};
            return $priv_pkg->$called($self, @_);
        }
        elsif( $called eq 'DESTROY' ) {
            return;
        }
        else {
            croak sprintf(q{Can't locate object method "%s" via package "%s"},
                          $called, ref $self);
        }
    };
}

sub _add_delegates {
    my ($spec) = @_;

    my %local_method;

    foreach my $desc (@{ $spec->{implementation}{forwards} }) {

        my $send = ref $desc->{send} eq 'ARRAY'
          ? [uniq @{ $desc->{send} }]
          : [$desc->{send}];

        if ( any { exists $local_method{$_} } @{ $send } ) {
            next;
        }
        my $as = ref $desc->{as} eq 'ARRAY' ? $desc->{as} : [$desc->{as}];
        if(ref $desc->{to} eq 'ARRAY') {
            assert_nonref($desc->{send});
            foreach my $i (0 .. $#{ $desc->{to} }) {
                push @{ $local_method{ $desc->{send} }{targets} }, {
                    to => $desc->{to}[$i],
                    as => $as->[$i] || $desc->{send},
                };
            }
        }
        else {
            foreach my $i (0 .. $#$send) {
                push @{ $local_method{ $send->[$i] }{targets} }, {
                    to => $desc->{to},
                    as => $as->[$i] || $send->[$i],
                };
            }
        }
    }

    return unless %local_method;
    my $in_interface = _interface($spec);
    foreach my $meth ( keys %local_method ) {
        if ( defined $spec->{implementation}{methods}{$meth} ) {
            croak "Cannot override implemented method '$meth' with a delegated method";
        }
        $spec->{implementation}{methods}{$meth} = sub { 
            my $obj;
            if( ! $in_interface->{$meth} ) {
                shift;
            }
            $obj = shift;

            my @results;
            foreach my $desc ( @{ $local_method{$meth}{targets} } ) {
                my $obfu_name = Moduloop::_Guts::obfu_name($desc->{to}, $spec);
                my $target = $desc->{as};
                my $delegate = reftype $obj eq 'HASH'
                  ? $obj->{$obfu_name}
                  : $obj->[ $spec->{implementation}{slot_offset}{ $desc->{to} } ];
                push @results, $delegate->$target(@_);
            }
            if (@results == 1) {
                return $results[0];
            }
            return unless defined wantarray;
            return wantarray ? @results : [@results];
        }
    }
}

sub _constructor_spec {
    my ($spec) = @_;

    (!  ref $spec->{interface}
     &&  $Moduloop::Spec_for{ $spec->{interface} }{constructor})

    || $spec->{constructor};
}

sub _add_default_constructor {
    my ($spec) = @_;

    my $constructor_spec = _constructor_spec($spec);

    $constructor_spec->{name} ||= 'new';
    my $sub_name = $constructor_spec->{name};
    if ( ! exists $spec->{class_methods}{$sub_name} ) {
        $spec->{class_methods}{$sub_name} = sub {
            my $class = shift;
            my ($arg);

            if ( scalar @_ == 1 ) {
                $arg = shift;
            }
            elsif ( scalar @_ > 1 ) {
                $arg = [@_];
            }

            my $builder_class = Moduloop::builder_class($class);
            my $obj = $builder_class->new_object;
            for my $name ( keys %{ $constructor_spec->{kv_args} } ) {

                my ($attr, $dup) = grep { $spec->{implementation}{has}{$_}{init_arg} eq $name }
                                        keys %{ $spec->{implementation}{has} };
                if ( $dup ) {
                    confess "Cannot have same init_arg '$name' for attributes '$attr' and '$dup'";
                }
                if ( $attr ) {
                    _copy_assertions($spec, $name, $attr);
                    my $sub = $spec->{implementation}{has}{$attr}{map_init_arg};
                    my $attr_val = $sub ? $sub->($arg->{$name}) : $arg->{$name};
                    if ( reftype $obj eq 'HASH' ) {
                        my $obfu_name = Moduloop::_Guts::obfu_name($attr, $spec);
                        $obj->{$obfu_name} = $attr_val;
                    }
                    else {
                        $obj->[ $spec->{implementation}{slot_offset}{$attr} ] = $attr_val;
                    }
                }
            }

            $builder_class->build($obj, $arg);
            $builder_class->check_invariants($obj);
            $builder_class->check_postconditions($obj, $arg);
            return $obj;
        };
    }
}

sub _object_maker {
    my ($builder_class, $init) = @_;

    my $class = $builder_class->main_class;

    my $stash = Package::Stash->new($class);

    my $spec = $stash->get_symbol('%__meta__');
    my $pkg_key = Moduloop::_Guts::obfu_name('', $spec);
    my $obj = $spec->{implementation}{arrayimp}
      ? [ ${ $stash->get_symbol('$__Private_pkg') } ]
      : {
            $pkg_key => ${ $stash->get_symbol('$__Private_pkg') },
        };

    while ( my ($attr, $meta) = each %{ $spec->{implementation}{has} } ) {
        my $init_val = $init->{$attr}
                ? $init->{$attr}
                : (ref $meta->{default} eq 'CODE'
                  ? $meta->{default}->()
                  : $meta->{default});
        if ( $spec->{implementation}{arrayimp} ) {
            my $offset = $spec->{implementation}{slot_offset}{$attr};
            $obj->[$offset] = $init_val;
        }
        else {
            my $obfu_name = Moduloop::_Guts::obfu_name($attr, $spec);
            $obj->{$obfu_name} = $init_val;
        }
    }

    bless $obj => ${ $stash->get_symbol('$__Obj_pkg') };
    $Moduloop::_Guts::Implementation_meta{ref $obj} = $spec->{implementation};

    if ( reftype $obj eq 'HASH' ) {
        lock_keys(%$obj);
    }
    return $obj;
}

sub _add_traitlib_items {
    my ($spec, $from_traitlib, $traitlib, $item) = @_;

    for my $name ( keys %{$item} ) {

        if (my $other_traitlib = $from_traitlib->{$name}) {
            _raise_traitlib_conflict($name, $traitlib, $other_traitlib);
        }
        if ( ! $spec->{implementation}{has}{$name} ) {
            $spec->{implementation}{has}{$name} = $item->{$name};
            $from_traitlib->{$name} = $traitlib;
        }
    }
}

sub _add_traitlib_methods {
    my ($spec, $from_traitlib, $traitlib, $traitlib_meta, $code_for) = @_;

    my $in_class_interface = _interface($spec);
    my $is_semiprivate     = _interface($traitlib_meta, 'semiprivate');

    for my $name ( keys %{$code_for} ) {
        if ( $in_class_interface->{$name} ) {
            if (my $other_traitlib = $from_traitlib->{method}{$name}) {
                _raise_traitlib_conflict($name, $traitlib, $other_traitlib);
            }
            if ( ! $spec->{implementation}{methods}{$name} ) {
                $spec->{implementation}{methods}{$name} = $code_for->{$name};
                $from_traitlib->{method}{$name} = $traitlib;
            }
        }
        elsif ( $is_semiprivate->{$name} ) {
            if (my $other_traitlib = $from_traitlib->{semiprivate}{$name}) {
                _raise_traitlib_conflict($name, $traitlib, $other_traitlib);
            }
            if ( ! $spec->{implementation}{semiprivate}{$name} ) {
                $spec->{implementation}{semiprivate}{$name} = $code_for->{$name};
                $from_traitlib->{semiprivate}{$name} = $traitlib;
            }
        }
    }
}

sub _add_traitlib_forwards {
    my ($spec, $from_traitlib, $traitlib, $traitlib_meta) = @_;

    my %wanted = 
        map { $_ => 1 }
        @{ $spec->{implementation}{traits}{$traitlib}{methods} };

    for my $desc ( @{ $traitlib_meta->{forwards} } ) {
        my $send = ref $desc->{send} eq 'ARRAY' ? $desc->{send} : [$desc->{send}];
        my $wanted_methods;
        foreach my $name ( @$send ) {
            if (my $other_traitlib = $from_traitlib->{forwarded}{$name}) {
                _raise_traitlib_conflict($name, $traitlib, $other_traitlib);
            }
            if ( $wanted{$name} ) {
                $from_traitlib->{forwarded}{$name} = $traitlib;
                $wanted_methods++;
            }
        }
        if ( $wanted_methods ) {
            push @{ $spec->{implementation}{forwards} }, $desc;
        }
    }
}

sub _raise_traitlib_conflict {
    my ($name, $traitlib, $other_traitlib) = @_;

    Moduloop::Error::TraitConflict->throw(
        error => "Cannot borrow trait '$name' from both $traitlib and $other_traitlib"
    );
}

sub _copy_assertions {
    my ($spec, $name, $attr) = @_;

    my $constructor_spec = _constructor_spec($spec);
    my $meta = $constructor_spec->{kv_args}{$name};

    for my $desc ( keys %{ $meta->{callbacks} || {} } ) {
        next if exists $spec->{implementation}{has}{$attr}{callbacks}{$desc};

        $spec->{implementation}{has}{$attr}{callbacks}{$desc} = $meta->{callbacks}{$desc};
    }
}


1;

__END__