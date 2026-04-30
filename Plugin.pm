package Plugins::HAControl::Plugin;

use strict;

use base qw(Slim::Plugin::Base);
use JSON::XS::VersionOneAndTwo;
use POSIX qw(ceil floor);
use Slim::Control::Request;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Utils::Prefs;
use Time::HiRes;
use Slim::Utils::Strings qw(cstring);
use Plugins::HAControl::WebsocketHandler;
use Plugins::HAControl::Entities;
use Plugins::HAControl::Entity;
use Plugins::HAControl::Log;
use Scalar::Util qw(looks_like_number);

my $PLUGIN_SHUTTING_DOWN = 0;

my %idxTimers  = ();
my %entity_id_in_error_timer = ();
my %websockets = ();
my %clientlogs  = ();
my %menus = ();
my $funcptr = undef;
my @requestsQueue = ();
my $requestProcessing = 0;

use constant CACHE_TIME              => 30;

sub getDisplayName {
    return 'PLUGIN_HACONTROL';
}

my $log = Slim::Utils::Log->addLogCategory({
    'category' => 'plugin.HAControl',
    'defaultLevel' => 'ERROR',
    'description' => getDisplayName(),
});

my $prefs = preferences('plugin.HAControl');

my $defaultPrefs = {
    'address'                   => '127.0.0.1',
    'port'                      => 8123,
    'wss'                       => 0,
    'password'                  => '',
    'dimmerHideSlider'          => 0,
    'dimmerHideOnOff'           => 0,
    'blindsPercentageHideSlider'=> 0,
    'blindsPercentageHideOnOff' => 0,
    'filterByName'              => '',
    'deviceOnOff'               => 0,
    'menuEnable'                => 0,
    'connectionEnable'          => 0,
    'generalAlarm'              => '',
    'generalSnooze'             => '',
};

sub getPrefNames {
    my @prefNames = keys %$defaultPrefs;
    return @prefNames;
}

sub _trim {
   return $_[0] =~ s/\A\s+|\s+\z//urg;
}

sub _log {
    my $client = shift;
    
    if ($client) {
        unless ($clientlogs{$client->id}) {
            $clientlogs{$client->id} = Plugins::HAControl::Log->new($log, $client->id);
        }
        return $clientlogs{$client->id};
    }
    else {
        return $log;
    }
}

sub _clean_entity_id_in_error {
    my $client = shift || return;

    if (exists $entity_id_in_error_timer{$client->id}) {
        Slim::Utils::Timers::killSpecific($entity_id_in_error_timer{$client->id});
    }

    $websockets{$client->id}->clear_entities_id_in_error();
    $entity_id_in_error_timer{$client->id} = Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 600, \&_clean_entity_id_in_error);
}

sub _onInit {
    my $client = shift || return;
    _log($client)->debug('_onInit');
    _buildMenu($client);
    _refreshMenu($client, 1);
}

sub _onError {
    my $client = shift || return;
    _log($client)->debug('_onError');
    _refreshMenu($client, 0);
}

sub initPref {
    return if $PLUGIN_SHUTTING_DOWN;
    my $client = shift || return;
    
    _log($client)->debug('Init pref');
    
    if ($prefs->client($client)->get('connectionEnable')) {
        unless ($websockets{$client->id}) {
            if ($prefs->client($client)->get('wss') and not Slim::Networking::Async::HTTP->hasSSL()) {
                _log($client)->error('No SSL support built in, but wss required');
            }
            $prefs->client($client)->init($defaultPrefs);
            if ($prefs->client($client)->get('address')) {
                my $url =
                    ($prefs->client($client)->get('wss') ? 'wss://' : 'ws://') .
                    _trim($prefs->client($client)->get('address')) . ':' . $prefs->client($client)->get('port') . '/api/websocket';
                _log($client)->debug('Setting URL to '. $url);
                if ($prefs->client($client)->get('menuEnable')) {
                    _log($client)->debug('Menu enabled');
                }
                else {
                    _log($client)->debug('Menu disabled');
                    _refreshMenu($client, 0);
                }
                my $dashboard = $prefs->client($client)->get('menuEnable') ? _trim($prefs->client($client)->get('filterByName')) : '';
                _log($client)->debug('Setting dashboard to '. $dashboard);
                $websockets{$client->id} = Plugins::HAControl::WebsocketHandler->new($url, _trim($prefs->client($client)->get('password')), $dashboard, _log($client), sub { _onInit($client) }, sub { _buildMenu($client) }, sub { _onError($client) });
                $entity_id_in_error_timer{$client->id} = Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 600, \&_clean_entity_id_in_error);
            }
        }
    }
}

