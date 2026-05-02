package Plugins::HAControl::WebsocketHandler;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Encode qw(encode_utf8);
use Time::HiRes ();
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
use constant MODE_PING                    => 8;

sub new {
    my $class = shift;

    my $self = {
        _url       => shift,
        _token     => shift,
        _dashboard => shift,
        _log       => shift,
        _on_init   => shift,
        _on_change => shift,
        _on_error  => shift,

        _id       => 1,
        _mode     => MODE_NONE,
        _pending  => {},

        _new_entities => Plugins::HAControl::Entities->new(),
        _entities     => Plugins::HAControl::Entities->new(),

        _ws    => undef,
        _open  => 0,
        _auth  => 0,
        _connecting => 0,
        _ready => 0,

        _queue        => [],
        _queue_mode   => [],
        _queue_entity => [],

        _url_path => '',

        _hidden_entity_id          => '',
        _entities_id_in_error      => {},
        _subscribe_hidden_callback => undef,

        _reconnect_timer => undef,
        _reconnect_delay => 5,
        _reconnect_max   => 300,
        _reconnecting    => 0,
        _reconnect_scheduled => 0,
        _ping_scheduled => 0,

        _ping_timer => undef,
        _last_pong  => time(),

        _shutdown => 0,
    };

    bless $self, $class;

    $self->connect();

    return $self;
}

sub DESTROY {
    my ($self) = @_;
    $self->shutdown();
}

##############################################################################
# lifecycle
##############################################################################

sub shutdown {
    my ($self) = @_;
    return unless $self;

    $self->{_log}->debug('shutdown');

    $self->{_reconnect_scheduled}=0;
    $self->{_shutdown} = 1;

    $self->close();
}

sub close {
    my ($self) = @_;

    $self->{_log}->debug('close');

    $self->{_open}  = 0;
    $self->{_auth}  = 0;
    $self->{_ready} = 0;

    Slim::Utils::Timers::killTimers($self, \&_reconnect_timer_cb);
    $self->{_reconnect_scheduled} = 0;
    Slim::Utils::Timers::killTimers($self, \&_ping_timer_cb);
    $self->{_ping_scheduled} = 0;

    if (defined $self->{_ws}) {
        my $ws = delete $self->{_ws};
        eval { $ws->close(); };
    }
}

sub connect {
    my ($self) = @_;

    return unless $self;
    return if $self->{_shutdown};
    
    if ($self->{_ws} && $self->{_open}) {
        $self->{_log}->debug('connect skipped: already open');
        return;
    }

    $self->close();

    $self->{_last_pong}       = time();
    $self->_start_ping();

    $self->{_log}->info(
        'Opening websocket ' . $self->{_url}
    );

    $self->{_connecting} = 1;
    $self->{_pending} = {};

    my $ws = Slim::Networking::SimpleWS->new(
        $self->{_url},

        sub {
            eval { $self->_connected_callback(@_) };
            if ($@) {
                $self->{_log}->error(
                    "Connected callback error: $@"
                );
            }
        },

        sub {
            eval { $self->_error_callback(@_) };
            if ($@) {
                $self->{_log}->error(
                    "Constructor error callback: $@"
                );
            }
        }
    );

    $self->{_ws} = $ws;

    $ws->listenAsync(

        sub {
            eval { $self->_ws_callback(@_) };
            if ($@) {
                $self->{_log}->error(
                    "WS callback error: $@"
                );
            }
        },

        sub {
            eval { $self->_error_callback(@_) };
            if ($@) {
                $self->{_log}->error(
                    "listenAsync error callback: $@"
                );
            }
        }
    );
}

##############################################################################
# reconnect / timers
##############################################################################

sub _reconnect_timer_cb {
    my ($self) = @_;

    $self->{_reconnect_scheduled} = 0;

    return if $self->{_shutdown};
    return if $self->{_open};

    $self->{_log}->warn("Reconnect timer fired");

    eval { $self->connect(); };

    if ($@) {
        $self->{_log}->error("Reconnect failed: $@");
        $self->_schedule_reconnect("connect exception");
    }
}

sub _schedule_reconnect {
    my ($self, $reason) = @_;

    return if $self->{_shutdown};
    return if $self->{_reconnect_scheduled};
    
    $self->close();

    my $delay = $self->{_reconnect_delay};

    $self->{_reconnect_scheduled} = 1;
    $self->{_reconnecting} = 1;

    $self->{_log}->warn(
        "Reconnect scheduled in ${delay}s ($reason)"
    );

    Slim::Utils::Timers::setTimer(
        $self,
        Time::HiRes::time() + $delay,
        \&_reconnect_timer_cb
    );

    $self->{_reconnect_delay} *= 2;
    $self->{_reconnect_delay} = $self->{_reconnect_max}
        if $self->{_reconnect_delay} > $self->{_reconnect_max};
}

