Home Assistant Control
================

This is a [Squeezebox](http://www.mysqueezebox.com) (Squeeze / Logitech Media / Lyrion Music  Server) plugin for controlling [Home Assistant](https://www.home-assistant.io) entities from your Jive based player screen (Squeezebox radio, Squeezebox Touch, UE Smart Radio with squeezebox firmware and [Jive Lite](https://github.com/ralph-irving/jivelite) and its derivatives).

The plugin can control lights, covers, switches, button, boolean, select and number inputs.

Installation
------------

To install the plugin, add the repository URL https://guillaumezin.github.io/HAControl/repo.xml to your Lyrion plugin settings page then activate the plugin.

Usage
-----

1. For each player, go to the player settings page and choose Home Assistant Control settings.

1. There you can configure URL access for Home Assistant, access token (you can generate one in and Home Assistant dashboard name where you want to grab entities to get them on the player screen.

1. You can also associate alarms and snoozes with Home Assistant devices (switch commands only). This can be useful to activate Home Assistant automation through a switch input for instance.

1. You can associate a Home Assistant entity that will turn on and off at the same time as a player.

1. If you have [Custom Clock, Custom Clock Helper](http://wiki.slimdevices.com/index.php/Custom_Clock_applet) and [SuperDateTime (weather.com version 5.9.42 onwards)](https://sourceforge.net/projects/sdt-weather-com), Home Assistant can expose values based on entities state to Custom Clock Helper. The formatting is explained in Home Assistant settings of the player settings page.

1. Home Assistant control should appear on the main screen of your Jive based players.

Limitations
-----------

If an entity state changes while Home Assistant control is opened on your player, the change will not reflect until you go back to main screen and reopen Home Assistant control menu.

License
-------

This project is licensed under the MIT license - see the [LICENSE](LICENSE) file for details
