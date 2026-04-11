package Plugins::HAControl::WebsocketHandler;

use JSON::XS::VersionOneAndTwo;
use Encode qw(encode_utf8);
use Slim::Networking::SimpleWS;
use Slim::Utils::Timers;
use Plugins::HAControl::Entity;
use Plugins::HAControl::Entities;

use constant MODE_NONE               => 0;
use constant MODE_GET_LIST_BOARDS    => 1;
use constant MODE_SUBSCRIBE_BOARDS   => 2;
use constant MODE_GET_ENTITIES       => 3;
use constant MODE_GET_SERVICES       => 4;
use constant MODE_SUBSCRIBE_ENTITIES => 5;

sub new {
   my $class = shift;
   my $self = {
        _url => shift,
        _token => shift,
        _dashboard => shift,
        _log => shift,
        _on_change => shift,
        _auth => 0,
        _id => 1,
        _backupid => 0,
        _mode => MODE_NONE,
        _new_entities => undef,
        _entities => Plugins::HAControl::Entities->new(),
        _ws => undef,
        _queue => undef,
        _timer => undef,
        _url_path => '',
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
    $self->{_log}->debug('Connected');
}

sub _ws_callback {
    my ($self, $buf) = @_;
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
        $self->{_auth} = 1;
        $self->{_mode} = MODE_GET_LIST_BOARDS;
        $self->{_backupid} = $self->{_id}++;
        my $msg = '{"id":'.$self->{_backupid}.',"type":"lovelace/dashboards/list"}';
        $self->{_ws}->send($msg);
        $self->{_log}->debug('Ask list '.$msg);
    }
    elsif (($decoded->{'type'} eq 'result') && $decoded->{'success'} && !$decoded->{'error'}) {
        if (($self->{_mode} == MODE_GET_LIST_BOARDS) && ($decoded->{'id'} == $self->{_backupid})) {
            $self->{_log}->debug('Received list');
            foreach my $obj (@{ $decoded->{'result'} }) {
                if ((lc($obj->{'id'}) eq lc($self->{_dashboard})) || (lc($obj->{'title'}) eq lc($self->{_dashboard})) || (lc($obj->{'url_path'}) eq lc($self->{_dashboard}))) {
                    $self->{_url_path} = $obj->{'url_path'};
                    break;
                }
            }
            $self->{_mode} = MODE_SUBSCRIBE_BOARDS;
            $self->{_backupid} = $self->{_id}++;
            my $msg = '{"id":'.$self->{_backupid}.',"type":"subscribe_events","event_type":"lovelace_updated"}';
            $self->{_ws}->send($msg);
        }
        elsif (($self->{_mode} == MODE_SUBSCRIBE_BOARDS) && ($decoded->{'id'} == $self->{_backupid})) {
            $self->{_mode} = MODE_GET_ENTITIES;
            $self->{_log}->debug('Got list url '.$self->{_url_path}. ' now send '.$msg);
            $self->{_backupid} = $self->{_id}++;
            my $msg = '{"id":'.$self->{_backupid}.',"type":"lovelace/config","url_path":"' . $self->{_url_path} . '"}';
            $self->{_ws}->send($msg);
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
                        $self->{_backupid} = $self->{_id}++;
                        my $entity = Plugins::HAControl::Entity->new($badge->{'entity'}, $self->{_backupid});
                        $self->{_new_entities}->add($entity);
                    }
                }
            }
            foreach my $entity ($self->{_new_entities}->all_entities()) {
                $self->{_log}->debug('Trigger get_services for '.$entity->id());
                my $msg = '{"id":'.$entity->commid().',"type":"get_services_for_target","target":{"entity_id": ["'.$entity->id().'"]}}';
                $self->{_ws}->send($msg);
            }
        }
        elsif (($self->{_mode} == MODE_GET_SERVICES) && ($decoded->{'id'})) {
            $self->{_log}->debug('Received services');
            my $entity = $self->{_new_entities}->by_commid($decoded->{'id'});
            if ($entity) {
                $self->{_log}->debug('Got services for entity '.$entity->id());
                $entity->analyse_services($decoded->{'result'});
                if ($self->{_new_entities}->all_services_received()) {
                    $self->{_mode} = MODE_SUBSCRIBE_ENTITIES;
                    foreach my $entity ($self->{_new_entities}->all_entities()) {
                        $self->{_log}->debug('Trigger subscribe_entities for '.$entity->id());
                        $self->{_backupid} = $self->{_id}++;
                        $entity->commid($self->{_backupid});
                        my $msg = '{"id":'.$entity->commid().',"type":"subscribe_entities","entity_ids":["'.$entity->id().'"]}';
                        $self->{_ws}->send($msg);
                    }
                }
            }
        }
    }
    elsif ($decoded->{'id'} && ($decoded->{'type'} eq 'event') && $decoded->{'event'} &&    $decoded->{'event'}->{'event_type'} && ($decoded->{'event'}->{'event_type'} eq 'lovelace_updated') && $decoded->{'event'}->{'data'} && $decoded->{'event'}->{'data'}->{'url_path'}  && ($decoded->{'event'}->{'data'}->{'url_path'} eq $self->{_url_path})) {
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
                if ($attr->{'current_position'}) {
                    $entity->current_position($attr->{'current_position'});
                }
            }
            if ($data->{'s'}) {
                $self->{_log}->debug('Got state '.$data->{'s'});
                $entity->state($data->{'s'});
            }
            if ($is_added) {
                if ($self->{_new_entities}->all_states_received()) {
                    $self->{_log}->debug('All entities ready');
                    $self->{_entities} = $self->{_new_entities};
                    if ($self->{_queue}) {
                        #TODO: Améliorer la gestion de queue
                        $self->{_backupid} = $self->{_id}++;
                        my $msg = $self->{_queue};
                        $self->{_log}->debug('Send command on queue '.$msg);
                        $self->{_ws}->send($msg);
                    }
                    $self->{_queue} = undef;
                    my $cb = $self->{_on_change};
                    if ($cb) {
                        $self->{_log}->debug('Calling callback');
                        $cb->();
                    }
                }
            }
            else {
                my $cb = $self->{_on_change};
                if ($cb) {
                    $self->{_log}->debug('Calling callback');
                    $cb->();
                }
            }
        }
    }
    elsif (($decoded->{'type'} eq 'result') && $decoded->{'success'} && $decoded->{'error'} && $decoded->{'error'}->{'code'} && $decoded->{'error'}->{'message'}) {
        $self->{_log}->debug('Error received from websocket: '.$decoded->{'error'}->{'message'}. ' (code: '.$decoded->{'error'}->{'code'} . ')');
    }
}