sub clientEvent {
    return if $PLUGIN_SHUTTING_DOWN;
    my $request = shift;
    my $client = $request->client();

    _log($client)->debug('Client event');

    if (defined $client) {
        initPref($client);
        _log($client)->debug('Client event with client defined '.$client->id);
    }
}

sub resetPref {
    return if $PLUGIN_SHUTTING_DOWN;
    my $client = shift || return;

    _log($client)->debug('Reset pref');

    if (exists $websockets{$client->id}) {
        $websockets{$client->id}->close();
        delete $websockets{$client->id};
    }
    initPref($client);
}

sub needsClient {
    return 1;
}

sub _setToHA {
    my $client = shift || return;
    my $idx = shift;
    my $cmd = shift;
    my $level = shift;

    $websockets{$client->id}->send_command($idx, $cmd, $level);
}

sub setToHA {
    my $request = shift;
    my $client = $request->client() || return;
    my $idx = $request->getParam('idx');
    my $cmd = $request->getParam('cmd');
    my $level = $request->getParam('level');

    _setToHA($client, $idx, $cmd, $level);

    $request->setStatusDone();
}

sub setToHATimer{
    my $request = shift;
    my $client = $request->client() || return;
    my $idx = $request->getParam('idx');
    my $cmd = $request->getParam('cmd');
    my $level = $request->getParam('level');

    if (exists $idxTimers{$idx}) {
        Slim::Utils::Timers::killSpecific($idxTimers{$idx});
    }

    $idxTimers{$idx} = Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&_setToHA, $idx, $cmd, $level);

    $request->setStatusDone();
}


sub menuHADimmer {
    my $request = shift;
    my $client = $request->client() || return;
    my $idx = $request->getParam('idx');
    my $level = $request->getParam('level');
    my $min = $request->getParam('min');
    my $max = $request->getParam('max');
    my $text = $request->getParam('text');

    _log($client)->debug('Slider menu');
    
    my $slider = {
        slider   => 1,
        min      => $min,
        max      => $max,
        text     => $text,
        initial  => $level,
        actions  => {
            do   => {
                player => 0,
                cmd    => ['setToHATimer'],
                params => {
                    idx    => $idx,
                    cmd    => 'slider',
                    valtag => 'level',
                },
            },
        },
    };

    $request->addResult('offset', 0);
    $request->addResult('count', 1);
    $request->setResultLoopHash('item_loop', 0, $slider);

    $request->setStatusDone();

    _log($client)->debug('done');
}


sub _strMatch {
    my $strmatch = shift;
    my $strToCheck = shift;

    if (
        !($strmatch eq '')
        && ($strToCheck !~ $strmatch)
    ) {
        return 0;
    }

    return 1;
}

