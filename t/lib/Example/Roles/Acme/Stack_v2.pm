package Example::Roles::Acme::Stack_v2;

use Moduloop::Implementation
    roles => ['Example::Roles::Role::Pushable'],

    around => {
        pop => sub {
            my ($orig, $self) = @_;

            $orig->($self, -1);
        },
    },
;

1;