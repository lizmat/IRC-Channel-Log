[![Actions Status](https://github.com/lizmat/IRC-Channel-Log/workflows/test/badge.svg)](https://github.com/lizmat/IRC-Channel-Log/actions)

NAME
====

IRC::Channel::Log - access to all logs of an IRC channel

SYNOPSIS
========

```raku
use IRC::Log::Colabti;  # class implementing one day of logs
use IRC::Channel::Log;

my $channel = IRC::Channel::Log.new(
  logdir    => "logs/raku",                   # directory containing logs
  class     => IRC::Log::Colabti,             # for example
  generator => -> $nick { RandomColor.new },  # generate color for nick
);

say $channel.dates;             # the dates for which there are logs available
say $channel.problems.elems;    # hash with problems / date

.say for $channel.entries;      # all entries of this channel

.say for $channel.entries(
  :conversation,         # only return conversational messages
  :control,              # only return control messages
  :dates<2021-04-23>,    # limit to given date(s)
  :nicks<lizmat japhb>,  # limit to given nick(s)
  :contains<foo>,        # limit to containing given text
  :starts-with<m:>,      # limit to starting with given text
  :matches(/ /d+ /),     # limit to matching regex
);

$channel.watch-and-update;  # watch and process updates

$channel.shutdown;          # perform all necessary actions on shutdown
```

DESCRIPTION
===========

IRC::Channel::Log provides a programmatic interface to the IRC log files of a channel.

CLASS METHODS
=============

new
---

```raku
use IRC::Log::Colabti;  # class implementing one day of logs
use IRC::Channel::Log;

my $channel = IRC::Channel::Log.new(
  logdir    => "logs/raku",        # directory containing logs
  class     => IRC::Log::Colabti,  # class implementing log parsing logic
  generator => &generator,        # generate color for nick
  name      => "foobar",           # name of channel, default: logdir.basename
  state     => "state",            # directory containing persistent state info
  batch     => 1,                  # number of logs parsed at a time, default: 6
  degree    => 8,                  # threads used, default: Kernel.cpu-cores
);
```

The `new` class method returns an `IRC::Channel::Log` object. It takes four named arguments:

### :logdir

The directory (either as a string or as an `IO::Path` object) in which log file of the channel is located, as created by a logger such as `IRC::Client::Plugin::Logger`. This expects the directories to be organized by year, with all the logs of each day of a year in that directory. For example, in the test of this module:

    raku
     |-- 2021
          |-- 2021-04-23
          |-- 2021-04-24

This argument is required.

### :batch

The batch size to use when racing to read all of the log files of the given channel. Defaults to 6 as an apparent optimal values to optimize for wallclock and not have excessive CPU usage. You can use `:!batch` to indicate you do not want any multi-threading: this is equivalent to specifying `1` or `0` or `True`.

### :class

The class to be used to interpret log files, e.g. `IRC::Log::Colabti`. This argument is also required.

### :degree

The maximum number of threads to be used when racing to read all of the log files of the given channel. Defaults to `Kernel.cpu-cores` (aka the number of CPU cores the system claims to have).

### :generator

A `Callable` expected to take a nick and return a color to be associated with that nick.

### :name

The name of the channel. Optional. Defaults to the base name of the directory specified with `logdir`.

### :state

The directory (either as a string or as an `IO::Path` object) in which persistent state information of the channel is located.

INSTANCE METHODS
================

active
------

```raku
say "$channel.name() is active" if $channel.active;
```

The `active` instance method returns whether the channel is considered to be active. If a `state` directory has been specified, and that directory contains a file named "inactive", then the channel is considered to **not** be active.

dates
-----

```raku
say $channel.dates;          # the dates for which there are logs available
```

The `dates` instance method returns a sorted list of dates (as strings in YYYY-MM-DD format) of which there are entries available.

entries
-------

```raku
.say for $channel.entries;             # all entries in chronological order

.say for $channel.entries(:reverse);   # in reverse chronological order

.say for $channel.entries(:contains<question>); # containing text

.say for $channel.entries(:control);            # control messages only

.say for $channel.entries(:conversation);       # conversational messages only

.say for $channel.entries(:dates<2021-04-23>);  # for one or more dates

.say for $channel.entries(:matches(/ \d+ /);    # matching regex

.say for $channel.entries(:starts-with<m:>);    # starting with text

.say for $channel.entries(:nicks<lizmat>);      # for one or more nicks

.say for $channel.entries(
  :dates<2021-04-23>,
  :nicks<lizmat japhb>,
  :contains<question answer>, :all,
);
```

The `entries` instance method is *the* workhorse for selecting entries from the log. It will always return messages in chronological order.

It takes a number of (optional) named arguments that allows you to select the entries from the log that you need. Named arguments may be combined, although some combinations do not make a lot of sense (which will generally mean that some of them will be ignored.

If no (valid) named arguments are specified, then **all** entries from the log will be produced: this allows you to do any ad-hoc filtering.

The following named arguments are supported:

### :contains

```raku
# just "question"
$channel.entries(:contains<question>);

# "question" or "answer"
$channel.entries(:contains<question answer>);

# "question" and "answer"
$channel.entries(:contains<question answer>, :all);
```

The `contains` named argument allows specification of one or more strings that an entry should contain. By default, an entry should only contain one of the specified strings to be selected. If you want an entry to contain **all** strings, then an additional `:all` named argument can be specified (with a true value).

Since this only applies to conversational entries, any additional setting of the `conversation` or `control` named arguments are ignored.

### :control

```raku
$channel.entries(:control);   # control messages only

$channel.entries(:!control);  # all but control messages
```

The `control` named argument specifies whether to limit to control messages only or not.

### :conversation

```raku
$channel.entries(:conversation);   # conversational messages only

$channel.entries(:!conversation);  # all but conversational messages
```

The `conversation` named argument specifies whether to limit to conversational messages only or not.

### :dates

```raku
$channel.entries(:dates<2021-04-23>);   # just on one date

my @dates = Date.today ... Date.today.earlier(:3days);
$channel.entries(:@dates);              # multiple dates
```

The `dates` named argument allows one to specify the date(s) from which entries should be selected. Dates can be specified in anything that will stringify in the YYYY-MM-DD format.

### :matches

```raku
$channel.entries(:matches(/ \d+ /);    # matching regex
```

The `matches` named argument allows one to specify a `Regex` to indicate which entries should be selected.

Since this only applies to conversational entries, any additional setting of the `conversation` or `control` named arguments are ignored.

### :nicks

```raku
$channel.entries(:nicks<lizmat>);        # limit to "lizmat"

$channel.entries(:nicks<lizmat japhb>);  # limit to "lizmat" or "japhb"
```

The `nicks` named argument allows one to specify one or more nicks to indicate which entries should be selected.

### :reverse

```raku
.say for $channel.entries(:reverse);   # all messages, most recent first
.say for $channel.entries(:!reverse);  # all messages, oldest first
```

The `reverse` named argument allows one to specify the order in which entries will be returned. If specified with a true value, it will return the most recent entries first, in reverse chronological order.

### :starts-with

```raku
# starts with "m:"
$channel.entries(:starts-with<m:>);

# starts with "m:" or "j:"
$channel.entries(:starts-with<m: j:>);
```

The `start-with` named argument allows specification of one or more strings that an entry should start with.

Since this only applies to conversational entries, any additional setting of the `conversation` or `control` named arguments are ignored.

is-first-date-of-month
----------------------

```raku
say $channel.is-first-date-of-month($date);
```

The `is-first-date-of-month` instance method takes a date (either as a `Date` object or as astring) and returns whether that date is the first date of the month, according to availability in the logs.

is-first-date-of-year
---------------------

```raku
say $channel.is-first-date-of-year($date);
```

The `is-first-date-of-month` instance method takes a date (either as a `Date` object or as astring) and returns whether that date is the first date of the year, according to availability in the logs.

log
---

```raku
say $channel.log($date);  # log object for given date
```

The `log` instance method takes a string representing a date, and returns the `class` object for that given date. Returns `Nil` if there is no log available on the specified date.

next-date
---------

```raku
say $channel.next-date($date);  # date after the given date with a log
```

The `next-date` instance method takes a string representing a date, and returns a string with the **next** date of logs that are available. Returns `Nil` if the specified date is the last date or after that.

nick-mapped
-----------

```raku
my %mapped := $channel.nick-mapped;  # thread-safe hash copy
say %mapped<liz>;  # <span style="color: #deadbeef">liz</span>
```

The `nick-mapped` instance method returns a `Map` of all nicks and their `nick-mapped` HTML in a thread-safe manner (as new nicks **can** be added during the lifetime of the process).

nicks
-----

```raku
say $channel.nicks;          # the nicks for which there are logs available
```

The `nicks` instance method returns a sorted list of nicks of which there are entries available.

prev-date
---------

```raku
say $channel.prev-date($date);  # date before the given date with a log
```

The `prev-date` instance method takes a string representing a date, and returns a string with the **previous** date of logs that are available. Returns `Nil` if the specified date is the first date or before that.

problems
--------

```raku
.say for $channel.problems;  # the dates with log parsing problems
```

The `problems` instance method returns a sorted list of `Pair`s with the date (formatted as YYYY-MM-DD) as key, and a list of problem descriptions as value.

sc
--

```raku
say "$channel.sc.elems() nick to color mappings are known";
```

The `String::Color` object that contains the mapping of nick to color.

shutdown
--------

```raku
$channel.shutdown;
```

Performs all the actions needed to shutdown: specifically saves the nick to color mapping if a `state` directory was specified.

state
-----

```raku
say "state is saved in $channel.state()";
```

The `IO` object of the directory in which persistent state will be saved.

this-date
---------

```raku
say $channel.this-date($date);  # date after / before the given date
```

The `this-date` instance method takes a string representing a date, and returns a string with the **first** date of logs that are available. This could be either the given date, or the next date, or the previous date (if there was no next date). Returns `Nil` if no dates could be found, which would effectively mean that there are **no** dates in the log.

watch-and-update
----------------

```raku
$channel.watch-and-update;
```

The `watch-and-update` instance method starts a thread (and returns its `Promise` in which it watches for any updates in the most recent logs. If there are any updates, it will process them and make sure that all the internal state is correctly updated.

AUTHOR
======

Elizabeth Mattijsen <liz@wenzperl.nl>

COPYRIGHT AND LICENSE
=====================

Copyright 2021 Elizabeth Mattijsen

Source can be located at: https://github.com/lizmat/IRC-Channel-Log . Comments and Pull Requests are welcome.

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

