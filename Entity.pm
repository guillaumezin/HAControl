package Plugins::HAControl::Entity;

use strict;
use warnings;

use List::Util qw(any);

sub new {
   my $class = shift;
   my $self = {
        _id => shift,
        _commid => shift,
        _hidden => shift,
        _state => '',
        _friendly_name => '',
        _domain => '',
        _short_name => '',
        _services_received => 0,
        _state_received => 0,
        _is_turn_on => 0,
        _is_turn_off => 0,
        _is_cover => 0,
        _is_cover_position => 0,
        _is_setpoint => 0,
        _is_number => 0,
        _current_position => 0,
        _is_selector => 0,
        _is_press => 0,
        _min => 0,
        _max => 100,
        _step => 1,
        _options => undef,
   };
   bless $self, $class;

   ($self->{_domain}, $self->{_short_name}) = split(/\./, $self->{_id}, 2);

   return $self;
}

sub analyse_services {
    my ($self, $services) = @_;
    $self->{_services_received} = 1;

    if (any { $_ eq "cover.open_cover" } @{ $services }) {
        $self->{_is_cover} = 1;
    }
    if (any { $_ eq "input_button.press" } @{ $services }) {
        $self->{_is_press} = 1;
    }
    if (any { $_ eq "homeassistant.turn_on" } @{ $services }) {
        $self->{_is_turn_on} = 1;
    }
    if (any { $_ eq "homeassistant.turn_off" } @{ $services }) {
        $self->{_is_turn_off} = 1;
    }
    if (any { $_ eq "cover.set_cover_position" } @{ $services }) {
        $self->{_is_cover_position} = 1;
    }
    if (any { $_ eq "input_number.set_value" } @{ $services }) {
        $self->{_is_number} = 1;
    }
    if (any { $_ eq "input_select.select_option" } @{ $services }) {
        $self->{_is_selector} = 1;
    }
}

sub options {
    my ($self, $options) = @_;

    if (@_ > 1) {
        if (defined $options) {
            $self->{_options} = [ @{ $options } ];
        } else {
            $self->{_options} = undef;
        }
        return $self;
    }

    return @{ $self->{_options} // [] };
}

sub is_services_received {
    my ($self) = @_;
    return $self->{_services_received};
}

sub friendly_name {
    my ($self, $friendly_name) = @_;

    if (@_ > 1) {
        if (defined $friendly_name) {
            $self->{_friendly_name} = $friendly_name;
        }
        return $self;
    }

    return $self->{_friendly_name};
}

sub state {
    my ($self, $state) = @_;

    if (@_ > 1) {
        $self->{_state_received} = 1;
        if (defined $state) {
            $self->{_state} = $state;
        }
        return $self;
    }

    return $self->{_state};
}

sub boolean_state {
    my ($self) = @_;

    if (($self->{_state} eq 'on') || ($self->{_state} eq 'open')) {
        return 1;
    }
    else {
        return 0;
    }
}

sub is_hidden {
    my ($self) = @_;
    return $self->{_hidden};
}

sub is_state_received {
    my ($self) = @_;
    return $self->{_state_received};
}

sub min {
    my ($self, $min) = @_;

    if (@_ > 1) {
        if (defined $min) {
            $self->{_min} = $min;
        }
        return $self;
    }

    return $self->{_min};
}

sub max {
    my ($self, $max) = @_;

    if (@_ > 1) {
        if (defined $max) {
            $self->{_max} = $max;
        }
        return $self;
    }

    return $self->{_max};
}

sub step {
    my ($self, $step) = @_;

    if (@_ > 1) {
        if (defined $step) {
            $self->{_step} = $step;
        }
        return $self;
    }

    return $self->{_step};
}

sub current_position {
    my ($self, $current_position) = @_;

    if (@_ > 1) {
        if (defined $current_position) {
            $self->{_current_position} = $current_position;
        }
        return $self;
    }

    return $self->{_current_position};
}

sub is_number {
    my ($self) = @_;
    return $self->{_is_number};
}

sub is_selector {
    my ($self) = @_;
    return $self->{_is_selector};
}

sub is_on_off {
    my ($self) = @_;
    return $self->{_is_turn_on} && $self->{_is_turn_off};
}

sub _translate_service_on_off {
    my ($self,$level) = @_;
    if ($level) {
        if ($self->{_is_cover}) {
            return 'open_cover';
        }
        else {
            return 'turn_on';
        }
    }
    else {
        if ($self->{_is_cover}) {
            return 'close_cover';
        }
        else {
            return 'turn_off';
        }
    }
}

sub is_press {
    my ($self) = @_;
    if ($self->{_is_press}) {
        return 1;
    }
    elsif (!$self->{_is_turn_on} && $self->{_is_turn_off}) {
        return 0;
    }
    return $self->{_is_turn_on} && ! $self->{_is_turn_off};
}

sub is_slider {
    my ($self) = @_;
    return $self->{_is_cover_position};
}

sub commid {
    my ($self, $commid) = @_;

    if (@_ > 1) {
        if (defined $commid) {
            $self->{_commid} = $commid;
        }
        return $self;
    }

    return $self->{_commid};
}

sub id {
    my ($self) = @_;
    return $self->{_id};
}

sub domain {
    my ($self) = @_;
    return $self->{_domain};
}

sub short_name {
    my ($self) = @_;
    return $self->{_short_name};
}

sub create_call_service {
    my ($self, $cmd, $level) = @_;

    if ($cmd eq 'selector') {
        return '"type":"call_service","domain":"'.$self->domain().'","service":"select_option","service_data":{"entity_id":"'.$self->id().'","option":"'.$level.'"}';
    }
    elsif (($cmd eq 'slider') && $self->_is_cover_position) {
        return '"type":"call_service","domain":"'.$self->domain().'","service":"set_cover_position","service_data":{"entity_id":"'.$self->id().'","position":'.$level.'}';
    }
    elsif (($cmd eq 'slider') || ($cmd eq 'number'))  {
        return '"type":"call_service","domain":"'.$self->domain().'","service":"set_value","service_data":{"entity_id":"'.$self->id().'","value":'.$level.'}';
    }
    elsif ($cmd eq 'press')  {
        if ($self->{_is_press}) {
            return '"type":"call_service","domain":"input_button","service":"press","service_data":{"entity_id":"'.$self->id().'"}';
        }
        elsif (!$self->{_is_turn_on} && $self->{_is_turn_off}) {
            return '"type":"call_service","domain":"'.$self->domain().'","service":"turn_off","service_data":{"entity_id":"'.$self->id().'"}';
        }
        return '"type":"call_service","domain":"'.$self->domain().'","service":"turn_on","service_data":{"entity_id":"'.$self->id().'"}';
    }
    else {
        my $boolean_level = $self->_translate_service_on_off($level);
        return '"type":"call_service","domain":"'.$self->domain().'","service":"'.$boolean_level.'","service_data":{"entity_id":"'.$self->id().'"}';
    }
}

1;

__END__
