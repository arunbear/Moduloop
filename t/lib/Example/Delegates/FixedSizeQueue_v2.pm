package Example::Delegates::FixedSizeQueue_v2;

use Moduloop
    interface => { 
        object => {
            push  => {},
            q_pop => {},
            q_size => {},
        },
        class => { new => {} }
    },

    constructor => {
        kv_args => {
            max_size => { 
                callbacks => { positive_int => sub { $_[0] =~ /^\d+$/ && $_[0] > 0 } }, 
            },
        }
    },

    implementation => 'Example::Delegates::Acme::FixedSizeQueue_v2',
;

1;
