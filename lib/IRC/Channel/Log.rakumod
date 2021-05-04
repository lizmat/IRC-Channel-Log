use v6.*;

use Array::Sorted::Util:ver<0.0.5>:auth<cpan:ELIZABETH>;
use Object::Delayed:ver<0.0.10>:auth<cpan:ELIZABETH>;

class IRC::Channel::Log:ver<0.0.5>:auth<cpan:ELIZABETH> {
    has IO() $.logdir is required;
    has Mu   $.class  is required;
    has str  $.name = $!logdir.basename;
    has str  @.dates    is built(False);
    has str  @.years    is built(False);
    has str  @.nicks    is built(False);
    has      @.problems is built(False);
    has Mu   @!logs;
    has      %!nicks;

    method new(|c) { catchup { self.bless(|c) } }

    method TWEAK(:$batch = 6, :$degree = Kernel.cpu-cores --> Nil) {
        for $!logdir.dir.map(*.dir.Slip)
          .race(:$batch, :$degree)
          .map(-> $path { $_ with $!class.new($path) }) -> $log {

            my $date := $log.date.Str;
            inserts(@!dates, $date, @!logs, $log);

            for $log.nicks {
                if %!nicks{.key} -> %dates {
                    %dates{$date} := .value;
                }
                else {
                    (%!nicks{.key} := {}){$date} := .value;
                }
            }

            if $log.problems -> @problems {
                @!problems.push: $date => @problems;
            }
        }

        @!nicks = %!nicks.keys.sort;
    }

#-------------------------------------------------------------------------------
# Filters

    # :starts-with post-processing filters
    multi method entries(IRC::Channel::Log:D:
      Str:D :starts-with($text)!,
      :conversation($),  # ignored
      :control($),       # ignored
    ) {
        self.entries(|%_).grep: { .conversation && .text.starts-with($text) }
    }
    multi method entries(IRC::Channel::Log:D:
      Str:D :starts-with(@text)!,
            :conversation($),  # ignored
            :control($),       # ignored
    ) {
        self.entries(|%_).grep: -> $entry {
            if $entry.conversation {
                my $text := $entry.text;
                @text.first: {  $text.starts-with($_) }
            }
        }
    }

    # :contains post-processing filters
    multi method entries(IRC::Channel::Log:D:
      Str:D :contains($text)!,
            :conversation($),  # ignored
            :control($),       # ignored
    ) {
        self.entries(|%_).grep: { .conversation && .text.contains($text) }
    }
    multi method entries(IRC::Channel::Log:D:
      :contains(@text)!,
      :$all,
      :conversation($),  # ignored
      :control($),       # ignored
    ) {
        self.entries(|%_).grep: -> $entry {
            if $entry.conversation {
                my $text := $entry.text;
                $all
                 ?? !@text.first: { !$text.contains($_) }
                 !!  @text.first: {  $text.contains($_) }
            }
        }
    }

    # :matches post-processing filter
    multi method entries(IRC::Channel::Log:D:
      Regex:D :matches($regex)!,
              :conversation($),  # ignored
              :control($),       # ignored
    ) {
        self.entries(|%_).grep: { .conversation && .text.contains($regex) }
    }

    # :conversation post-processing filter
    multi method entries(IRC::Channel::Log:D: :$conversation!) {
        $conversation
          ?? self.entries(|%_).grep: *.conversation
          !! self.entries(|%_).grep: !*.conversation
    }

    # :control post-processing filter
    multi method entries(IRC::Channel::Log:D: :$control!) {
        $control
          ?? self.entries(|%_).grep: *.control
          !! self.entries(|%_).grep: !*.control
    }

    # :dates *and* :nicks selection
    multi method entries(IRC::Channel::Log:D: :$dates!, :$nicks!) {
        %!nicks{$nicks<>}{$dates<>}.map: { .Slip with $_ }
    }
    multi method entries(IRC::Channel::Log:D: :@dates!, :$nicks!) {
        %!nicks{$nicks<>}{@dates.sort}.map: { .Slip with $_ }
    }
    multi method entries(IRC::Channel::Log:D: :$dates!, :@nicks!) {
        @nicks == 1
          ?? %!nicks{@nicks[0]}{$dates<>}.map: { .Slip with $_ }
          !! %!nicks{@nicks}{$dates<>}.map({ .Slip with $_ })
               .sort: *.target
    }
    multi method entries(IRC::Channel::Log:D: :@dates!, :@nicks!) {
        @nicks == 1
          ?? %!nicks{@nicks[0]}{@dates.sort}.map: { .Slip with $_ }
          !! %!nicks{@nicks}{@dates}.map({ .Slip with $_ })
               .sort: *.target
    }

    # just :dates selection
    multi method entries(IRC::Channel::Log:D: :$dates!) {
        $dates<>.map: -> $date {
            with finds(@!dates, $date) -> $pos {
                @!logs[$pos].entries.Slip
            }
        }
    }
    multi method entries(IRC::Channel::Log:D: :@dates!) {
        @dates.sort.map: -> $date {
            with finds(@!dates, $date) -> $pos {
                @!logs[$pos].entries.Slip
            }
        }
    }

    # just :nicks selection
    multi method entries(IRC::Channel::Log:D: :@nicks!) {
        @nicks == 1
          ?? %!nicks{@nicks[0]}.map(*.sort(*.key)).map(*.value.Slip)
          !! %!nicks{@nicks}.map(*.values).map(*.Slip).map(*.Slip)
               .sort: *.target
    }
    multi method entries(IRC::Channel::Log:D: :$nicks!) {
        %!nicks{$nicks<>}.map(*.values).map(*.Slip).map(*.Slip)
          .sort: *.target
    }

