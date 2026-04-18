package Plugins::HAControl::Plugin;

use strict;

use base qw(Slim::Plugin::Base);
use JSON::XS::VersionOneAndTwo;
use POSIX qw(ceil floor);
use Scalar::Util qw(weaken);
use Slim::Control::Request;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Utils::Prefs;
use Time::HiRes;
use Slim::Utils::Strings qw (string);
use Plugins::HAControl::WebsocketHandler;
use Plugins::HAControl::Entities;
use Plugins::HAControl::Entity;

my %idxTimers  = ();
my %entity_id_in_error_timer = ();
my %websockets = ();
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

#sub enabled {
#}

my $defaultPrefs = {
    'address'                   => '127.0.0.1',
    'port'                      => 8123,
    'https'                     => 0,
    'password'                  => '',
    'dimmerAsOnOff'             => 1,
    'blindsPercentageAsOnOff'   => 1,
    'filterByName'              => '',
    'deviceOnOff'               => 0,
    'generalAlarm'              => '',
    'generalSnooze'             => '',
};

sub getPrefNames {
    my @prefNames = keys %$defaultPrefs;
    return @prefNames;
}

sub _clean_entity_id_in_error {
    my $client = shift;

    if (exists $entity_id_in_error_timer{$client->id}) {
        Slim::Utils::Timers::killSpecific($entity_id_in_error_timer{$client->id});
    }

    $websockets{$client->id}->clear_entities_id_in_error();
    $entity_id_in_error_timer{$client->id} = Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 600, \&_clean_entity_id_in_error);
}

sub initPref {
    my $client = shift;

    $log->debug('Init pref');

    unless ($websockets{$client->id}) {
        if ($prefs->client($client)->get('https') and not Slim::Networking::Async::HTTP->hasSSL()) {
            $log->error('No HTTPS support built in, but https URL required');
        }
        $prefs->client($client)->init($defaultPrefs);
        my $url =
            ($prefs->client($client)->get('https') ? 'wss://' : 'ws://') .
            $prefs->client($client)->get('address') . ':' . $prefs->client($client)->get('port') . '/api/websocket';
        $log->debug('Setting URL to '. $url);
        my $weak_client = $client;
        weaken($weak_client);    
        $websockets{$client->id} = Plugins::HAControl::WebsocketHandler->new($url, $prefs->client($client)->get('password'), $prefs->client($client)->get('filterByName'), $log, sub { _buildMenu($weak_client) }, sub { _buildMenu($weak_client) });
        $entity_id_in_error_timer{$client->id} = Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 600, \&_clean_entity_id_in_error);
    }
}

sub clientEvent {
    my $request = shift;
    my $client  = $request->client;

    $log->debug('Client event');

    if (defined $client) {
        $log->debug('Client event with client defined');
        initPref($client);
    }
}

sub resetPref {
    my $client = shift;

    $log->debug('Reset pref');

    if (exists $websockets{$client->id}) {
        $websockets{$client->id}->close();
        delete $websockets{$client->id};
    }
    initPref($client);
}

sub _setToHACallback {
    $log->debug('Got answer from HA after set');

    $log->debug('done');
}

sub _setToHAErrorCallback {
    my $http    = shift;
    my $error   = $http->error;

    if (defined $error) {
        $log->error("Got error after set: $error");
    }
    else {
        $log->error('No answer from HA after set');
    }
}

sub needsClient {
    return 1;
}

sub _setToHA {
    my $client = shift;
    my $idx = shift;
    my $cmd = shift;
    my $level = shift;

    $websockets{$client->id}->send_command($idx, $cmd, $level);
}

sub setToHA {
    my $request = shift;
    my $client  = $request->client();
    my $idx = $request->getParam('idx');
    my $cmd = $request->getParam('cmd');
    my $level = $request->getParam('level');

    _setToHA($client, $idx, $cmd, $level);

    $request->setStatusDone();
}

