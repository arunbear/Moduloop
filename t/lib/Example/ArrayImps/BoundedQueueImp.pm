package Example::ArrayImps::BoundedQueueImp;

use Example::Delegates::Queue;

use Mic::ArrayImpl
    has  => {
        Q => { 
            default => sub { Example::Delegates::Queue::->new },
        },

        MAX_SIZE => { 
            init_arg => 'max_size',
        },
    }, 
    forwards => [
        {
            send => [qw( size pop )],
            to   => 'Q'
        },
    ],
;

sub push {
    my ($self, $val) = @_;

    $self->[$Q]->push($val);

    if ($self->size > $self->[$MAX_SIZE]) {
        $self->pop;        
    }
}

1;
