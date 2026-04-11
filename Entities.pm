package Plugins::HAControl::Entities;
use strict;
use warnings;
use List::Util qw(all);

sub new {
    my ($class) = @_;
    return bless {
        _by_id      => {},   # index by _id (main list)
        _by_commid  => {},   # index by _commid (main list)
        _list       => [],   # main list
    }, $class;
}

sub add {
    my ($self, $entity) = @_;
    push @{ $self->{_list} }, $entity;
    $self->{_by_id}    { $entity->{_id}     } = $entity;
    $self->{_by_commid}{ $entity->{_commid} } = $entity;
}

sub by_id {
    my ($self, $id) = @_;
    # Cherche dans la liste principale d'abord, puis dans hidden
    return $self->{_by_id}{$id};
}

sub by_commid {
    my ($self, $commid) = @_;
    return $self->{_by_commid}{$commid};
}

sub all_entities {
    my ($self) = @_;
    return @{ $self->{_list} };
}

sub count {
    my ($self) = @_;
    return scalar @{ $self->{_list} };
}

sub clear {
    my ($self) = @_;
    $self->{_by_id}       = {};
    $self->{_by_commid}   = {};
    $self->{_list}        = [];
    $self->{_hidden}      = [];
}

sub all_services_received {
    my ($self) = @_;
    return 0 unless $self->count();
    return all { $_->is_services_received() } $self->all_entities();
}

sub all_states_received {
    my ($self) = @_;
    return 0 unless $self->count();
    return all { $_->is_state_received() } $self->all_entities();
}

1;

__END__