sub setToHATimer{
    my $request = shift;
    my $client  = $request->client();
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
    my $idx = $request->getParam('idx');
    my $level = $request->getParam('level');
    my $min = $request->getParam('min');
    my $max = $request->getParam('max');

    $log->debug('Slider menu');

    my $slider = {
        slider   => 1,
        min      => $min,
        max      => $max,
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

    $log->debug('done');
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
    my $client = shift;
    
    if (!defined($client)) {
        return;
    }

    my @menu;

    my @entities = $websockets{$client->id}->entities();

    $log->debug('Build menu after status change detected');

    foreach my $entity ( @entities ) {
        $log->debug('Test entry for id '.$entity->id());
        if (!$entity->is_hidden()) {
            if ($entity->is_selector()) {
                $log->debug('Add selector entry for id '.$entity->id());
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
            elsif ($entity->is_number()) {
                $log->debug('Add number entry for id '.$entity->id());

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
            elsif (($entity->is_cover_slider() && !$prefs->client($client)->get('blindsPercentageAsOnOff')) || ($entity->is_light_slider() && !$prefs->client($client)->get('dimmerAsOnOff'))) {
                $log->debug('Add slider entry for id '.$entity->id());
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
                            },
                        },
                    },
                };
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
                $log->debug('Add on/off entry for id '.$entity->id());
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
    }

    $menus{$client->id} = [@menu];
    Slim::Control::Request::notifyFromArray($client, ['pluginHAControlmenu']);
}

sub getFromHA {
    my $request = shift;
    my $client = $request->client();
    my @menu = @{ $menus{$client->id} // [] };

    $log->debug('Menu display called');

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

    $log->debug('done');
}

sub powerCallback {
    my $request = shift;
    my $client = $request->client() || return;
    my $cmd = 'on_off';
    my $level;
    my $idx = $prefs->client($client)->get('deviceOnOff');

    if ($idx > 0) {
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
    my $generalAlarm = $prefs->client($client)->get('generalAlarm');
    my $generalSnooze = $prefs->client($client)->get('generalSnooze');
    my $prefsAlarms = $prefs->client($client)->get('alarms');
    my $prefsSnoozes = $prefs->client($client)->get('snoozes');
    if ($prefsAlarms) {
        %alarms = %{ $prefsAlarms };
    }
    if ($prefsSnoozes) {
        %snoozes = %{ $prefsSnoozes };
    }

    #Data::Dump::dump($request);

    if ($alarmType eq 'sound') {
        $log->debug('Alarm on to HA: '. $alarmId);
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
        $log->debug('Alarm off to HA: '. $alarmId);
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
        $log->debug('Snooze on to HA: '. $alarmId);
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
        $log->debug('Snooze off to HA: '. $alarmId);
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

#TODO : à améliorer, "Processing request" une seule fois, ensuite je n'ai que du "Already processing"
sub _manageMacroStringQueue {
    my $request = shift;

    if (!$request) {
        $requestProcessing = 0;
        $log->debug('Next request');
        $request = shift @requestsQueue;
    }

    if ($request) {
        if (!$requestProcessing) {
            $log->debug('Processing request');
            my $client = $request->client();
            _macroStringResult($request);
        }
        else {
            push @requestsQueue, $request;
            $request->setStatusProcessing();
            $log->debug('Already processing, waiting for end of previous request');
        }
    }
    else {
        $log->debug('Request queue empty');
    }
}

sub _macroSubFunc {
    my $replaceStr = shift;
    my $func = shift;
    my $funcArg = shift;
    my $result = eval {
        if ($func eq 'truncate') {
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
        elsif ($func eq 'ceil') {
            return sprintf('%d', ceil($replaceStr + 0.0));
        }
        elsif ($func eq 'floor') {
            return sprintf('%d', floor($replaceStr + 0.0));
        }
        elsif ($func eq 'round') {
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
        $log->error('Error while trying to eval macro function: [' . $@ . ']');
        return $replaceStr;
    }
    else {
        return $result;
    }
}

sub _macroCallNextMacro {
    my $request = shift;
    my $result = shift;

    $request->addResult('macroString', $result);
    $log->debug('Result: ' . $result);

    if (defined $funcptr && ref($funcptr) eq 'CODE') {
        $log->debug('Calling next function');
        $request->addParam('format', $result);
        eval { &{$funcptr}($request) };

        # arrange for some useful logging if we fail
        if ($@) {
            $log->error('Error while trying to run function coderef: [' . $@ . ']');
            $request->setStatusBadDispatch();
            $request->dump('Request');
        }
    }
    else {
        $log->debug('Done');
        $request->setStatusDone();
    }
}

sub _macroStringResult {
    my $request = shift;
    my $client = $request->client();
    my $format = $request->getParam('format');
#     $format = 'test ~sensor.ebusd_f47_outsidetemp_temp~shorten~2~';
    my $result = $format;

    $log->debug('Search in results for ' . $format);
    while ($format =~ /(~(\S+?)(~(\S+?))?(~(\S+?))?~)/g) {
        $log->debug('Got match name');
        my $whole = $1;
        my $id = $2;
        my $func = $4;
        my $funcArg = $6;

        if ($websockets{$client->id}->is_entity_id_in_error($id)) {
            $log->debug('Skip ' . $id);
            next;
        }

        my $entity = $websockets{$client->id}->entity_by_id($id);
        if ($entity) {
            $log->debug('Found element name ' . $id);
            my $replaceStr = _macroSubFunc($entity->state(), $func, $funcArg);
            $log->debug('Will replace by: ' . $replaceStr);
            $result =~ s/\Q${whole}\E/${replaceStr}/;
        }
        else {
            $request->setStatusProcessing();
            $requestProcessing = 1;
            $websockets{$client->id}->subscribe_hidden_entity($id, sub { _macroStringResult($request) });
            return;
        }
    }

    _macroCallNextMacro($request, $result);
    _manageMacroStringQueue(undef);
}

sub macroString {
    my $request = shift;
    my $format = $request->getParam('format');
#     $format = 'test ~sensor.ebusd_f47_outsidetemp_temp~shorten~2~';

    $log->debug('Inside CLI request macroString for ' . $format . ' status ' . $request->getStatusText());

    # Check that there is a pattern for us
    if ($format =~ m/~\S+~/) {
        _manageMacroStringQueue($request);
    }
    # No pattern, jump to next dispatched sdtMacroString
    else {
        $log->debug('No pattern for us');
        _macroCallNextMacro($request, $format);
    }
}

sub initPlugin {
    my $class = shift;

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
    Slim::Control::Jive::registerPluginMenu(\@menu, 'home');

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
    Slim::Control::Request::unsubscribe(\&clientEvent);
    Slim::Control::Request::unsubscribe(\&setAlarmToHA);
    Slim::Control::Request::unsubscribe(\&powerCallback);
    Slim::Control::Jive::deleteMenuItem('pluginHAControlmenu');
}

1;

__END__
