package TOML::Parser;
use 5.010000;
use strict;
use warnings;
use Encode;

our $VERSION = "0.91";

use TOML::Parser::Tokenizer qw/:constant/;
use TOML::Parser::Tokenizer::Strict;
use TOML::Parser::Util qw/unescape_str/;
use Types::Serialiser;

sub new {
    my $class = shift;
    my $args  = (@_ == 1 and ref $_[0] eq 'HASH') ? +shift : +{ @_ };
    return bless +{
        inflate_datetime => sub { $_[0] },
        inflate_boolean  => sub { $_[0] eq 'true' ? Types::Serialiser::true : Types::Serialiser::false },
        strict_mode      => 0,
        %$args,
    } => $class;
}

sub parse_file {
    my ($self, $file) = @_;
    open my $fh, '<:encoding(utf-8)', $file or die $!;
    return $self->parse_fh($fh);
}

sub parse_fh {
    my ($self, $fh) = @_;
    my $src = do { local $/; <$fh> };
    return $self->parse($src);
}

sub _tokenizer_class {
    my $self = shift;
    return $self->{strict_mode} ? 'TOML::Parser::Tokenizer::Strict' : 'TOML::Parser::Tokenizer';
}

our @TOKENS;
our $ROOT;
our $CONTEXT;
sub parse {
    my ($self, $src) = @_;

    local $ROOT    = {};
    local $CONTEXT = $ROOT;
    local @TOKENS  = $self->_tokenizer_class->tokenize($src);
    while (my $token = shift @TOKENS) {
        $self->_parse_token($token);
    }
    return $ROOT;
}

sub _parse_token {
    my ($self, $token) = @_;

    my ($type, $val) = @$token;
    if ($type eq TOKEN_TABLE) {
        $self->_parse_table($val);
    }
    elsif ($type eq TOKEN_ARRAY_OF_TABLE) {
        $self->_parse_array_of_table($val);
    }
    elsif (my ($key, $value) = $self->_parse_key_and_value($token)) {
        die "Duplicate key. key:$key" if exists $CONTEXT->{$key};
        $CONTEXT->{$key} = $value;
    }
    elsif ($type eq TOKEN_COMMENT) {
        # pass through
    }
    else {
        die "Unknown case. type:$type";
    }
}

sub _parse_key_and_value {
    my ($self, $token) = @_;

    my ($type, $val) = @$token;
    if ($type eq TOKEN_KEY) {
        my $token = shift @TOKENS;

        my $key = $val;
        my $value = $self->_parse_value_token($token);
        return ($key, $value);
    }

    return;
}

sub _parse_table {
    my ($self, $keys) = @_;
    my @keys = @$keys;

    $CONTEXT = $ROOT;
    for my $k (@keys) {
        if (exists $CONTEXT->{$k}) {
            $CONTEXT = ref $CONTEXT->{$k} eq 'ARRAY' ? $CONTEXT->{$k}->[-1] :
                       ref $CONTEXT->{$k} eq 'HASH'  ? $CONTEXT->{$k}       :
                       die "invalid structure. @{[ join '.', @keys ]} cannot be `Table`";
        }
        else {
            $CONTEXT = $CONTEXT->{$k} ||= +{};
        }
    }
}

sub _parse_array_of_table {
    my ($self, $keys) = @_;
    my @keys     = @$keys;
    my $last_key = pop @keys;

    $CONTEXT = $ROOT;
    for my $k (@keys) {
        if (exists $CONTEXT->{$k}) {
            $CONTEXT = ref $CONTEXT->{$k} eq 'ARRAY' ? $CONTEXT->{$k}->[-1] :
                       ref $CONTEXT->{$k} eq 'HASH'  ? $CONTEXT->{$k}       :
                       die "invalid structure. @{[ join '.', @keys ]} cannot be `Array of table`.";
        }
        else {
            $CONTEXT = $CONTEXT->{$k} ||= +{};
        }
    }

    $CONTEXT->{$last_key} = [] unless exists $CONTEXT->{$last_key};
    die "invalid structure. @{[ join '.', @keys ]} cannot be `Array of table`" unless ref $CONTEXT->{$last_key} eq 'ARRAY';
    push @{ $CONTEXT->{$last_key} } => $CONTEXT = {};
}

