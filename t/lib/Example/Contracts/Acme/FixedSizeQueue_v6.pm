package Example::Contracts::Acme::FixedSizeQueue_v6;

use Example::Delegates::Queue;

use Moduloop::Implementation
    has  => {
        Q => { 
            default => sub { Example::Delegates::Queue::->new },
        },

        MAX_SIZE => { 
            init_arg => 'max_size',
            reader   => 'max_size',
        },
    }, 
    forwards => [
        {
            send => [qw( head pop tail size )],
            to   => 'Q'
        },
    ],
;

sub BUILD { 
    my ($self) = @_;

    # make constructor postcondition fail
    $self->{$Q}->push(1);
}

sub push {
    my ($self, $val) = @_;

    $self->{$Q}->push($val);

    if ($self->size > $self->{$MAX_SIZE}) {
        $self->pop;        
    }
}

1;
