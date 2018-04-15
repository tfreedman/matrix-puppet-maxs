# matrix-puppet-maxs

This is a puppeting bridge for Project MAXS, that demuxes a single Matrix room containing all MAXS traffic into multiple rooms, with each room representing a phone number you're contacting. In simpler terms, after installing a pile of software, you can use it to send/receive text messages from your computer or Android phone using Matrix, to the point where you won't need an actual SMS app on your phone.

## What is Project MAXS?

From http://projectmaxs.org/homepage/ :
"MAXS (Modular Android XMPP Suite), a set of open-source GPLv3 licensed Android applications, allows you to control your Android device and receive notifications over XMPP. For example, you can compose and send a SMS message on your desktop/laptop by sending a command message from every standard compliant XMPP client to MAXS running on your smartphone"

## Okay, how does Matrix fit into this?

Programs exist (called bridges) that will connect from Matrix to some other protocol (in this case, XMPP), and relay traffic between the two networks. This means that if you have an XMPP server that MAXS is talking to, you can have a Matrix bot copy/paste all messages it sends and receives to Matrix. An example XMPP Matrix bridge is called mxpp, and can be found here: https://github.com/anewusername/mxpp

## What exactly does this do?

When you use mxpp + MAXS, all traffic to and from your phone is dumped into a single Matrix room. To send a text message saying 'hey' to a phone number, you have to prefix every outgoing message with 'sms send some-phone-number  hey'. Likewise, all phone calls will show up in the room the same way. This is fine in the sense that it works, but it gets annoying over time. A better solution is to create one room for each phone number, such that all messages to and from that room automatically go to the right place. The latter is what this program does - if you send a message in the channel #phone_=14165551234:your-home-server, it'll be sent as an SMS message to +1 416 555 1234, and if you receive a reply from that number, it'll show up in that room as a message.

## Why the = in front of each phone number / user account / room name?

Phone numbers are complicated. Really complicated. There are a bunch of weird edge cases that arise from when we try to handle phone numbers in a number of circumstances. Consider:

- If you text your friend at 416-555-1234 by joining #phone_4165551234 (or just dialing that on your phone), it'll go through if your cell phone is physically located in a NANP area.

- If you take your phone to Australia and attempt to SMS/call that number, it won't work. Likewise, sending a message via Matrix to the room you were using before you got on a plane also won't work, because 416-555-1234 isn't routable in Australia.


To work around these issues (and not produce the [exact](https://github.com/nextcloud/ocsms/issues/176
) [same](https://github.com/tijder/SmsMatrix/issues/14) bug that every other Android SMS bridge seems to have), rooms will generally be created with canonical normalized numbers, which always include both the country code and international call prefix (+). Matrix MXIDs and room names can't contain '+' characters, so we'll use the next best thing, a '='.

There are some exceptions to the whole 'canonical normalized number' thing. Some numbers aren't globally routable - things like emergency services, SMS short codes, and custom phone numbers (411, 611, etc) in North America won't work in different parts of the world, because they're specific to some region or carrier. If your carrier sends you an SMS message from 611 while in a NANP country, you'll be joined to a room called #phone_611, and that room won't work if you travel to Australia - there is no canonical form of that number, because that number only exists in certain countries, and calls different places depending on where you are.

In short, you can join #phone_4165551234 if you really want, provided you're located in a region where that number would work. However, if you're joining a room to send a message, you should probably always include the =1 (or whatever your equivalent country code is), unless you want things to break while travelling or fail in odd ways later on (like having a second room be created with those characters in front when you receive a call or text message from that number). Rooms and users will be automatically created using those characters where applicable.

## What about just changing MAXS to work using Matrix instead - why does this need AppService permissions?

Unfortunately, it isn't that simple. We can definitely ditch the MAXS <--XMPP--> XMPP Server <--mxpp--> Matrix part of the equation by replacing maxs-transport-xmpp with a hypothetical maxs-transport-matrix, but that's still only a partial solution. It would, at minimum, have the following problems:

* MAXS would be limited to a single user account (you can open multiple chat rooms, but all of them would have the same person inside them) - to send an SMS message to a random phone number, you'd have to create a room (e.g. #phone_=14165551234), invite MAXS to the room, and then send a message to the room. Using an AS, we can allow you to join #phone_=14165551234 to send a message to that number, but more importantly, we can make the message appear to come from a user account specific to that one number (@phone_=14165551234).

* Messages sent from other Android SMS apps wouldn't be able to show up as coming from you within Matrix. Using an AS with Puppetting support means that when you send an SMS from your phone, you'll see a message that looks like it came from you within the respective Matrix chat window.

For more information on puppetting, see: https://github.com/matrix-hacks/matrix-puppet-bridge#q-whats-puppetting-and-why-does-this-use-it.

## How does it work?

Project MAXS by default talks over XMPP - it's a modular project in the sense that you can swap out the communication protocol it uses, but to date only maxs-transport-xmpp exists. Assuming this is bridged into Matrix (via mxpp), we effectively get a control channel, where all calling / texting / other stuff shows up. This is great in the sense that it works, but it isn't terribly user friendly. matrix-puppet-maxs watches if you send a message to any of the channels it controls (by default #phone_some_number), takes whatever message you sent, and then fires it through the control channel after prefixing it with the requisite magic (sms send phone-number  message) to make it actually send an SMS message. If a new message comes into the control channel, matrix-puppet-maxs will insert that message into the #phone_number channel, so that you have a coherent view of your SMS / calls to that number.

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
 - [x] Full canonical E.164 support
 - [ ] Backfilling history