sub entities {
    my ($self) = @_;
    return $self->{_entities}->all_entities();
}

sub send_command {
    my ($self, $id, $cmd, $level) = @_;

    my $entity = $self->{_entities}->by_id($id);

    if ($entity) {
        $self->{_backupid} = $self->{_id}++;
        $entity->commid($self->{_backupid});
        my $msg = '{"id":'.$entity->commid().',"return_response":false,'.$entity->create_call_service($cmd, $level).'}';
        $self->{_log}->debug('Send command '.$msg);
        if ($self->{_open}) {
            $self->{_ws}->send($msg);
        }
        else {
            $self->{_queue} = $msg;
            $self->connect();
        }
    }
}

sub _error_callback {
    my ($self) = @_;
    if ($self->{_mode}) {
        $self->{_log}->error('Error during communication');
    }
    else {
        $self->{_log}->error('Error during auth, check token in configuration');
    }
    $self{_timer} = Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 10, sub { $self->connect() });
}

sub connect {
    my ($self) = @_;

    $self->close();

    $self->{_log}->debug('Opening websocket ' . $self->{_url});
    my $ws = Slim::Networking::SimpleWS->new($self->{_url}, sub { $self->_connected_callback(@_) }, sub { $self->_error_callback(@_) });
    $self->{_ws} = $ws;
    $self->{_open} = 1;
    #$self->{_ws}->listenAsync(sub { $self->_normal_callback(@_) }, sub { $self->_error_callback(@_) });
    $self->{_ws}->listenAsync(sub { eval {$self->_ws_callback(@_)}; if ($@) {$self->{_log}->error("Error in _ws_callback : $@");} }, sub { $self->_error_callback(@_) });
}

sub close {
    $self->{_open} = 0;
    if ($self{_timer}) {
        Slim::Utils::Timers::killSpecific($self{_timer});
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

1;
