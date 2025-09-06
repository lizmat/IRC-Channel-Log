use Array::Sorted::Util:ver<0.0.11+>:auth<zef:lizmat>;
use JSON::Fast:ver<0.19+>:auth<cpan:TIMOTIMO>;
use String::Color:ver<0.0.11+>:auth<zef:lizmat>;

class IRC::Channel::Log:ver<0.0.42>:auth<zef:lizmat> {
    has IO() $.logdir    is required is built(:bind);
    has      $.class     is required is built(:bind);
    has      &.generator is required is built(:bind);
    has IO() $.state                 is built(:bind);
    has      $.degree                is built(:bind);
    has      $.batch                 is built(:bind);
    has str  $.name = $!logdir.basename;
    has str  @.dates      is built(False);
    has str  @.years      is built(False);
    has      %.problems   is built(False);
    has String::Color $!sc;
    has      @!logs;        # log objects, same order as @!dates
    has      @!topics;      # topic entry objects, same order as @!dates
    has      %!nick-names;  # hash of known nick names

    # IO for file containing persistent color information
    method !colors-json() {
        $!state
          ?? $!state.add("colors.json")
          !! Nil
    }

    # Not done creating the object yet
    submethod TWEAK(--> Nil) {
        $!degree := Kernel.cpu-cores / 2 without $!degree;
        $!batch  := 16                   without $!batch;

        # Make sure we access the channel logs complex data
        # structures from one thread at a time, even though
        # each log is parsed in parallel.
        my $lock := Lock.new;

        # Read and process all log files asynchronously
        for $!logdir.dir.map(*.dir.Slip)
          .race(:$!degree, :$!batch)
          .map(-> $path { $_ with $!class.new($path) })
        -> $log {
            my $date := $log.date.Str;

            $lock.protect: {
                # Associate date with the log and other information
                inserts @!dates,  $date,
                        @!logs,   $log,
                        @!topics, $log.last-topic-change;

                # Remember the year we've seen
                inserts @!years, $date.substr(0,4);

                # Remember nicks seen on this date
                %!nick-names{$_} := 1 for $log.nick-names;

                # Remember any problems for this log
                %!problems{$date} := $log.problems.List
                  if $log.problems.elems;
            }
        }

        # Topic of a date is the last changed topic of previous date
        @!topics.pop;
        @!topics.unshift(Nil);
        my $last-topic := Nil;
        for 1 ..^ +@!topics -> int $i {
            if @!topics[$i] -> $topic {  # lose container
                $last-topic := @!topics[$i] := $topic;
            }
            else {
                @!topics[$i] := $last-topic;
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
            $!sc.add: %!nick-names.keys;
        }
    }

#-------------------------------------------------------------------------------
# The search workhorse

    method entries(IRC::Channel::Log:D:
      :$around-target,
      :$dates is raw,
      :$entries,
      :$reverse,
      *%options,
    ) {
        my @dates := $dates ?? (my str @ = $dates.map: *.Str) !! @!dates;

        # Search around given target, only available at this level
        if $around-target -> str $target {
            my int $entries = %options<nr-entries>:delete // 10;
            my $seq := (
              self.entries(
                |%options,
                :le-target($target),
                :reverse,
                :entries($entries + 1),
              ).Slip,
              self.entries(
                :%options,
                :gt-target($target),
                :!reverse,
                :$entries,
              ).Slip
            ).Slip;
            $reverse ?? $seq.reverse !! $seq
        }

        # Lazily determine here how much to return
        elsif $entries {
            my $buffer  := IterationBuffer.new;
            my int $todo = $entries;

            if $reverse {
                %options<reverse> := True;  # UNCOVERABLE
                for @dates.reverse.map(-> $date {
                    $_ with self.log($date)
                }) -> $log {
                    use nqp;    # Waiting for IterationBuffer.unshift
                    nqp::unshift($buffer,$_)
                      for $log.search(|%options).head($todo);
                    last unless $todo = $entries - $buffer.elems;
                }
            }
            else {
                for @dates.map(-> $date {
                    $_ with self.log($date)
                }) -> $log {
                    $buffer.push($_)
                      for $log.search(|%options).head($todo);
                    last unless $todo = $entries - $buffer.elems;
                }
            }
            $buffer.List
        }

        # Limitless, so let the consumer decide how much they want
        else {
            ($reverse ?? @dates.reverse !! @dates).map: -> str $date {
                .search(:$reverse, |%options).Slip with self.log($date);
            }
        }
    }

#-------------------------------------------------------------------------------
# Utility methods

    method active(IRC::Channel::Log:D: --> Bool:D) {
        $!state
          ?? !$!state.add("inactive").e
          !! True
    }

    method aliases-for-nick-name(IRC::Channel::Log:D: Str:D $nick) {
        $!sc.aliases($nick)
    }
    method cleaned-nick-name(IRC::Channel::Log:D: Str:D $nick) {
        $!sc.cleaner()($nick)
    }

    method watch-and-update(IRC::Channel::Log:D: :&post-process --> Promise:D) {
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
                            with finds(@!dates,$date) -> int $pos {
                                my $log := @!logs[$pos];

                                for $log.update($path) -> \entry {
                                    my $nick := entry.nick;
                                    %!nick-names{$nick} := 1;
                                    $!sc.add($nick);
                                    post-process(entry) if &post-process;
                                }

                                # In case it was updated
                                @!topics[$pos] := $log.last-topic-change;
                            }

                            # A new date
                            else {
                                my $log := $!class.new($path, $date);
                                my int $pos = inserts
                                  @!dates,  $date,
                                  @!logs,   $log,
                                  @!topics, Nil;   # update later

                                @!topics[$pos] :=
                                  @!logs[$pos - 1].last-topic-change
                                  // @!topics[$pos - 1]
                                  if $pos;

                                for $log.nick-names -> str $nick {
                                    %!nick-names{$nick} := 1;
                                    $!sc.add($nick);
                                }

                                if &post-process {
                                    post-process($_) for $log.entries;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

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

    # Return the initial topic for the given date, if any
    method initial-topic(IRC::Channel::Log:D: str $date) {
        with finds(@!dates, $date) -> $pos {
            @!topics[$pos] // Nil
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
    method is-first-date-of-year(IRC::Channel::Log:D: str $date --> Bool:D) {
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

    # Return the known nicknames
    method nick-names(IRC::Channel::Log:D:) {
        %!nick-names.keys.sort
    }

    # Perform all of the necessary shutdown work
    method shutdown(IRC::Channel::Log:D: --> Nil) {
        my $io := self!colors-json;
        $io.parent.mkdir unless $io.e;
        $io.spurt: to-json $!sc.Map, :!pretty;
    }
}

# vim: expandtab shiftwidth=4
