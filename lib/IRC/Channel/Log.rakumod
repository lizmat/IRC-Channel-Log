use v6.*;

use Array::Sorted::Util:ver<0.0.6>:auth<cpan:ELIZABETH>;
use JSON::Fast:ver<0.15>;
use String::Color:ver<0.0.6>:auth<cpan:ELIZABETH>;

class IRC::Channel::Log:ver<0.0.17>:auth<cpan:ELIZABETH> {
    has IO() $.logdir    is required is built(:bind);
    has      $.class     is required is built(:bind);
    has      &.generator is required is built(:bind);
    has IO() $.state                 is built(:bind);
    has str  $.name = $!logdir.basename;
    has str  @.dates       is built(False);
    has str  @.years       is built(False);
    has      @.problems    is built(False);
    has String::Color $!sc;
    has      @!logs;   # log objects, same order as @!dates
    has      %!nicks;  # hash of hash of entries
             # |- nick
             #     |- date
             #         |- entries

    # IO for file containing persistent color information
    method !colors-json() {
        $!state 
          ?? $!state.add("colors.json")
          !! Nil
    }

    # Not done creating the object yet
    method TWEAK(
      :$batch = 6,
      :$degree = Kernel.cpu-cores,
    --> Nil) {

        # Read and process all log files asynchronously
        for $!logdir.dir.map(*.dir.Slip)
          .race(:$batch, :$degree)
          .map(-> $path { $_ with $!class.new($path) })
        -> $log {

            # Associate the date with the log
            my $date := $log.date.Str;
            inserts @!dates, $date, @!logs, $log;

            # Map nicks to dates with entries per date
            for $log.nicks {
                if %!nicks{.key} -> %dates {
                    %dates{$date} := .value;
                }
                else {
                    (%!nicks{.key} := {}){$date} := .value;
                }
            }

            # Remember any problems for this log
            if $log.problems -> @problems {
                @!problems.push: $date => @problems;
            }
        }

        # Create nick to color mapping from state if possible
        with self!colors-json -> $colors {
            $!sc := String::Color.new:
              :&!generator,
              :colors(from-json $colors.slurp)
              if $colors.e;
        }

        # Create nick to color mapping from nicks if we don't have one yet
        without $!sc {
            $!sc := String::Color.new: :&!generator;
            $!sc.add: %!nicks.keys;
        }
    }

#-------------------------------------------------------------------------------
# Filters

    # :starts-with post-processing filters
    multi method entries(IRC::Channel::Log:D:
      :starts-with($needle)! is raw,
      :$ignorecase,
      :conversation($),  # ignored
      :control($),       # ignored
    ) {
        if $needle.List -> @needle {
            if @needle == 1 {
                my $needle := @needle[0];
                self.entries(|%_).grep: {
                    .conversation && .text.starts-with($needle, :$ignorecase)
                }
            }

            # More than one needle
            else {
                self.entries(|%_).grep: -> $entry {
                    if $entry.conversation {
                        my $text := $entry.text;
                        @needle.first: { $text.starts-with($_, :$ignorecase) }
                    }
                }
            }
        }
    }

    # :contains post-processing filters
    multi method entries(IRC::Channel::Log:D:
      :contains($needle)! is raw,
      :$ignorecase,
      :$all,
      :conversation($),  # ignored
      :control($),       # ignored
    ) {
        if $needle.List -> @needle {
            if @needle == 1 {
                my $needle := @needle[0];
                self.entries(|%_).grep: {
                    .conversation && .text.contains($needle, :$ignorecase)
                }
            }

            # More than one needle
            else {
                self.entries(|%_).grep: -> $entry {
                    if $entry.conversation {
                        my $text := $entry.text;
                        $all
                         ?? !@needle.first: {
                                !$text.contains($_, :$ignorecase)
                            }
                         !! ?@needle.first: {
                                $text.contains($_, :$ignorecase)
                            }
                    }
                }
            }
        }
    }

