package Plugins::HAControl::WebsocketHandler;

use JSON::XS::VersionOneAndTwo;
use Encode qw(encode_utf8);
use Scalar::Util qw(weaken);
use Slim::Networking::SimpleWS;
use Slim::Utils::Timers;
use Plugins::HAControl::Entity;
use Plugins::HAControl::Entities;

use constant MODE_NONE                    => 0;
use constant MODE_GET_LIST_BOARDS         => 1;
use constant MODE_SUBSCRIBE_BOARDS        => 2;
use constant MODE_GET_ENTITIES            => 3;
use constant MODE_GET_SERVICES            => 4;
use constant MODE_SUBSCRIBE_ENTITIES      => 5;
use constant MODE_GET_MORE_SERVICES       => 6;
use constant MODE_SUBSCRIBE_MORE_ENTITIES => 7;

sub new {
   my $class = shift;
   my $self = {
        _url => shift,
        _token => shift,
        _dashboard => shift,
        _log => shift,
        _on_init => shift,
        _on_change => shift,
        _on_error => shift,
        _id => 1,
        _backupid => 0,
        _mode => MODE_NONE,
        _new_entities => Plugins::HAControl::Entities->new(),
        _entities => Plugins::HAControl::Entities->new(),
        _ws => undef,
        _queue => [],
        _queue_mode => [],
        _queue_entity => [],
        _ready => 0,
        _timer => undef,
        _url_path => '',
        _hidden_entity_id => '',
        _entities_id_in_error => {},
        _subscribe_hidden_callback => undef,
        _open => 0,
   };
   bless $self, $class;

   $self->connect();

   return $self;
}

sub DESTROY {
    my ($self) = @_;
    $self->close();
}

sub _connected_callback {
    my ($self) = @_;

    if (!defined($self)) {
        return;
    }

    $self->{_log}->debug('Connected');
}

sub _on_ready {
    my ($self) = @_;
    $self->{_log}->debug('State machine ready');

    if (@{ $self->{_queue} }) {
        $self->_send_next();
        return;
    }

    $self->{_ready} = 1;
    $self->{_log}->debug('State machine ready and queue empty');
}

sub _send_with_id{
    my ($self, $buf, $entity) = @_;
    my $msg;
    
    $self->{_backupid} = $self->{_id}++;

    if ($entity) {
        $self->{_entities}->commid($entity, $self->{_backupid});
        $self->{_new_entities}->commid($entity, $self->{_backupid});
    }

    $msg = '{"id":'.$self->{_backupid}.','.$buf.'}';
    $self->{_log}->debug('Send message '.$msg);

    $self->{_ws}->send($msg);
}