sub _buildMenu {
    my $client = shift || return;
    
    if (!defined($client)) {
        return;
    }

    my @menu;

    my @entities = $websockets{$client->id}->entities();

    _log($client)->debug('Build menu after status change detected');

    foreach my $entity ( @entities ) {
        _log($client)->debug('Test entry for id '.$entity->id());
        next if $entity->is_hidden();
        if ($entity->is_selector()) {
            _log($client)->debug('Add selector entry for id '.$entity->id());
            my @options = $entity->options();
            my @choiceActions;
            my $index = 0;
            my $i = 0;
            foreach my $option (@options) {
                if ($option eq $entity->state()) {
                    $index = $i;
                }
                $i++;
                push @choiceActions,
                {
                    player => 0,
                    cmd    => ['setToHA'],
                    params => {
                        idx    => $entity->id(),
                        cmd    => 'selector',
                        level  => $option,
                    },
                },
            }
            push @menu, {
                text          => $entity->friendly_name(),
                selectedIndex => $index,
                choiceStrings => [ @options ],
                actions  => {
                    do => {
                        choices => [ @choiceActions ],
                    },
                },
            };
        }
        elsif ($entity->is_number() && $entity->is_slider()) {
            _log($client)->debug('Add number slider entry for id '.$entity->id());
            push @menu, {
                text     => $entity->friendly_name(),
                actions  => {
                    go => {
                        player => 0,
                        cmd    => ['menuHADimmer'],
                        params => {
                            idx    => $entity->id(),
                            level  => $entity->state(),
                            min    => $entity->min(),
                            max    => $entity->max(),
                            text   => cstring($client, 'PLUGIN_HACONTROL_INITIAL_VALUE').' '.($entity->unit() ? $entity->state().' '.$entity->unit() : $entity->state()),
                        },
                    },
                },
            };
        }
        elsif ($entity->is_number()) {
            _log($client)->debug('Add number box entry for id '.$entity->id());
            push @menu, {
                text     => $entity->friendly_name(),
                nextWindow => 'parent',
                input    => {
                    initialText => $entity->state(),
                    len => 1,
                    allowedChars => '.0123456789',
                },
                window   => {
                    text => $entity->friendly_name(),
                },
                actions  => {
                    go => {
                        player => 0,
                        cmd    => ['setToHA'],
                        params => {
                            idx    => $entity->id(),
                            cmd    => 'number',
                            level  => '__TAGGEDINPUT__',
                        },
                    },
                },
            };
        }
        elsif ($entity->is_cover_slider() || $entity->is_light_slider()) {
            if (($entity->is_cover_slider() && !$prefs->client($client)->get('blindsPercentageHideOnOff')) || ($entity->is_light_slider() && !$prefs->client($client)->get('dimmerHideOnOff'))) {
                _log($client)->debug('Add on/off slider entry for id '.$entity->id());
                push @menu, {
                    text     => $entity->friendly_name(),
                    checkbox => $entity->boolean_state(),
                    actions  => {
                        on   => {
                            player => 0,
                            cmd    => ['setToHA'],
                            params => {
                                idx    => $entity->id(),
                                cmd    => 'on_off',
                                level  => 1,
                            },
                        },
                        off  => {
                            player => 0,
                            cmd    => ['setToHA'],
                            params => {
                                idx    => $entity->id(),
                                cmd    => 'on_off',
                                level  => 0,
                            },
                        },
                    },
                };
            }
            if (($entity->is_cover_slider() && !$prefs->client($client)->get('blindsPercentageHideSlider')) || ($entity->is_light_slider() && !$prefs->client($client)->get('dimmerHideSlider'))) {
                _log($client)->debug('Add slider entry for id '.$entity->id());
                push @menu, {
                    text     => $entity->friendly_name(),
                    actions  => {
                        go => {
                            player => 0,
                            cmd    => ['menuHADimmer'],
                            params => {
                                idx    => $entity->id(),
                                level  => $entity->current_position(),
                                min    => $entity->min(),
                                max    => $entity->max(),
                                #text   => cstring($client, 'PLUGIN_HACONTROL_INITIAL_VALUE').' '. $entity->unit() ? $entity->percent().' '.$entity->unit() : $entity->percent(),
                                text   => '',
                            },
                        },
                    },
                };
            }
        }
        elsif ($entity->is_press()) {
            push @menu, {
                text     => $entity->friendly_name(),
                radio    => 0,
                nextWindow => 'refresh',
                actions  => {
                    do   => {
                        player => 0,
                        cmd    => ['setToHA'],
                        params => {
                            idx    => $entity->id(),
                            cmd    => 'press',
                            level  => 1,
                        },
                    },
                },
            };
        }
        # Normal On/Off
        elsif ($entity->is_on_off()) {
            _log($client)->debug('Add on/off entry for id '.$entity->id());
            push @menu, {
                text     => $entity->friendly_name(),
                checkbox => $entity->boolean_state(),
                actions  => {
                    on   => {
                        player => 0,
                        cmd    => ['setToHA'],
                        params => {
                            idx    => $entity->id(),
                            cmd    => 'on_off',
                            level  => 1,
                        },
                    },
                    off  => {
                        player => 0,
                        cmd    => ['setToHA'],
                        params => {
                            idx    => $entity->id(),
                            cmd    => 'on_off',
                            level  => 0,
                        },
                    },
                },
            };
        }
    }

    $menus{$client->id} = [@menu];
}