    # :words post-processing filters
    multi method entries(IRC::Channel::Log:D:
      :words($needle)! is raw,
      :$ignorecase,
      :$all,
      :conversation($),  # ignored
      :control($),       # ignored
    ) {
        if $needle.List -> @needle {
            if @needle == 1 {
                my $needle := @needle[0];
                if $ignorecase {
                    my $regex := /:i << $needle >> /;
                    self.entries(|%_).grep: {
                        .conversation
                          && .text.contains($needle, :ignorecase)
                          && .text.contains($regex)
                    }
                }
                else {
                    my $regex := / << $needle >> /;
                    self.entries(|%_).grep: {
                        .conversation
                          && .text.contains($needle)
                          && .text.contains($regex)
                    }
                }
            }

            # More than one needle
            else {
                my @regex = $ignorecase
                  ?? @needle.map: -> str $needle { /:i << $needle >> / }
                  !! @needle.map: -> str $needle { /   << $needle >> / }

                if $all {
                    self.entries(|%_).grep: -> $entry {
                        if $entry.conversation {
                            my $text := $entry.text;
                            !@needle.first({
                                !$text.contains($_, :$ignorecase)
                            }) && !@regex.first({
                                !$text.contains($_)
                            }, :k).defined
                        }
                    }
                }

                # Only one of the needles
                else {
                    self.entries(|%_).grep: -> $entry {
                        if $entry.conversation {
                            my $text := $entry.text;
                            @needle.first({
                                $text.contains($_, :$ignorecase)
                            })
                            && @regex.first({
                                $text.contains($_)
                            }, :k).defined
                        }
                    }
                }
            }
        }
    }

    # :matches post-processing filter
    multi method entries(IRC::Channel::Log:D:
      Regex:D :matches($regex)!,
              :conversation($),  # ignored
              :control($),       # ignored
    ) {
        self.entries(|%_).grep: {
            .conversation && .text.contains($regex)
        }
    }

    # :conversation post-processing filter
    multi method entries(IRC::Channel::Log:D: :$conversation!) {
        $conversation
          ?? self.entries(|%_).grep:  *.conversation
          !! self.entries(|%_).grep: !*.conversation
    }

    # :control post-processing filter
    multi method entries(IRC::Channel::Log:D: :$control!) {
        $control
          ?? self.entries(|%_).grep: *.control
          !! self.entries(|%_).grep: !*.control
    }

    # Both dates and nicks as arrays
    method !dates-nicks(@dates, @nicks) {
        if %!nicks{@nicks}.grep: *.defined -> @date-hashes {
            if @dates -> @sorted-dates {
                @sorted-dates.map: -> $date {
                    (@date-hashes.map: {
                        .Slip with .{$date} }
                    ).sort(*.target).Slip
                }
            }
        }
    }

    # Both dates and nicks as arrays in reverse order
    method !dates-nicks-reverse(@dates, @nicks) {
        if %!nicks{@nicks}.grep: *.defined -> @date-hashes {
            if @dates.reverse -> @sorted-dates {
                @sorted-dates.map: -> $date {
                    (@date-hashes.map: {
                        .List.reverse.Slip with .{$date} }
                    ).sort(*.target).reverse.Slip
                }
            }
        }
    }

    # :dates *and* :nicks selection
    multi method entries(IRC::Channel::Log:D:
      :$dates! is raw,
      :$nicks! is raw,
      :$reverse
    ) {
        $reverse
          ?? self!dates-nicks-reverse($dates.List, $nicks.List)
          !! self!dates-nicks($dates.List, $nicks.List)
    }

    # Just dates as array
    method !dates(@dates) {
        @dates.map: -> $date {
            with finds(@!dates, $date) -> $pos {
                @!logs[$pos].entries.Slip
            }
        }
    }

    # Just dates as array in reverse order
    method !dates-reverse(@dates) {
        @dates.reverse.map: -> $date {
            with finds(@!dates, $date) -> $pos {
                @!logs[$pos].entries.List.reverse.Slip
            }
        }
    }

    # just :dates selection
    multi method entries(IRC::Channel::Log:D:
      :$dates! is raw,
      :$reverse
    ) {
        $reverse
          ?? self!dates-reverse($dates.List)
          !! self!dates($dates.List)
    }

    # Just nicks as array
    method !nicks(@nicks) {
        if %!nicks{@nicks}.grep: *.defined -> @date-hashes {
            @!dates.map: -> $date {
                (@date-hashes.map: {
                    .Slip with .{$date} }
                ).Slip
            }
        }
    }