sub _ws_callback {
    my ($self, $buf) = @_;

    if (!defined($self)) {
        return;
    }   
    
    $self->{_log}->debug('Message: ' . $buf);
    my $decoded = eval { decode_json(encode_utf8($buf)) };
    if ($@) {
        $self->{_log}->error("JSON decode error : $@");
        return;
    }
    if ($decoded->{'type'} eq 'auth_required') {
        my $msg = '{"type":"auth","access_token":"scrambled"}';
        $self->{_log}->debug('Send auth '.$msg);
        $msg = '{"type":"auth","access_token":"'.$self->{_token}.'"}';
        $self->{_ws}->send($msg);
    }
    elsif ($decoded->{'type'} eq 'auth_ok') {
        $self->{_mode} = MODE_GET_LIST_BOARDS;
        my $msg = '"type":"lovelace/dashboards/list"';
        $self->_send_with_id($msg);
        $self->{_log}->debug('Ask list '.$msg);
    }
    elsif (($decoded->{'type'} eq 'result') && $decoded->{'success'} && !$decoded->{'error'}) {
        if (($self->{_mode} == MODE_GET_LIST_BOARDS) && ($decoded->{'id'} == $self->{_backupid})) {
            $self->{_log}->debug('Received list');
            foreach my $obj (@{ $decoded->{'result'} }) {
                if ((lc($obj->{'id'}) eq lc($self->{_dashboard})) || (lc($obj->{'title'}) eq lc($self->{_dashboard})) || (lc($obj->{'url_path'}) eq lc($self->{_dashboard}))) {
                    $self->{_url_path} = $obj->{'url_path'};
                    last;
                }
            }
            $self->{_mode} = MODE_SUBSCRIBE_BOARDS;
            my $msg = '"type":"subscribe_events","event_type":"lovelace_updated"';
            $self->_send_with_id($msg);
            $self->{_log}->debug('Got list url '.$self->{_url_path}. ' now send '.$msg);
        }
        elsif (($self->{_mode} == MODE_SUBSCRIBE_BOARDS) && ($decoded->{'id'} == $self->{_backupid})) {
            $self->{_mode} = MODE_GET_ENTITIES;
            my $msg = '"type":"lovelace/config","url_path":"' . $self->{_url_path} . '"';
            $self->_send_with_id($msg);
            $self->{_log}->debug('Lovelace subscribed, now send '.$msg);
        }
        elsif (($self->{_mode} == MODE_GET_ENTITIES) && ($decoded->{'id'} == $self->{_backupid})) {
            $self->{_log}->debug('Received entities');
            $self->{_new_entities} = Plugins::HAControl::Entities->new();
            $self->{_mode} = MODE_GET_SERVICES;
            foreach my $view (@{ $decoded->{'result'}->{'views'} }) {
                next unless $view->{'badges'};
                foreach my $badge (@{ $view->{'badges'} }) {
                    next unless $badge->{'type'} eq 'entity';
                    if ($badge->{'entity'}) {
                        $self->{_log}->debug('Got entity '.$badge->{'entity'});
                        my $entity = Plugins::HAControl::Entity->new($badge->{'entity'}, 0);
                        $self->{_new_entities}->add($entity);
                    }
                }
            }
            foreach my $entity ($self->{_new_entities}->all_entities()) {
                $self->{_log}->debug('Trigger get_services for '.$entity->id());
                my $msg = '"type":"get_services_for_target","target":{"entity_id": ["'.$entity->id().'"]}';
                $self->_send_with_id($msg, $entity);
            }
        }
        elsif (($self->{_mode} == MODE_GET_SERVICES) && $decoded->{'id'}) {
            $self->{_log}->debug('Received services');
            my $entity = $self->{_new_entities}->by_commid($decoded->{'id'});
            if ($entity) {
                $self->{_log}->debug('Got services for entity '.$entity->id());
                $entity->analyse_services($decoded->{'result'});
                if ($self->{_new_entities}->all_services_received()) {
                    $self->{_mode} = MODE_SUBSCRIBE_ENTITIES;
                    foreach my $entity ($self->{_new_entities}->all_entities()) {
                        $self->{_log}->debug('Trigger subscribe_entities for '.$entity->id());
                        my $msg = '"type":"subscribe_entities","entity_ids":["'.$entity->id().'"]';
                        $self->_send_with_id($msg, $entity);
                    }
                }
            }
            else {
                $self->{_log}->debug('Entity not found');
                foreach my $entity2 ($self->{_new_entities}->all_entities()) {
                    $self->{_log}->debug('Entity '. $entity2->id() . ' with commid ' . $entity2->commid() . ' in collection');
                }
            }
        }
        elsif (($self->{_mode} == MODE_GET_MORE_SERVICES) && ($decoded->{'id'} == $self->{_backupid})) {
            $self->{_ready} = 0;
            $self->{_log}->debug('Received more services');
            my $entity = $self->{_entities}->add(Plugins::HAControl::Entity->new($self->{_hidden_entity_id}, 1));
            if ($entity) {
                $entity->analyse_services($decoded->{'result'});
                $self->{_mode} = MODE_SUBSCRIBE_MORE_ENTITIES;
                $self->{_log}->debug('Trigger subscribe_entities for '.$entity->id());
                my $msg = '"type":"subscribe_entities","entity_ids":["'.$entity->id().'"]';
                $self->_send_with_id($msg, $entity);
            }
        }
    }
    elsif ($decoded->{'id'} && ($decoded->{'type'} eq 'event') && $decoded->{'event'} &&    $decoded->{'event'}->{'event_type'} && ($decoded->{'event'}->{'event_type'} eq 'lovelace_updated') && $decoded->{'event'}->{'data'} && $decoded->{'event'}->{'data'}->{'url_path'} && ($decoded->{'event'}->{'data'}->{'url_path'} eq $self->{_url_path})) {
        $self->{_log}->debug('Lovelace event, reconnect');
        $self->connect();
    }
    elsif ($decoded->{'id'} && ($decoded->{'type'} eq 'event') && $decoded->{'event'}) {
        my $entity_id;
        my $entity;
        my $key = 'c';
        my $is_added = 0;
        if ($decoded->{'event'}->{'a'}) {
            $key = 'a';
            ($entity_id) = keys %{ $decoded->{'event'}->{$key} };
            if (!$entity_id) {
                $self->{_log}->debug('Empty event received');
                return;
            }
            $entity = $self->{_new_entities}->by_id($entity_id);
            $is_added = 1;
        }
        elsif ($decoded->{'event'}->{'c'}) {
            ($entity_id) = keys %{ $decoded->{'event'}->{$key} };
            $entity = $self->{_entities}->by_id($entity_id);
        }
        if ($entity) {
            $self->{_log}->debug('Got states for entity '.$entity->id());
            my $data;
            if ($is_added) {
                $data = $decoded->{'event'}->{$key}->{$entity_id};
            }
            else {
                $data = $decoded->{'event'}->{$key}->{$entity_id}->{'+'};
            }
            my $attr = $data->{'a'};
            if ($attr) {
                if ($attr->{'supported_features'} && ($attr->{'supported_features'} eq 'restored')) {                    
                    $self->{_log}->debug('Trigger get_services after supported_features restored for '.$entity->id());
                    my $msg = '"type":"get_services_for_target","target":{"entity_id": ["'.$entity->id().'"]}';
                    $self->_send_with_id($msg, $entity);
                    return;
                }
                if ($attr->{'friendly_name'}) {
                    $self->{_log}->debug('Got name '.$attr->{'friendly_name'});
                    $entity->friendly_name($attr->{'friendly_name'});
                }
                if ($attr->{'options'}) {
                    $entity->options($attr->{'options'});
                }
                if ($attr->{'min'}) {
                    $entity->min($attr->{'min'});
                }
                if ($attr->{'max'}) {
                    $entity->max($attr->{'max'});
                }
                if ($attr->{'step'}) {
                    $entity->step($attr->{'step'});
                }
                if ($attr->{'mode'}) {
                    $entity->mode($attr->{'mode'});
                }
                if ($attr->{'unit_of_measurement'}) {
                    $entity->unit($attr->{'unit_of_measurement'});
                }
                if ($attr->{'current_position'}) {
                    $self->{_log}->debug('Change current position to '.$attr->{'current_position'});
                    $entity->current_position($attr->{'current_position'});
                }
                if ($attr->{'brightness'}) {
                    $self->{_log}->debug('Change current brightness to '.$attr->{'brightness'});
                    $entity->current_position($attr->{'brightness'});
                }
            }
            if ($data->{'s'}) {
                $self->{_log}->debug('Got state '.$data->{'s'});
                $entity->state($data->{'s'});
            }
            if ($entity->is_hidden()) {
                if ($is_added) {
                    $self->{_log}->debug('New hidden entity state received');
                    my $cb = $self->{_subscribe_hidden_callback};
                    if ($cb) {
                        $self->{_log}->debug('Calling subscribe_hidden_entity callback (after add)');
                        $cb->();
                        $self->{_subscribe_hidden_callback} = undef;
                    }
                    $self->_on_ready();
                }
            }
            elsif ($is_added) {
                if ($self->{_new_entities}->all_states_received()) {
                    $self->{_log}->debug('All entities ready');
                    $self->{_entities} = $self->{_new_entities};
                    my $cb = $self->{_on_init};
                    if ($cb) {
                        $self->{_log}->debug('Calling oninit callback');
                        $cb->();
                    }
                    $self->_on_ready();
                }
            }
            else {
                my $cb = $self->{_on_change};
                if ($cb) {
                    $self->{_log}->debug('Calling onchange callback');
                    $cb->();
                }
            }
        }
    }
    elsif (($decoded->{'type'} eq 'result') && !$decoded->{'success'} && $decoded->{'error'} && $decoded->{'error'}->{'code'} && $decoded->{'error'}->{'message'}) {
        my $cb = $self->{_subscribe_hidden_callback};
        if ($cb) {
            $self->_add_entities_id_in_error($self->{_hidden_entity_id});
            $self->{_log}->debug('Calling subscribe_hidden_entity callback (after error)');
            $cb->();
            $self->{_subscribe_hidden_callback} = undef;
        }
        else {
            $self->{_log}->debug('Error received from websocket: '.$decoded->{'error'}->{'message'}. ' (code: '.$decoded->{'error'}->{'code'} . ')');
            my $cb = $self->{_on_error};
            if ($cb) {
                $self->{_log}->debug('Calling onerror callback');
                $cb->();
            }
        }
        $self->_on_ready();
    }
}