sub _parse_value_token {
    my $self  = shift;
    my $token = shift;

    my ($type, $val, @args) = @$token;
    if ($type eq TOKEN_COMMENT) {
        return; # pass through
    }
    elsif ($type eq TOKEN_INTEGER || $type eq TOKEN_FLOAT) {
        $val =~ tr/_//d;
        return 0+$val;
    }
    elsif ($type eq TOKEN_BOOLEAN) {
        return $self->inflate_boolean($val);
    }
    elsif ($type eq TOKEN_DATETIME) {
        return $self->inflate_datetime($val);
    }
    elsif ($type eq TOKEN_STRING) {
        my ($is_raw) = @args;
        return $is_raw ? $val : unescape_str($val);
    }
    elsif ($type eq TOKEN_MULTI_LINE_STRING_BEGIN) {
        my ($is_raw) = @args;
        my $value = $self->_parse_value_token(shift @TOKENS);
        $value =~ s/\A(?:\r\n|[\r\n])//msg;
        $value =~ s/\\\s+//msg;
        if (my $token = shift @TOKENS) {
            my ($type) = @$token;
            return $value if $type eq TOKEN_MULTI_LINE_STRING_END;
            die "Unexpected token: $type";
        }
    }
    elsif ($type eq TOKEN_INLINE_TABLE_BEGIN) {
        my %data;
        while (my $token = shift @TOKENS) {
            last if $token->[0] eq TOKEN_INLINE_TABLE_END;
            next if $token->[0] eq TOKEN_COMMENT;
            my ($key, $value) = $self->_parse_key_and_value($token);
            die "Duplicate key. key:$key" if exists $data{$key};
            $data{$key} = $value;
        }
        return \%data;
    }
    elsif ($type eq TOKEN_ARRAY_BEGIN) {
        my @data;

        my $last_token;
        while (my $token = shift @TOKENS) {
            last if $token->[0] eq TOKEN_ARRAY_END;
            next if $token->[0] eq TOKEN_COMMENT;
            if ($self->{strict_mode}) {
                die "Unexpected token: $token->[0]" if defined $last_token && $token->[0] ne $last_token->[0];
            }
            push @data => $self->_parse_value_token($token);
            $last_token = $token;
        }
        return \@data;
    }

    die "Unexpected token: $type";
}

sub inflate_datetime {
    my $self = shift;
    return $self->{inflate_datetime}->(@_);
}

sub inflate_boolean {
    my $self = shift;
    return $self->{inflate_boolean}->(@_);
}

1;
__END__

=encoding utf-8

=for stopwords versa

=head1 NAME

TOML::Parser - simple toml parser

=head1 SYNOPSIS

    use TOML::Parser;

    my $parser = TOML::Parser->new;
    my $data   = $parser->parse($toml);

=head1 DESCRIPTION

TOML::Parser is a simple toml parser.

This data structure complies with the tests
provided at L<https://github.com/toml-lang/toml/tree/v0.4.0/tests>.

The v0.4.0 specification is supported.

=head1 METHODS

=over

=item my $parser = TOML::Parser->new(\%args)

Creates a new TOML::Parser instance.

    use TOML::Parser;

    # create new parser
    my $parser = TOML::Parser->new();

Arguments can be:

=over

=item * C<inflate_datetime>

If use it, You can replace inflate C<datetime> process.
The subroutine of default is C<identity>. C<e.g.) sub { $_[0] }>

    use TOML::Parser;
    use DateTime;
    use DateTime::Format::ISO8601;

    # create new parser
    my $parser = TOML::Parser->new(
        inflate_datetime => sub {
            my $dt = shift;
            return DateTime::Format::ISO8601->parse_datetime($dt);
        },
    );

=item * C<inflate_boolean>

If use it, You can replace inflate boolean process.
The return value of default subroutine is C<Types::Serialiser::true> or C<Types::Serialiser::false>.

    use TOML::Parser;

    # create new parser
    my $parser = TOML::Parser->new(
        inflate_boolean => sub {
            my $boolean = shift;
            return $boolean eq 'true' ? 1 : 0;
        },
    );

=item * C<strict_mode>

TOML::Parser is using a more flexible rule for compatibility with old TOML of default.
If make this option true value, You can parse a toml with strict rule.

    use TOML::Parser;

    # create new parser
    my $parser = TOML::Parser->new(
        strict_mode => 1
    );

=back

=item my $data = $parser->parse_file($path)

=item my $data = $parser->parse_fh($fh)

=item my $data = $parser->parse($src)

Transforms a string containing toml to a perl data structure or vice versa.

=back

=head1 SEE ALSO

L<TOML>

=head1 LICENSE

Copyright (C) karupanerura.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

karupanerura E<lt>karupa@cpan.orgE<gt>

=head1 CONTRIBUTOR

Olivier Mengu?? E<lt>dolmen@cpan.orgE<gt>
yowcow E<lt>yowcow@cpan.orgE<gt>
Syohei YOSHIDA E<lt>syohex@gmail.comE<gt>

=cut
