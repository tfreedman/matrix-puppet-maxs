# matrix-puppet-maxs

This is a puppeting bridge for Project MAXS, that demuxes a single Matrix room containing all MAXS traffic into multiple rooms, with each room representing a phone number you're contacting. In simpler terms, after installing a pile of software, you can use it to send/receive text messages from your computer or Android phone using Matrix, to the point where you won't need an actual SMS app on your phone.

## What is Project MAXS?

From http://projectmaxs.org/homepage/ :
"MAXS (Modular Android XMPP Suite), a set of open-source GPLv3 licensed Android applications, allows you to control your Android device and receive notifications over XMPP. For example, you can compose and send a SMS message on your desktop/laptop by sending a command message from every standard compliant XMPP client to MAXS running on your smartphone"

## Okay, how does Matrix fit into this?

Programs exist (called bridges) that will connect from Matrix to some other protocol (in this case, XMPP), and relay traffic between the two networks. This means that if you have an XMPP server that MAXS is talking to, you can have a Matrix bot copy/paste all messages it sends and receives to Matrix. An example XMPP Matrix bridge is called mxpp, and can be found here: https://github.com/anewusername/mxpp

## What exactly does this do?

When you use mxpp + MAXS, all traffic to and from your phone is dumped into a single Matrix room. To send a text message saying 'hey' to a phone number, you have to prefix every outgoing message with 'sms send some-phone-number  hey'. Likewise, all phone calls will show up in the room the same way. This is fine in the sense that it works, but it gets annoying over time. A better solution is to create one room for each phone number, such that all messages to and from that room automatically go to the right place. The latter is what this program does - if you send a message in the channel #phone_4165551234:your-home-server, it'll be sent as an SMS message to 4165551234, and if you receive a reply from that number, it'll show up in that room as a message.

## What about just changing MAXS to work using Matrix instead - why does this need AppService permissions?

Unfortunately, it isn't that simple. We can definitely ditch the MAXS <--XMPP--> XMPP Server <--mxpp--> Matrix part of the equation by replacing maxs-transport-xmpp with a hypothetical maxs-transport-matrix, but that's still only a partial solution. It would, at minimum, have the following problems:

* MAXS would be limited to a single user account (you can open multiple chat rooms, but all of them would have the same person inside them) - to send an SMS message to a random phone number, you'd have to create a room (e.g. #phone_4165551234), invite MAXS to the room, and then send a message to the room. Using an AS, we can allow you to join #phone_4165551234 to send a message to that number, but more importantly, we can make the message appear to come from a user account specific to that one number (@phone_4165551234).

* Messages sent from other Android SMS apps wouldn't be able to show up as coming from you within Matrix. Using an AS with Puppetting support means that when you send an SMS from your phone, you'll see a message that looks like it came from you within the respective Matrix chat window.

For more information on puppetting, see: https://github.com/matrix-hacks/matrix-puppet-bridge#q-whats-puppetting-and-why-does-this-use-it.

## How does it work?

Project MAXS by default talks over XMPP - it's a modular project in the sense that you can swap out the communication protocol it uses, but to date only maxs-transport-xmpp exists. We 

## installation

clone this repo

cd into the directory

run `bundle install`

then:

run `ruby maxs.rb`

## configure

Copy `config.sample.json` to `config.json` and update it to match your setup.

## register the app service

Generate a `maxs-registration.yaml` file 

Note: The 'registration' setting in the config.json needs to set to the path of this file. By default, it already is.

Copy this `maxs-registration.yaml` file to your home server. Make sure that from the perspective of the homeserver, the url is correctly pointing to your bridge server. e.g. `url: 'http://your-bridge-server.example.org:8090'` and is reachable.

Edit your homeserver.yaml file and update the `app_service_config_files` with the path to the `maxs-registration.yaml` file.

Launch the bridge with ```ruby maxs.rb```.

Restart your HS.

## Features and Roadmap

 - [x] Call notifications
 - [x] SMS sending / receiving
 - [x] Control room (for non SMS / call MAXS features)