sub _ping_timer_cb {
    my ($self) = @_;

    $self->{_ping_scheduled} = 0;

    return if $self->{_shutdown};
    return unless $self->{_ws};
    
    if (!$self->{_auth}) {
        $self->{_log}->error("Auth timeout");
        $self->_error_callback();
        return;
    }

    if (!$self->{_ready}) {
        $self->{_log}->error("Ready timeout");
        $self->_error_callback();
        return;
    }

    if (time() - $self->{_last_pong} > 90) {
        $self->{_log}->warn("Ping timeout");
        $self->_error_callback();
        return;
    }

    eval {
        $self->_send_with_id(
            '"type":"ping"',
            MODE_PING
        );
    };

    if ($@) {
        $self->{_log}->error("Ping failed: $@");
        $self->_error_callback();
        return;
    }

    $self->_start_ping();
}

sub _start_ping {
    my ($self) = @_;

    return unless $self->{_ws};
    return if $self->{_ping_scheduled};

    $self->{_log}->debug("Start ping");
    
    $self->{_ping_scheduled} = 1;

    Slim::Utils::Timers::setTimer(
        $self,
        Time::HiRes::time() + 30,
        \&_ping_timer_cb
    );
}

##############################################################################
# callbacks
##############################################################################

sub _connected_callback {
    my ($self) = @_;

    return unless $self;

    $self->{_log}->info("Connected");

    Slim::Utils::Timers::killTimers($self, \&_reconnect_timer_cb);
    
    $self->{_reconnect_scheduled}=0;
    $self->{_reconnecting}    = 0;
    $self->{_connecting}      = 0;
    $self->{_open}            = 1;
    $self->{_reconnect_delay} = 5;
}

sub _error_callback {
    my ($self) = @_;

    return unless $self;
    return if $self->{_reconnecting};    
    return if $self->{_shutdown};

    $self->{_log}->error('Websocket error');

    $self->{_auth} = 0;
    $self->{_ready} = 0;
    $self->{_connecting} = 0;
    $self->{_open}  = 0;

    $self->_schedule_reconnect('socket error');

    my $cb = $self->{_on_error};
    eval { $cb->() if $cb; };
}

##############################################################################
# send helpers
##############################################################################

sub _send_with_id {
    my ($self, $buf, $mode, $entity) = @_;

    my $id = $self->{_id}++;

    if ($entity) {
        $self->{_entities}->commid($entity, $id);
        $self->{_new_entities}->commid($entity, $id);
    }

    $self->{_pending}{$id} = {
        mode   => $mode,
        entity => $entity,
        ts     => time(),
    };

    my $msg = '{"id":' . $id . ',' . $buf . '}';

    $self->{_log}->debug('Send message ' . $msg);

    $self->{_ws}->send($msg);

    return $id;
}

sub _enqueue {
    my ($self, $msg, $mode, $entity) = @_;

    push @{ $self->{_queue} },        $msg;
    push @{ $self->{_queue_mode} },   $mode;
    push @{ $self->{_queue_entity} }, $entity;
}

sub _send_next {
    my ($self) = @_;
    return unless @{ $self->{_queue} };

    my $msg    = shift @{ $self->{_queue} };
    my $mode   = shift @{ $self->{_queue_mode} };
    my $entity = shift @{ $self->{_queue_entity} };

    $self->_send_with_id($msg, $mode, $entity);
}

sub _send_or_enqueue {
    my ($self, $msg, $mode, $entity) = @_;

    if ($self->{_ready} && $self->{_open}) {
        $self->_send_with_id($msg, $mode, $entity);
    }
    else {
        $self->_enqueue($msg, $mode, $entity);

        if (!$self->{_open}) {
            $self->connect();
        }
    }
}

sub _on_ready {
    my ($self) = @_;

    if (@{ $self->{_queue} }) {
        $self->_send_next();
        return;
    }

    $self->{_ready} = 1;
}

##############################################################################
# public api
##############################################################################

sub send_command {
    my ($self, $id, $cmd, $level) = @_;

    my $entity = $self->{_entities}->by_id($id);
    return unless $entity;

    my $msg =
        '"return_response":false,' .
        $entity->create_call_service($cmd, $level);

    $self->_send_or_enqueue($msg, MODE_NONE, $entity);
}