    # Just nicks as array in reverse order
    method !nicks-reverse(@nicks) {
        if %!nicks{@nicks}.grep: *.defined -> @date-hashes {
            @!dates.reverse.map: -> $date {
                (@date-hashes.map: {
                    .List.reverse.Slip with .{$date}
                }).sort(*.target).reverse.Slip
            }
        }
    }

    # just :nicks selection
    multi method entries(IRC::Channel::Log:D:
      :$nicks! is raw,
      :$reverse
    ) {
        $reverse
          ?? self!nicks-reverse($nicks.List)
          !! self!nicks($nicks.List)
    }

    # just all of them
    multi method entries(IRC::Channel::Log:D: :$reverse) {
        $reverse
          ?? @!logs.reverse.map: *.entries.List.reverse.Slip
          !! @!logs.map: *.entries.Slip
    }

#-------------------------------------------------------------------------------
# Utility methods

    method active(IRC::Channel::Log:D: --> Bool:D) {
        $!state
          ?? !$!state.add("inactive").e
          !! True
    }

    method years(IRC::Channel::Log:D:) {
        @!years ||= $!logdir.dir(:test(/ ^ \d ** 4 $ /)).map(*.basename).sort
    }

    method watch-and-update(IRC::Channel::Log:D: --> Promise:D) {
        start {
            my $year := self.years.tail;

            # Outer loop in case we get to a new *year*
            loop {
                react {

                    # Moved into a new year
                    whenever $!logdir.watch {
                        my $new := self.years.tail;
                        if $new ne $year {
                            $year := $new;
                            done;
                        }
                    }

                    # A log file has changed 
                    whenever $!logdir.add($year).watch -> $event {
                        my $path := $event.path.IO;
                        if $path.f && $!class.IO2Date($path) -> $Date {
                            my $date := $Date.Str;

                            # A date for which we have data already
                            my $log;
                            with finds(@!dates,$date) -> $pos {
                                $log := @!logs[$pos];
                                $log.update($path);
                                (%!nicks{.key} := {}){$date} := .value
                                  unless %!nicks{.key}
                                  for $log.nicks;
                            }

                            # A new date
                            else {
                                $log := $!class.new($path, $date);
                                inserts(@!dates, $date, @!logs, $log);
                                %!nicks{.key}{$date} := .value for $log.nicks;
                            }

                            # Create mappings for any new nicks
                            $!sc.add($log.nicks);
                        }
                    }
                }
            }
        }
    }

    method nicks(IRC::Channel::Log:D:) { $!sc.strings }
    method colors(IRC::Channel::Log:D: --> Map:D) { $!sc.Map }

    # Return the closest date for a given date.  If there is no log
    # for that date, then first look forward in time.  If that fails,
    # look backward in time: should always return some date in a non-empty
    # log.
    method this-date(IRC::Channel::Log:D: str $date) {
        with finds(@!dates, $date) {
            $date
        }
        else {
            nexts(@!dates, $date) // prevs(@!dates, $date)
        }
    }

    # Return the next date for a given date for which there is a log
    method next-date(IRC::Channel::Log:D: str $date) {
        nexts(@!dates, $date)
    }
    # Return the previous date for a given date for which there is a log
    method prev-date(IRC::Channel::Log:D: str $date) {
        prevs(@!dates, $date)
    }

    # Return the log for the given date, if any
    method log(IRC::Channel::Log:D: str $date) {
        with finds(@!dates, $date) -> $pos {
            @!logs[$pos]
        }
        else {
            Nil
        }
    }

    # Return whether the given date is the first date of the month
    # judging by availability.
    method is-first-date-of-month(IRC::Channel::Log:D: str $date --> Bool:D) {
        if $date.ends-with('-01') {
            True
        }
        else {
            my $pos := finds(@!dates, $date);
            if $pos > 0 {
                @!dates[$pos - 1].substr(0,7) ne $date.substr(0,7)
            }
            else {
                True
            }
        }
    }