sub entities {
    my ($self) = @_;
    return $self->{_entities}->all_entities();
}

sub _add_entities_id_in_error {
    my ($self, $id) = @_;
    $self->{_log}->debug('Add to entities id error list: ' . $id);
    $self->{_entities_id_in_error}{$id} = 1;
}

sub is_entity_id_in_error {
    my ($self, $id) = @_;
    return exists $self->{_entities_id_in_error}{$id};
}

sub clear_entities_id_in_error {
    my ($self) = @_;
    $self->{_log}->debug('Clear entities id error list');
    $self->{_entities_id_in_error} = {};
}

sub entity_by_id {
    my ($self, $id) = @_;
    return $self->{_entities}->by_id($id);
}

sub _enqueue {
    my ($self, $msg, $mode, $entity) = @_;
    $self->{_log}->debug('Enqueue');
    push @{ $self->{_queue} }, $msg;
    push @{ $self->{_queue_mode} }, $mode // $self->{_mode};
    push @{ $self->{_queue_entity} }, $entity;
}

sub _send_next {
    my ($self) = @_;
    return unless @{ $self->{_queue} };
    $self->{_log}->debug('Send next');
    my $msg  = shift @{ $self->{_queue} };
    my $mode = shift @{ $self->{_queue_mode} };
    my $entity = shift @{ $self->{_queue_entity} };
    $self->{_mode} = $mode;
    $self->_send_with_id($msg, $entity);
}