sub getFromHA {
    my $request = shift;
    my $client = $request->client() || return;
    my @menu = @{ $menus{$client->id} // [] };

    _log($client)->debug('Menu display called');

    my $numitems = scalar(@menu);

    $request->addResult('count', $numitems);
    $request->addResult('offset', 0);

    if ($numitems > 0) {
        my $cnt = 0;
        for my $eachPreset (@menu) {
            $request->setResultLoopHash('item_loop', $cnt, $eachPreset);
            $cnt++;
        }
    }

    $request->setStatusDone();

    _log($client)->debug('done');
}

sub powerCallback {
    my $request = shift;
    my $client = $request->client() || return;
    my $cmd = 'on_off';
    my $level;
    my $idx = $prefs->client($client)->get('deviceOnOff');

    if ($idx) {
        if ($client->power()) {
            $level = 1;
        }
        else {
            $level = 0;
        }
        initPref($client);
        _setToHA($client, $idx, $cmd, $level);
    }
}

sub setAlarmToHA {
    my $request = shift;
    my $client  = $request->client() || return;
    my $alarmType = $request->getRequest(1);
    my $alarmId = $request->getParam('_id');
    my $idx;
    my $level;
    my $cmd = 'on_off';
    my %alarms;
    my %snoozes;
    initPref($client);
    my $generalAlarm = _trim($prefs->client($client)->get('generalAlarm'));
    my $generalSnooze = _trim($prefs->client($client)->get('generalSnooze'));
    my $prefsAlarms = _trim($prefs->client($client)->get('alarms'));
    my $prefsSnoozes = _trim($prefs->client($client)->get('snoozes'));
    if ($prefsAlarms) {
        %alarms = %{ $prefsAlarms };
    }
    if ($prefsSnoozes) {
        %snoozes = %{ $prefsSnoozes };
    }

    #Data::Dump::dump($request);

    if ($alarmType eq 'sound') {
        _log($client)->debug('Alarm on to HA: '. $alarmId);
        $idx = $alarms{$alarmId};
        $level = 1;
        if ($idx) {
            _setToHA($client, $idx, $cmd, $level);
        }
        if ($generalAlarm) {
            _setToHA($client, $generalAlarm, $cmd, $level);
        }
    }
    elsif ($alarmType eq 'end') {
        _log($client)->debug('Alarm off to HA: '. $alarmId);
        $idx = $alarms{$alarmId};
        $level = 0;
        if ($idx) {
            _setToHA($client, $idx, $cmd, $level);
        }
        if ($generalAlarm) {
            _setToHA($client, $generalAlarm, $cmd, $level);
        }
    }
    elsif ($alarmType eq 'snooze') {
        _log($client)->debug('Snooze on to HA: '. $alarmId);
        $idx = $snoozes{$alarmId};
        $level = 1;
        if ($idx) {
            _setToHA($client, $idx, $cmd, $level);
        }
        if ($generalSnooze) {
            _setToHA($client, $generalSnooze, $cmd, $level);
        }
    }
    elsif ($alarmType eq 'snooze_end') {
        _log($client)->debug('Snooze off to HA: '. $alarmId);
        $idx = $snoozes{$alarmId};
        $level = 0;
        if ($idx) {
            _setToHA($client, $idx, $cmd, $level);
        }
        if ($generalSnooze) {
            _setToHA($client, $generalSnooze, $cmd, $level);
        }
    }
}

sub _manageMacroStringQueue {
    my $request = shift;
    my $client  = $request->client() || return;

    if (!$request) {
        $requestProcessing = 0;
        _log($client)->debug('Next request');
        $request = shift @requestsQueue;
    }

    if ($request) {
        if (!$requestProcessing) {
            _log($client)->debug('Processing request');
            my $client = $request->client();
            _macroStringResult($request);
        }
        else {
            push @requestsQueue, $request;
            $request->setStatusProcessing();
            _log($client)->debug('Already processing, waiting for end of previous request');
        }
    }
    else {
        _log($client)->debug('Request queue empty');
    }
}

sub _macroSubFunc {
    my $client = shift || return;
    my $replaceStr = shift;
    my $func = shift;
    my $funcArg = shift;
    my $isNumber = looks_like_number($replaceStr);
    my $result = eval {
        if ($isNumber && ($func eq 'truncate')) {
            my $dec = $funcArg + 0; 
            if ($dec > 0) {
                my $val = $replaceStr + 0.0;
                my $factor = 10**$dec;
                return ($val < 0) ? ceil($val*$factor)/$factor : floor($val*$factor)/$factor;
            }
            else {
                return $replaceStr; 
            }
        }
        elsif ($isNumber && ($func eq 'ceil')) {
            return sprintf('%d', ceil($replaceStr + 0.0));
        }
        elsif ($isNumber && ($func eq 'floor')) {
            return sprintf('%d', floor($replaceStr + 0.0));
        }
        elsif ($isNumber && ($func eq 'round')) {
            my $dec = $funcArg + 0; 
            if ($dec > 0) {
                my $val = $replaceStr + 0.0;
                my $factor = 10**$dec;
                return ($val < 0) ? ceil($val*$factor-0.5)/$factor : floor($val*$factor+0.5)/$factor;
            }
            else {
                return $replaceStr; 
            }
        }
        elsif ($func eq 'shorten') {
            return substr($replaceStr, 0, $funcArg + 0);
        }
        else {
            return $replaceStr;
        }
    };
    if ($@) {
        _log($client)->error('Error while trying to eval macro function: [' . $@ . ']');
        return $replaceStr;
    }
    else {
        return $result;
    }
}

sub _macroCallNextMacro {
    my $request = shift;
    my $client = $request->client() || return;
    my $result = shift;

    $request->addResult('macroString', $result);
    _log($client)->debug('Result: ' . $result);

    if (defined $funcptr && ref($funcptr) eq 'CODE') {
        _log($client)->debug('Calling next function');
        $request->addParam('format', $result);
        eval { &{$funcptr}($request) };

        # arrange for some useful logging if we fail
        if ($@) {
            _log($client)->error('Error while trying to run function coderef: [' . $@ . ']');
            $request->setStatusBadDispatch();
            $request->dump('Request');
        }
    }
    else {
        _log($client)->debug('Done');
        $request->setStatusDone();
    }
}

sub _macroStringResult {
    my $request = shift;
    my $client = $request->client() || return;
    my $format = $request->getParam('format');
#     $format = 'test ~sensor.ebusd_f47_outsidetemp_temp~shorten~2~';
    my $result = $format;

    _log($client)->debug('Search in results for ' . $format);
    while ($format =~ /(~(\S+?)(~(\S+?))?(~(\S+?))?~)/g) {
        _log($client)->debug('Got match name');
        my $whole = $1;
        my $id = $2;
        my $func = $4;
        my $funcArg = $6;

        if ($websockets{$client->id}) {
            if ($websockets{$client->id}->is_entity_id_in_error($id)) {
                _log($client)->debug('Skip ' . $id);
                next;
            }

            my $entity = $websockets{$client->id}->entity_by_id($id);
            if ($entity) {
                _log($client)->debug('Found element name ' . $id);
                my $replaceStr = _macroSubFunc($client, $entity->state(), $func, $funcArg);
                _log($client)->debug('Will replace by: ' . $replaceStr);
                $result =~ s/\Q${whole}\E/${replaceStr}/;
            }
            else {
                $request->setStatusProcessing();
                $requestProcessing = 1;
                $websockets{$client->id}->subscribe_hidden_entity($id, sub { _macroStringResult($request) });
                return;
            }
        }
    }

    _macroCallNextMacro($request, $result);
    _manageMacroStringQueue(undef);
}

sub macroString {
    my $request = shift;
    my $client = $request->client() || return;
    my $format = $request->getParam('format');
#     $format = 'test ~sensor.ebusd_f47_outsidetemp_temp~shorten~2~';

    initPref($client);
    _log($client)->debug('Inside CLI request macroString for ' . $format . ' status ' . $request->getStatusText());

    # Check that there is a pattern for us
    if ($format =~ m/~\S+~/) {
        _manageMacroStringQueue($request);
    }
    # No pattern, jump to next dispatched sdtMacroString
    else {
        _log($client)->debug('No pattern for us');
        _macroCallNextMacro($request, $format);
    }
}

sub _refreshMenu {
    my $client = shift || return;
    my $display = shift;

    if (!$display || !$prefs->client($client)->get('menuEnable')) {
        _log($client)->debug('Delete menu');
        Slim::Control::Jive::deleteMenuItem('pluginHAControlmenu', $client);
        return;
    }

    my @menu = ({
        stringToken => getDisplayName(),
        id          => 'pluginHAControlmenu',
        'icon-id' => Plugins::HAControl::Plugin->_pluginDataFor('icon'),
        weight      => 50,
        actions     => {
            go => {
                player => 0,
                cmd => ['pluginHAControlmenu'],
            }
        }
    });

    _log($client)->debug('Add menu');
    Slim::Control::Jive::registerPluginMenu(
        \@menu,
        'home',
        $client
    );
}

sub initPlugin {
    my $class = shift;

    $PLUGIN_SHUTTING_DOWN = 0;

    Slim::Control::Request::unsubscribe(\&clientEvent);
    Slim::Control::Request::unsubscribe(\&setAlarmToHA);
    Slim::Control::Request::unsubscribe(\&powerCallback);

    if (main::WEBUI) {
        require Plugins::HAControl::PlayerSettings;
        Plugins::HAControl::PlayerSettings->new();
    }

    $class->SUPER::initPlugin();

                                                        #        |requires Client
                                                        #        |  |is a Query
                                                        #        |  |  |has Tags
                                                        #        |  |  |  |Function to call
                                                        #        C  Q  T  F
    $funcptr = Slim::Control::Request::addDispatch(['sdtMacroString'], [1, 1, 1, \&macroString]);
    Slim::Control::Request::addDispatch(['menuHADimmer'],[1, 0, 1, \&menuHADimmer]);
    Slim::Control::Request::addDispatch(['setToHA'],[1, 0, 1, \&setToHA]);
    Slim::Control::Request::addDispatch(['setToHATimer'],[1, 0, 1, \&setToHATimer]);
    Slim::Control::Request::addDispatch(['pluginHAControlmenu'],[1, 0, 1, \&getFromHA]);

    my @menu = ({
        stringToken   => getDisplayName(),
        id     => 'pluginHAControlmenu',
        'icon-id' => Plugins::HAControl::Plugin->_pluginDataFor('icon'),
        weight => 50,
        actions => {
            go => {
                player => 0,
                cmd => ['pluginHAControlmenu'],
            }
        }
    });

#    Slim::Control::Jive::registerAppMenu(\@menu);
#    $class->addNonSNApp();
#    Slim::Control::Jive::registerPluginMenu(\@menu, 'extras');
#    Slim::Control::Jive::registerPluginMenu(\@menu, 'home');

    # Subscribe to on/off
    Slim::Control::Request::subscribe(
            \&powerCallback,
            [['power']]
    );

    # Subscribe to alarms
    Slim::Control::Request::subscribe(
            \&setAlarmToHA,
            [['alarm'],['sound', 'end', 'snooze', 'snooze_end']]
    );

    # Init pref when client connects
    Slim::Control::Request::subscribe(
        \&clientEvent,
        [['client'],['new','reconnect','disconnect']]
    );
}

sub shutdownPlugin {
    my $class = shift;

    $PLUGIN_SHUTTING_DOWN = 1;

    Slim::Control::Request::unsubscribe(\&clientEvent);
    Slim::Control::Request::unsubscribe(\&setAlarmToHA);
    Slim::Control::Request::unsubscribe(\&powerCallback);

    Slim::Control::Jive::deleteMenuItem('pluginHAControlmenu');

    foreach my $t (values %idxTimers) {
        eval { Slim::Utils::Timers::killSpecific($t); };
    }

    foreach my $t (values %entity_id_in_error_timer) {
        eval { Slim::Utils::Timers::killSpecific($t); };
    }

    foreach my $id (keys %websockets) {
        eval { $websockets{$id}->shutdown(); };
    }

    %idxTimers = ();
    %entity_id_in_error_timer = ();
    %websockets = ();
    %menus = ();

    @requestsQueue = ();
    $requestProcessing = 0;
}

1;

__END__
