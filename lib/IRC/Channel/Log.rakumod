use v6.*;

class IRC::Channel::Log:ver<0.0.1>:auth<cpan:ELIZABETH> {
    has IO() $.logdir is required;
    has Mu   $.class  is required;
    has Str  $.name = $!logdir.basename;
    has      %.logs is built(False);

    method TWEAK(--> Nil) {
        %!logs = $!logdir.dir.map(*.dir.Slip)
#          .hyper(:1batch)    # sadly, hyper segfaults sometimes
          .map: { .date => $_ with $!class.new($_) }
    }
}

=begin pod

=head1 NAME

IRC::Channel::Log - access to all logs of an IRC channel

=head1 SYNOPSIS

=begin code :lang<raku>

use IRC::Channel::Log;

=end code

=head1 DESCRIPTION

IRC::Channel::Log is ...

=head1 AUTHOR

Elizabeth Mattijsen <liz@wenzperl.nl>

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Elizabeth Mattijsen

Source can be located at: https://github.com/lizmat/IRC-Channel-Log . Comments and
Pull Requests are welcome.

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