    # Return whether the given date is the first date of the year
    # judging by availability.
    method is-first-date-of-year(IRC::Channel::Log:D: $date --> Bool:D) {
        if $date.ends-with('-01-01') {
            True
        }
        else {
            my $pos := finds(@!dates, $date);
            if $pos > 0 {
                @!dates[$pos - 1].substr(0,4) ne $date.substr(0,4)
            }
            else {
                True
            }
        }
    }

    # Perform all of the necessary shutdown work
    method shutdown(IRC::Channel::Log:D: --> Nil) {
        self!colors-json.spurt: to-json $!sc.Map, :!pretty;
    }
}

#-------------------------------------------------------------------------------
# Documentation

=begin pod

=head1 NAME

IRC::Channel::Log - access to all logs of an IRC channel

=head1 SYNOPSIS

=begin code :lang<raku>

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

=end code

=head1 DESCRIPTION

IRC::Channel::Log provides a programmatic interface to the IRC log files
of a channel.

=head1 CLASS METHODS

=head2 new

=begin code :lang<raku>

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

=end code

The C<new> class method returns an C<IRC::Channel::Log> object.  It takes
four named arguments:

=head3 :logdir

The directory (either as a string or as an C<IO::Path> object) in which
log file of the channel is located, as created by a logger such as
C<IRC::Client::Plugin::Logger>.  This expects the directories to be
organized by year, with all the logs of each day of a year in that
directory.  For example, in the test of this module:

  raku
   |-- 2021
        |-- 2021-04-23
        |-- 2021-04-24

This argument is required.

=head3 :batch

The batch size to use when racing to read all of the log files of the
given channel.  Defaults to 6 as an apparent optimal values to optimize
for wallclock and not have excessive CPU usage.  You can use C<:!batch>
to indicate you do not want any multi-threading: this is equivalent to
specifying C<1> or C<0> or C<True>.

=head3 :class

The class to be used to interpret log files, e.g. C<IRC::Log::Colabti>.
This argument is also required.

=head3 :degree

The maximum number of threads to be used when racing to read all of the
log files of the given channel.  Defaults to C<Kernel.cpu-cores> (aka the
number of CPU cores the system claims to have).

=head3 :generator

A C<Callable> expected to take a nick and return a color to be associated
with that nick.

=head3 :name

The name of the channel.  Optional.  Defaults to the base name of the
directory specified with C<logdir>.

=head3 :state

The directory (either as a string or as an C<IO::Path> object) in which
persistent state information of the channel is located.

=head1 INSTANCE METHODS

=head2 active

=begin code :lang<raku>

say "$channel.name() is active" if $channel.active;

=end code

The C<active> instance method returns whether the channel is considered to
be active.  If a C<state> directory has been specified, and that directory
contains a file named "inactive", then the channel is considered to B<not>
be active.

=head2 dates

=begin code :lang<raku>

say $channel.dates;          # the dates for which there are logs available

=end code

The C<dates> instance method returns a sorted list of dates (as strings
in YYYY-MM-DD format) of which there are entries available.

=head2 entries

=begin code :lang<raku>

.say for $channel.entries;             # all entries in chronological order

.say for $channel.entries(:reverse);   # in reverse chronological order

.say for $channel.entries(:contains<question>); # containing text

.say for $channel.entries(:control);            # control messages only

.say for $channel.entries(:conversation);       # conversational messages only

.say for $channel.entries(:dates<2021-04-23>);  # for one or more dates