sub _send_or_enqueue {
    my ($self, $msg, $mode, $entity) = @_;
    if ($self->{_ready} && $self->{_open}) {
        $self->{_mode} = $mode if defined $mode;
        $self->_send_with_id($msg, $entity);
    } else {
        $self->_enqueue($msg, $mode, $entity);
        if (!$self->{_open}) {
            $self->connect();
        }
    }
}

sub _clear_queue {
    my ($self) = @_;
    $self->{_queue}      = [];
    $self->{_queue_mode} = [];
    $self->{_queue_entity} = [];
}

sub send_command {
    my ($self, $id, $cmd, $level) = @_;

    my $entity = $self->{_entities}->by_id($id);

    if ($entity) {
        my $msg = '"return_response":false,'.$entity->create_call_service($cmd, $level);
        $self->{_log}->debug('Send command '.$msg);
        $self->_send_or_enqueue($msg, undef, $entity);
    }
}

sub _error_callback {
    my ($self) = @_;

    if (!defined($self)) {
        return;
    }
    
    my $weak_self = $self;
    weaken($weak_self);    

    if ($self->{_mode}) {
        $self->{_log}->error('Error during communication');
    }
    else {
        $self->{_log}->error('Error during connection or auth, check token in configuration');
    }
    $self->{_timer} = Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 10, sub { eval{$weak_self->connect()}; if ($@) {$weak_self->{_log}->error("Error in reconnect timer: $@");} });
}

sub subscribe_hidden_entity {
    my ($self, $id, $cb) = @_;

    $self->{_log}->debug('Trigger get_services for '.$id);
    $self->{_hidden_entity_id} = $id;
    $self->{_subscribe_hidden_callback} = $cb;
    my $msg = '"type":"get_services_for_target","target":{"entity_id": ["'.$id.'"]}';
    $self->_send_or_enqueue($msg, MODE_GET_MORE_SERVICES);
}

sub connect {
    my ($self) = @_;
    
    if (!defined($self)) {
        return;
    }
    
    my $weak_self = $self;
    weaken($weak_self);    

    $self->close();

    $self->{_log}->debug('Opening websocket ' . $self->{_url});
    $self->{_open} = 1;
    my $ws = Slim::Networking::SimpleWS->new($self->{_url}, sub { eval {$weak_self->_connected_callback(@_)}; if ($@) {$weak_self->{_log}->error("Error in _connected_callback: $@");} }, sub { eval {$weak_self->_error_callback(@_)}; if ($@) {$weak_self->{_log}->error("Error in _error_callback on new: $@");} });
    $self->{_ws} = $ws;
    #$self->{_ws}->listenAsync(sub { $weak_self->_ws_callback(@_) }, sub { $weak_self->_error_callback(@_) });
    #$self->{_ws}->listenAsync(sub { eval {$weak_self->_ws_callback(@_)} }, sub { eval {$weak_self->_error_callback(@_) } });
    $self->{_ws}->listenAsync(sub { eval {$weak_self->_ws_callback(@_)}; if ($@) {$weak_self->{_log}->error("Error in _ws_callback: $@");} }, sub { eval {$weak_self->_error_callback(@_)}; if ($@) {$weak_self->{_log}->error("Error in _error_callback on listenAsync: $@");} });
}

sub close {
    my ($self) = @_;

    $self->{_open} = 0;
    $self->{_ready} = 0;
    if ($self->{_timer}) {
        Slim::Utils::Timers::killSpecific($self->{_timer});
    }
    if ($self->{_ws}) {
        $self->{_ws}->close();
        $self->{_ws} = undef;
    }
}

sub on_change {
    my ($self, $cb) = @_;

    $self->{_on_change} = $cb;
    return $self;
}

sub on_init {
    my ($self, $cb) = @_;

    $self->{_on_init} = $cb;
    return $self;
}

sub on_error {
    my ($self, $cb) = @_;

    $self->{_on_error} = $cb;
    return $self;
}

1;

__END__
