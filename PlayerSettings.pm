package Plugins::HAControl::PlayerSettings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Alarm;

my $pluginprefs = preferences('plugin.HAControl');
my $serverprefs = preferences('server');

sub needsClient {
    return 1;
}

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_HACONTROL_PLAYER_SETTINGS');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/HAControl/settings/player.html');
}

sub prefs {
    my ($class, $client) = @_;

    return ($pluginprefs->client($client), Plugins::HAControl::Plugin::getPrefNames());
}

sub handler {
    my ($class, $client, $paramRef) = @_;

    my ($prefsClass, @prefs) = $class->prefs($client);
    my @alarmsObj = Slim::Utils::Alarm->getAlarms($client);
    my %savedAlarms;
    my %savedSnoozes;
    my $shallReset = 0;    
#    Data::Dump::dump(%domoAlarmsId);
#    Data::Dump::dump(%domoSnoozesId);
    
#    $Template::Stash::PRIVATE = undef;

    if ($paramRef->{'saveSettings'}) {
        # set undefined to 0, we don't wand undefined to be saved because it will be overwritten by default values
	foreach my $pref (@prefs) {
            if (! defined $paramRef->{'pref_' . $pref}) {
                $paramRef->{'pref_' . $pref} = 0;
            }
        }
        foreach my $alarm (@alarmsObj) {
            my $id = $alarm->id();
            $savedAlarms{$id} = $paramRef->{'alarmId' . $id};
            $savedSnoozes{$id} = $paramRef->{'snoozeId' . $id};
	}
        $prefsClass->set('alarms', \%savedAlarms);
        $prefsClass->set('snoozes', \%savedSnoozes);
        
        $shallReset = 1;
    }
    else {
        my $prefsAlarms = $prefsClass->get('alarms');
	my $prefsSnoozes = $prefsClass->get('snoozes');
        if ($prefsAlarms) {
            %savedAlarms = %{ $prefsAlarms };
        }
        if ($prefsSnoozes) {
            %savedSnoozes = %{ $prefsSnoozes };
        }
    }
#    Data::Dump::dump(%savedAlarms);
#    Data::Dump::dump(%savedSnoozes);

    my @alarms;
    foreach my $alarm (@alarmsObj) {
        my $id = $alarm->id();
        my %rec;
        $rec{"id"} = $id;
        $rec{"alarm"} = $savedAlarms{$id};
        $rec{"snooze"} = $savedSnoozes{$id};
        push @alarms, \%rec;
    }

    $paramRef->{'alarms'} = \@alarms;
    
#    Data::Dump::dump(\@alarms);
    
    my $result = $class->SUPER::handler($client, $paramRef);
    if ($shallReset) {
        Plugins::HAControl::Plugin::resetPref($client);
    }
    return $result;
}

1;

__END__
