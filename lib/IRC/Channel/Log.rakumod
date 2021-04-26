use v6.*;

class IRC::Channel::Log:ver<0.0.1>:auth<cpan:ELIZABETH> {
    has IO() $.logdir is required;
    has Mu   $.class  is required;
    has Str  $.name = $!logdir.basename;
    has      %.logs     is built(False);
    has      @.dates    is built(False);
    has      %.nicks    is built(False);
    has      %.problems is built(False);

    method TWEAK(--> Nil) {
        %!logs = $!logdir.dir.map(*.dir.Slip)
#          .hyper(:1batch)    # sadly, hyper segfaults sometimes
          .map: { .date => $_ with $!class.new($_) }

        @!dates = %!logs.keys.sort;

        %!problems = %!logs.map: {
            if .value.problems -> @problems {
                .key => @problems
            }
        }

        my %nicks;
        for @!dates -> $date {
            %nicks{.key}{$date} := .value for %!logs{$date}.nicks;
        }
        %!nicks := %nicks;
    }

    multi method entries(:$conversation!) {
        $conversation
          ?? self.entries(|%_).grep: *.conversation
          !! self.entries(|%_).grep: !*.conversation
    }
    multi method entries(:$control!) {
        $control
          ?? self.entries(|%_).grep: *.control
          !! self.entries(|%_).grep: !*.control
    }
    multi method entries(:$dates!, :$nicks!) {
        %!nicks{$nicks<>}{$dates<>}.map: { .Slip with $_ }
    }
    multi method entries(:@dates!, :$nicks!) {
        %!nicks{$nicks<>}{@dates.sort}.map: { .Slip with $_ }
    }
    multi method entries(:$dates!) {
        %!logs{$dates<>}.map: { .entries.Slip with $_ }
    }
    multi method entries(:@dates!) {
        %!logs{@dates.List}.map: { .entries.Slip with $_ }
    }
    multi method entries(:@nicks!) {
        if @nicks == 1 {
            %!nicks{@nicks[0]}.map(*.sort(*.key).map(*.value.Slip).Slip)
        }
        else {
            %!nicks{@nicks}.map(*.sort(*.key).map(*.value.Slip).Slip)
              .sort: *.target;
        }
    }
    multi method entries(:$nicks!) {
        %!nicks{$nicks<>}.map(*.sort(*.key).map(*.value.Slip).Slip)
    }
    multi method entries() {
        @!dates.map: { %!logs{$_}.entries.Slip }
    }
}

=begin pod

=head1 NAME

IRC::Channel::Log - access to all logs of an IRC channel

=head1 SYNOPSIS

=begin code :lang<raku>

use IRC::Log::Colabti;  # class implementing one day of logs
use IRC::Channel::Log;

my $channel = IRC::Channel::Log(
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
);

=end code

=head1 DESCRIPTION

IRC::Channel::Log provides a programmatic interface to the IRC log files
of a channel.

=head1 AUTHOR

Elizabeth Mattijsen <liz@wenzperl.nl>

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Elizabeth Mattijsen

Source can be located at: https://github.com/lizmat/IRC-Channel-Log . Comments and
Pull Requests are welcome.

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