sub entities {
    my ($self) = @_;
    return $self->{_entities}->all_entities();
}

sub entity_by_id {
    my ($self, $id) = @_;
    return $self->{_entities}->by_id($id);
}

sub subscribe_hidden_entity {
    my ($self, $id, $cb) = @_;

    $self->{_hidden_entity_id}          = $id;
    $self->{_subscribe_hidden_callback} = $cb;

    my $msg =
        '"type":"get_services_for_target",' .
        '"target":{"entity_id":["' . $id . '"]}';

    $self->_send_or_enqueue(
        $msg,
        MODE_GET_MORE_SERVICES
    );
}

sub clear_entities_id_in_error {
    my ($self) = @_;
    $self->{_entities_id_in_error} = {};
}

sub is_entity_id_in_error {
    my ($self, $id) = @_;
    return exists $self->{_entities_id_in_error}{$id};
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

##############################################################################
# entities extract helpers
##############################################################################

sub _add_entity_if_valid {
    my ($self, $id) = @_;
    return unless defined $id;
    return if ref($id);

    ################################################
    # filtre format domain.object
    ################################################
    return unless $id =~
        /^[a-z0-9_]+\.[a-z0-9_]+$/i;

    ################################################
    # éviter doublon
    ################################################
    return if $self->{_new_entities}->by_id($id);

    my $entity =
        Plugins::HAControl::Entity->new($id, 0);

    $self->{_new_entities}->add($entity);

    $self->{_log}->debug("Entity found: $id");
}

sub _extract_entity_id_field {
    my ($self, $val) = @_;
    return unless defined $val;

    if (!ref($val)) {
        $self->_add_entity_if_valid($val);
        return;
    }

    if (ref($val) eq 'ARRAY') {
        foreach my $e (@$val) {
            $self->_add_entity_if_valid($e);
        }
    }
}

sub _extract_entities_recursive {
    my ($self, $node) = @_;
    return unless defined $node;

    ############################################
    # ARRAY
    ############################################
    if (ref($node) eq 'ARRAY') {
        foreach my $item (@$node) {
            $self->_extract_entities_recursive($item);
        }
        return;
    }

    ############################################
    # HASH
    ############################################
    if (ref($node) eq 'HASH') {

        ################################################
        # 1. entity => light.xxx
        ################################################
        $self->_add_entity_if_valid($node->{entity});

        ################################################
        # 2. camera_image
        ################################################
        $self->_add_entity_if_valid($node->{camera_image});

        ################################################
        # 3. entities => [...]
        ################################################
        if (ref($node->{entities}) eq 'ARRAY') {

            foreach my $e (@{ $node->{entities} }) {

                if (!ref($e)) {
                    $self->_add_entity_if_valid($e);
                }
                elsif (ref($e) eq 'HASH') {
                    $self->_add_entity_if_valid($e->{entity});
                }
            }
        }

        ################################################
        # 4. target.entity_id
        ################################################
        if (ref($node->{target}) eq 'HASH') {
            $self->_extract_entity_id_field(
                $node->{target}{entity_id}
            );
        }

        ################################################
        # 5. service_data.entity_id
        ################################################
        if (ref($node->{service_data}) eq 'HASH') {
            $self->_extract_entity_id_field(
                $node->{service_data}{entity_id}
            );
        }

        ################################################
        # 6. data.entity_id
        ################################################
        if (ref($node->{data}) eq 'HASH') {
            $self->_extract_entity_id_field(
                $node->{data}{entity_id}
            );
        }

        ################################################
        # recurse all keys
        ################################################
        foreach my $k (keys %$node) {
            $self->_extract_entities_recursive($node->{$k});
        }

        return;
    }
}

##############################################################################
# main callback
##############################################################################

sub _ws_callback {
    my ($self, $buf) = @_;
    return unless $self;
    return if $self->{_shutdown};
    return unless $self->{_open};

    $self->{_log}->debug('Message: ' . $buf);

    my $decoded = eval { decode_json(encode_utf8($buf)) };
    if ($@) {
        $self->{_log}->error("JSON decode error: $@");
        return;
    }

    ######################################################################
    # recover request context by id
    ######################################################################
    my $ctx;
    if (exists $decoded->{id}) {
        $ctx = delete $self->{_pending}{ $decoded->{id} };
    }

    ######################################################################
    # AUTH FLOW
    ######################################################################

    if ($decoded->{type} eq 'auth_required') {

        my $msg = '{"type":"auth","access_token":"' .
                  $self->{_token} . '"}';

        $self->{_log}->debug('Send auth');
        $self->{_ws}->send($msg);
        return;
    }

    if ($decoded->{type} eq 'auth_ok') {

        $self->{_log}->debug('Auth OK');
        
        if ($self->{_dashboard}) {
            $self->_send_with_id(
                '"type":"lovelace/dashboards/list"',
                MODE_GET_LIST_BOARDS
            );
        }
        return;
    }

    if ($decoded->{type} eq 'auth_invalid') {
        $self->{_log}->error('Authentication failed');
        $self->_schedule_reconnect('auth invalid');
        return;
    }

    ######################################################################
    # PONG
    ######################################################################

    if ($decoded->{type} eq 'pong') {
        $self->{_last_pong} = time();
        $self->{_log}->debug('Pong received');
        return;
    }

    ######################################################################
    # RESULT SUCCESS
    ######################################################################

    if ($decoded->{type} eq 'result'
        && $decoded->{success}
        && !$decoded->{error})
    {
        unless ($ctx) {
            $self->{_log}->debug('Result without pending context');
            return;
        }

        ##############################################################
        # dashboards/list
        ##############################################################
        if ($ctx->{mode} == MODE_GET_LIST_BOARDS) {

            $self->{_log}->debug('Received dashboard list');

            foreach my $obj (@{ $decoded->{result} || [] }) {

                if (
                    lc($obj->{id} // '')       eq lc($self->{_dashboard}) ||
                    lc($obj->{title} // '')    eq lc($self->{_dashboard}) ||
                    lc($obj->{url_path} // '') eq lc($self->{_dashboard})
                ) {
                    $self->{_url_path} = $obj->{url_path};
                    last;
                }
            }

            $self->_send_with_id(
                '"type":"subscribe_events","event_type":"lovelace_updated"',
                MODE_SUBSCRIBE_BOARDS
            );
            return;
        }

        ##############################################################
        # subscribe lovelace updates
        ##############################################################
        if ($ctx->{mode} == MODE_SUBSCRIBE_BOARDS) {

            $self->_send_with_id(
                '"type":"lovelace/config","url_path":"' .
                $self->{_url_path} . '"',
                MODE_GET_ENTITIES
            );
            return;
        }

        ##############################################################
        # get entities
        ##############################################################
        if ($ctx->{mode} == MODE_GET_ENTITIES) {

            $self->{_new_entities} =
                Plugins::HAControl::Entities->new();

            $self->_extract_entities_recursive(
                $decoded->{result}
            );

            foreach my $entity (
                $self->{_new_entities}->all_entities()
            ) {

                my $msg =
                    '"type":"get_services_for_target",' .
                    '"target":{"entity_id":["' .
                    $entity->id() . '"]}';

                $self->_send_with_id(
                    $msg,
                    MODE_GET_SERVICES,
                    $entity
                );
            }

            return;
        }

        ##############################################################
        # get services
        ##############################################################
        if ($ctx->{mode} == MODE_GET_SERVICES) {

            my $entity = $ctx->{entity};
            return unless $entity;
            
            my $result = $decoded->{result};

            my $empty = 0;

            if (!defined $result) {
                $empty = 1;
            }
            elsif (ref($result) eq 'HASH') {
                $empty = !keys(%{$result});
            }
            elsif (ref($result) eq 'ARRAY') {
                $empty = !@{$result};
            }
            else {
                $empty = 1;
            }

            if ($empty) {
                $self->{_log}->warn(
                    'Empty services list received for entity ' .
                    $entity->id() .
                    ', reconnect later'
                );

                $self->_schedule_reconnect('empty services result');

                return;
            }
            
            $entity->analyse_services($result);

            if ($self->{_new_entities}->all_services_received()) {

                foreach my $e (
                    $self->{_new_entities}->all_entities()
                ) {
                    my $msg =
                        '"type":"subscribe_entities",' .
                        '"entity_ids":["' .
                        $e->id() . '"]';

                    $self->_send_with_id(
                        $msg,
                        MODE_SUBSCRIBE_ENTITIES,
                        $e
                    );
                }
            }

            return;
        }

        ##############################################################
        # get hidden entity services
        ##############################################################
        if ($ctx->{mode} == MODE_GET_MORE_SERVICES) {

            my $entity = $self->{_entities}->add(
                Plugins::HAControl::Entity->new(
                    $self->{_hidden_entity_id}, 1
                )
            );

            if ($entity) {
                $entity->analyse_services($decoded->{result});

                my $msg =
                    '"type":"subscribe_entities",' .
                    '"entity_ids":["' .
                    $entity->id() . '"]';

                $self->_send_with_id(
                    $msg,
                    MODE_SUBSCRIBE_MORE_ENTITIES,
                    $entity
                );
            }

            return;
        }

        return;
    }

    ######################################################################
    # RESULT ERROR
    ######################################################################

    if ($decoded->{type} eq 'result'
        && !$decoded->{success}
        && $decoded->{error})
    {
        my $msg = $decoded->{error}{message} || 'unknown error';

        $self->{_log}->error("HA error: $msg");

        my $cb = $self->{_subscribe_hidden_callback};

        if ($cb) {
            eval { $cb->(); };
            $self->{_subscribe_hidden_callback} = undef;
        }

        $self->_on_ready();
        return;
    }

    ######################################################################
    # EVENTS
    ######################################################################

    if ($decoded->{type} eq 'event'
        && $decoded->{event})
    {
        $self->{_log}->debug('Event received');
        ##############################################################
        # lovelace updated
        ##############################################################
        if (($decoded->{event}{event_type} || '') eq 'lovelace_updated')
        {
            my $path =
                $decoded->{event}{data}{url_path} || '';

            $self->{_log}->debug('Dashboard update received for '.$path);
            
            if ($path eq $self->{_url_path}) {
                $self->{_log}->info(
                    'Dashboard changed, reconnecting'
                );
                $self->close();
                $self->connect();
                return;
            }
        }

        ##############################################################
        # entity state update
        ##############################################################
        my $data = $decoded->{event};

        my $key;
        my $is_added = 0;
        my $entity_id;
        my $entity;

        $self->{_log}->debug('State (new or change) received');
        
        if ($data->{a}) {
            $self->{_log}->debug('New state received');
            $key = 'a';
            ($entity_id) = keys %{ $data->{a} };
            $self->{_log}->debug('Entity id is '.$entity_id);
            return unless $entity_id;
            $entity = $self->{_new_entities}->by_id($entity_id);
            $is_added = 1;
        }
        elsif ($data->{c}) {
            $self->{_log}->debug('Change state received');
            $key = 'c';
            ($entity_id) = keys %{ $data->{c} };
            $self->{_log}->debug('Entity id is '.$entity_id);
            return unless $entity_id;
            $entity = $self->{_entities}->by_id($entity_id);
        }

        return unless $entity;
        $self->{_log}->debug('Confirmed entity id is '.$entity->id());

        my $payload =
            $is_added
            ? $data->{$key}{$entity_id}
            : $data->{$key}{$entity_id}{'+'};

        my $attr = $payload->{a};

        if ($attr) {
            $self->{_log}->debug('Attributes received');

            $entity->friendly_name($attr->{friendly_name})
                if exists $attr->{friendly_name};

            $entity->options($attr->{options})
                if exists $attr->{options};

            $entity->min($attr->{min})
                if exists $attr->{min};

            $entity->max($attr->{max})
                if exists $attr->{max};

            $entity->step($attr->{step})
                if exists $attr->{step};

            $entity->mode($attr->{mode})
                if exists $attr->{mode};

            $entity->unit($attr->{unit_of_measurement})
                if exists $attr->{unit_of_measurement};

            $entity->current_position($attr->{current_position})
                if exists $attr->{current_position};

            $entity->current_position($attr->{brightness})
                if exists $attr->{brightness};
        }

        if (exists $payload->{s}) {
            $self->{_log}->debug('State received: '.$payload->{s});
            $entity->state($payload->{s});
        }

        ##############################################################
        # hidden entity completed
        ##############################################################
        if ($entity->is_hidden()) {
            $self->{_log}->debug('Hidden entity info received for '.$entity->id());

            if ($is_added) {
                $self->{_log}->debug('Calling callback');
                my $cb =
                    $self->{_subscribe_hidden_callback};

                if ($cb) {
                    eval { $cb->(); };
                    $self->{_subscribe_hidden_callback}
                        = undef;
                }

                $self->_on_ready();
            }

            return;
        }

        ##############################################################
        # init complete
        ##############################################################
        if ($is_added) {

            if ($self->{_new_entities}
                ->all_states_received())
            {
                $self->{_log}->debug('All states received, calling _on_init and _on_ready');

                $self->{_entities} =
                    $self->{_new_entities};

                my $cb = $self->{_on_init};

                eval { $cb->() if $cb; };

                $self->_on_ready();
            }

            return;
        }

        ##############################################################
        # normal update
        ##############################################################
        my $cb = $self->{_on_change};
        eval { $cb->($entity) if $cb; };

        return;
    }
}

1;

__END__
