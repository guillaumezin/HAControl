package Plugins::HAControl::Log;

use strict;
use warnings;

sub new {
    my $class = shift;
    my $self = {
        _logger => shift,
        _prefix => shift,
    };
   bless $self, $class;
}

sub _fmt {
    my ($self, $msg) = @_;
    return $self->{_prefix} ? "[$self->{_prefix}] $msg" : $msg;
}

sub debug {
    my ($self, $msg) = @_;
    $self->{_logger}->debug($self->_fmt($msg));
}

sub info {
    my ($self, $msg) = @_;
    $self->{_logger}->info($self->_fmt($msg));
}

sub warn {
    my ($self, $msg) = @_;
    $self->{_logger}->warn($self->_fmt($msg));
}

sub error {
    my ($self, $msg) = @_;
    $self->{_logger}->error($self->_fmt($msg));
}

1;

__END__