.say for $channel.entries(:matches(/ \d+ /);    # matching regex

.say for $channel.entries(:starts-with<m:>);    # starting with text

.say for $channel.entries(:contains<foo>);      # containing string

.say for $channel.entries(:words<foo>);         # containing word

.say for $channel.entries(:nicks<lizmat>);      # for one or more nicks

.say for $channel.entries(
  :dates<2021-04-23>,
  :nicks<lizmat japhb>,
  :contains<question answer>, :all,
);

=end code

The C<entries> instance method is *the* workhorse for selecting entries
from the log.  It will always return messages in chronological order.

It takes a number of (optional) named arguments that allows you to select
the entries from the log that you need.  Named arguments may be combined,
although some combinations do not make a lot of sense (which will generally
mean that some of them will be ignored.

If no (valid) named arguments are specified, then B<all> entries from
the log will be produced: this allows you to do any ad-hoc filtering.

The following named arguments are supported:

=head3 :all

The C<all> named argument can only be used in combination with the C<contains>
and C<words> named arguments.  If specified with a true value, it will force
entries to only be selected if B<all> conditions are true.

=head3 :contains

=begin code :lang<raku>

# just "question"
$channel.entries(:contains<question>);

# "question" or "answer"
$channel.entries(:contains<question answer>);

# "question" or "answer"
$channel.entries(:contains<question answer>, :ignorecase);

# "question" and "answer"
$channel.entries(:contains<question answer>, :all);

=end code

The C<contains> named argument allows specification of one or more
strings that an entry should contain.  By default, an entry should
only contain one of the specified strings to be selected.  If you
want an entry to contain B<all> strings, then an additional C<:all>
named argument can be specified (with a true value).

If comparisons need to be done in an case-insensitive manner, then
the C<ignorecase> named argument can be specified with a true value.

Since this only applies to conversational entries, any additional
setting of the C<conversation> or C<control> named arguments are
ignored.

=head3 :control

=begin code :lang<raku>

$channel.entries(:control);   # control messages only

$channel.entries(:!control);  # all but control messages

=end code

The C<control> named argument specifies whether to limit to control
messages only or not.

=head3 :conversation

=begin code :lang<raku>

$channel.entries(:conversation);   # conversational messages only

$channel.entries(:!conversation);  # all but conversational messages

=end code

The C<conversation> named argument specifies whether to limit to
conversational messages only or not.

=head3 :dates

=begin code :lang<raku>

$channel.entries(:dates<2021-04-23>);   # just on one date

my @dates = Date.today ... Date.today.earlier(:3days);
$channel.entries(:@dates);              # multiple dates

=end code

The C<dates> named argument allows one to specify the date(s) from
which entries should be selected.  Dates can be specified in anything
that will stringify in the YYYY-MM-DD format, but are expected to be in
ascending sort order.

=head3 :ignorecase

The C<ignorecase> named argument can only be used in combination with the
C<starts-with>, C<contains> and C<words> named arguments.  If specified with
a true value, it will do all comparisons in a case-insensitive manner.

=head3 :matches

=begin code :lang<raku>

$channel.entries(:matches(/ \d+ /);    # matching regex

=end code

The C<matches> named argument allows one to specify a C<Regex> to
indicate which entries should be selected.

Since this only applies to conversational entries, any additional
setting of the C<conversation> or C<control> named arguments are
ignored.

=head3 :nicks

=begin code :lang<raku>

$channel.entries(:nicks<lizmat>);        # limit to "lizmat"

$channel.entries(:nicks<lizmat japhb>);  # limit to "lizmat" or "japhb"

=end code

The C<nicks> named argument allows one to specify one or more nicks
to indicate which entries should be selected.

=head3 :reverse

=begin code :lang<raku>

.say for $channel.entries(:reverse);   # all messages, most recent first
.say for $channel.entries(:!reverse);  # all messages, oldest first

=end code

The C<reverse> named argument allows one to specify the order in which entries
will be returned.  If specified with a true value, it will return the most
recent entries first, in reverse chronological order.

=head3 :starts-with

=begin code :lang<raku>

# starts with "m:"
$channel.entries(:starts-with<m:>);

# starts with "how" in any case
$channel.entries(:starts-with<how>, :ignorecase);

# starts with "m:" or "j:"
$channel.entries(:starts-with<m: j:>);

=end code

The C<start-with> named argument allows specification of one or more
strings that an entry should start with.

If comparisons need to be done in an case-insensitive manner, then
the C<ignorecase> named argument can be specified with a true value.

Since this only applies to conversational entries, any additional
setting of the C<conversation> or C<control> named arguments are
ignored.

=head3 :words

=begin code :lang<raku>

# contains the word "foo"
$channel.entries(:words<foo>);

# contains the word "foo" or "bar"
$channel.entries(:words<foo bar>);

# contains the word "foo" or the word "bar" in any case
$channel.entries(:words<foo bar>, :ignorecase);

# contains the word "foo" *and* "bar"
$channel.entries(:words<foo bar>, :all);

=end code

The C<words> named argument allows specification of one or more words that
an entry should contain.  By default, an entry should only contain one of
the specified words to be selected.  If you want an entry to contain B<all>
words, then an additional C<:all> named argument can be specified (with a
true value).

If comparisons need to be done in an case-insensitive manner, then
the C<ignorecase> named argument can be specified with a true value.

Since this only applies to conversational entries, any additional
setting of the C<conversation> or C<control> named arguments are
ignored.

=head2 is-first-date-of-month

=begin code :lang<raku>

say $channel.is-first-date-of-month($date);

=end code

The C<is-first-date-of-month> instance method takes a date (either as a
C<Date> object or as astring) and returns whether that date is the
first date of the month, according to availability in the logs.

=head2 is-first-date-of-year

=begin code :lang<raku>

say $channel.is-first-date-of-year($date);

=end code

The C<is-first-date-of-month> instance method takes a date (either as a
C<Date> object or as astring) and returns whether that date is the first
date of the year, according to availability in the logs.

=head2 log

=begin code :lang<raku>

say $channel.log($date);  # log object for given date

=end code

The C<log> instance method takes a string representing a date, and returns
the C<class> object for that given date.  Returns C<Nil> if there is no
log available on the specified date.

=head2 next-date

=begin code :lang<raku>

say $channel.next-date($date);  # date after the given date with a log

=end code

The C<next-date> instance method takes a string representing a date, and
returns a string with the B<next> date of logs that are available.  Returns
C<Nil> if the specified date is the last date or after that.

=head2 nick-mapped

=begin code :lang<raku>

my %mapped := $channel.nick-mapped;  # thread-safe hash copy
say %mapped<liz>;  # <span style="color: #deadbeef">liz</span>

=end code

The C<nick-mapped> instance method returns a C<Map> of all nicks and their
C<nick-mapped> HTML in a thread-safe manner (as new nicks B<can> be added
during the lifetime of the process).

=head2 nicks

=begin code :lang<raku>

say $channel.nicks;          # the nicks for which there are logs available

=end code

The C<nicks> instance method returns a sorted list of nicks of which
there are entries available.

=head2 prev-date

=begin code :lang<raku>

say $channel.prev-date($date);  # date before the given date with a log

=end code

The C<prev-date> instance method takes a string representing a date, and
returns a string with the B<previous> date of logs that are available.
Returns C<Nil> if the specified date is the first date or before that.

=head2 problems

=begin code :lang<raku>

.say for $channel.problems;  # the dates with log parsing problems

=end code

The C<problems> instance method returns a sorted list of C<Pair>s with
the date (formatted as YYYY-MM-DD) as key, and a list of problem
descriptions as value.

=head2 sc

=begin code :lang<raku>

say "$channel.sc.elems() nick to color mappings are known";

=end code

The C<String::Color> object that contains the mapping of nick to color.

=head2 shutdown

=begin code :lang<raku>

$channel.shutdown;

=end code

Performs all the actions needed to shutdown: specifically saves the nick
to color mapping if a C<state> directory was specified.

=head2 state

=begin code :lang<raku>

say "state is saved in $channel.state()";

=end code

The C<IO> object of the directory in which persistent state will be saved.

=head2 this-date

=begin code :lang<raku>

say $channel.this-date($date);  # date after / before the given date

=end code

The C<this-date> instance method takes a string representing a date, and
returns a string with the B<first> date of logs that are available.  This
could be either the given date, or the next date, or the previous date
(if there was no next date).  Returns C<Nil> if no dates could be found,
which would effectively mean that there are B<no> dates in the log.

=head2 watch-and-update

=begin code :lang<raku>

$channel.watch-and-update;

=end code

The C<watch-and-update> instance method starts a thread (and returns its
C<Promise> in which it watches for any updates in the most recent logs.
If there are any updates, it will process them and make sure that all the
internal state is correctly updated.

=head1 AUTHOR

Elizabeth Mattijsen <liz@wenzperl.nl>

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Elizabeth Mattijsen

Source can be located at: https://github.com/lizmat/IRC-Channel-Log .
Comments and Pull Requests are welcome.

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