    # just all of them
    multi method entries(IRC::Channel::Log:D: ) {
        @!logs.map: *.entries.Slip
    }

#-------------------------------------------------------------------------------
# Utility methods

    method years() {
        @!years ||= $!logdir.dir(:test(/ ^ \d ** 4 $ /)).map(*.basename).sort
    }

    method watch-and-update() {
        start {
            my $year := self.years.tail;

            # outer loop in case we get to a new *year*
            loop {
                react {
                    whenever $!logdir.watch {
                        my $new := self.years.tail;
                        if $new ne $year {
                            $year := $new;
                            done;
                        }
                    }
                    whenever $!logdir.add($year).watch -> $event {
                        my $path := $event.path.IO;
                        if $path.f && $!class.IO2Date($path) -> $Date {
                            my $date := $Date.Str;

                            with finds(@!dates,$date) -> $pos {
                                my $log := @!logs[$pos];
                                $log.update($path);
                                (%!nicks{.key} := {}){$date} := .value
                                  unless %!nicks{.key}
                                  for $log.nicks;
                            }
                            else {
                                my $log := $!class.new($path, $date);
                                inserts(@!dates, $date, @!logs, $log);
                                %!nicks{.key}{$date} := .value for $log.nicks;
                            }
                        }
                    }
                }
            }
        }
    }

    method this-date(str $date) {
        with finds(@!dates, $date) -> $pos {
            $date
        }
        else {
            nexts(@!dates, $date) // prevs(@!dates, $date)
        }
    }
    method next-date(str $date) { nexts(@!dates, $date) }
    method prev-date(str $date) { prevs(@!dates, $date) }
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
  logdir => "logs/raku",        # directory containing logs
  class  => IRC::Log::Colabti,  # for example
);

say $channel.dates;             # the dates for which there are logs available
say $channel.problems.elems;    # hash with problems / date

.say for $channel.entries;      # all entries of this channel

.say for $channel.entries(
  :conversation,           # only return conversational messages
  :control,                # only return control messages
  :dates<2021-04-23>,      # limit to given date(s)
  :nicks<lizmat japhb>,    # limit to given nick(s)
  :contains<foo>,          # limit to containing given text
  :starts-with<m:>,        # limit to starting with given text
  :matches(/ /d+ /),       # limit to matching regex
);

$channel.watch-and-update;  # watch and process updates

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
  logdir => "logs/raku",        # directory containing logs
  class  => IRC::Log::Colabti,  # for example
  name   => "foobar",           # defaults to logdir.basename
  batch  => 1,                  # defaults to 6
  degree => 8,                  # defaults to Kernel.cpu-cores
);

=end code

The C<new> class method returns a C<catchup>ped object that will eventually
become an C<IRC::Channel::Log> object.  It takes four named arguments:

=head3 logdir

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

=head3 class

The class to be used to interpret log files, e.g. C<IRC::Log::Colabti>.
This argument is also required.

=head3 name

The name of the channel.  Optional.  Defaults to the base name of the
directory specified with C<logdir>.

=head3 batch

The batch size to use when racing to read all of the log files of the
given channel.  Defaults to 6 as an apparent optimal values to optimize
for wallclock and not have excessive CPU usage.  You can use C<:!batch>
to indicate you do not want any multi-threading: this is equivalent to
specifying C<1> or C<0> or C<True>.

=head3 degree

The maximum number of threads to be used when racing to read all of the
log files of the given channel.  Defaults to C<Kernel.cpu-cores> (aka the
number of CPU cores the system claims to have).

=head1 INSTANCE METHODS

=head2 dates

=begin code :lang<raku>

say $channel.dates;          # the dates for which there are logs available

=end code

The C<dates> instance method returns a sorted list of dates (as strings
in YYYY-MM-DD format) of which there are entries available.

=head2 entries

=begin code :lang<raku>

.say for $channel.entries;   # all entries for this channel

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

=head3 :contains

=begin code :lang<raku>

# just "question"
$channel.entries(:contains<question>);

# "question" or "answer"
$channel.entries(:contains<question answer>);

# "question" and "answer"
$channel.entries(:contains<question answer>, :all);

=end code

The C<contains> named argument allows specification of one or more
strings that an entry should contain.  By default, an entry should
only contain one of the specified strings to be selected.  If you
want an entry to contain B<all> strings, then an additional C<:all>
named argument can be specified (with a true value).

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
that will stringify in the YYYY-MM-DD format.

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

=head3 :starts-with

=begin code :lang<raku>

# starts with "m:"
$channel.entries(:starts-with<m:>);

# starts with "m:" or "j:"
$channel.entries(:starts-with<m: j:>);

=end code

The C<start-with> named argument allows specification of one or more
strings that an entry should start with.

Since this only applies to conversational entries, any additional
setting of the C<conversation> or C<control> named arguments are
ignored.

=head2 next-date

=begin code :lang<raku>

say $channel.next-date($date);  # date after the given date with a log

=end code

The C<next-date> instance method takes a string representing a date, and
returns a string with the B<next> date of logs that are available.  Returns
C<Nil> if the specified date is the last date or after that.

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

The C<watch-and-update> instance method starts a threade (and returns its
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
