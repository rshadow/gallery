#!/usr/bin/perl

=head1 000-gallery.t

Nginx::Module::Gallery

=cut

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests        => 33;
use Encode                  qw(encode_utf8 decode_utf8);
use File::Basename          qw(dirname basename);
use File::Spec::Functions   qw(catfile rel2abs);

################################################################################
# BEGIN
################################################################################

BEGIN {
    # Use utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ':encoding(UTF-8)';
    binmode $builder->failure_output, ':encoding(UTF-8)';
    binmode $builder->todo_output,    ':encoding(UTF-8)';

    note "*** Тест Nginx::Module::Gallery ***";
    use_ok 'Nginx::Module::Gallery';

    require_ok 'Digest::MD5';
    require_ok 'GD';
    require_ok 'Mojo::Template';
    require_ok 'MIME::Base64';
}

################################################################################
# TEST
################################################################################

note 'Common icons tests';
my $common_icon_path = catfile rel2abs(dirname __FILE__), '../icons/*.png';
for my $path (glob $common_icon_path)
{
    my $filename    = basename($path);
    my $value       = basename($path, '.png');

    _test_icon_params( $value =>
        Nginx::Module::Gallery::_icon_common( $value )
    );
}

note 'Cache images tests';
my $data_path = catfile rel2abs(dirname __FILE__), 'data/*.png';
for my $path (glob $data_path)
{
    my $name = basename($path, '.png');

    my $md5 = Nginx::Module::Gallery::_get_md5_image( $path );
    ok length $md5,             'Get image MD5: '. $md5;

    my $icon = Nginx::Module::Gallery::make_icon( $path );
    _test_icon_params( make_icon => $icon );

    my $cache = Nginx::Module::Gallery::save_icon_in_cache($path, $icon);
    SKIP:
    {
        skip 'Cache not aviable', 2 unless $cache;

        ok -f $cache,               'Icon stored in: '. $cache;
        ok -s _,                    'Icon not empty';

        _test_icon_params( save_icon_in_cache =>
            Nginx::Module::Gallery::get_icon_form_cache( $path ) );
    }
}

sub _test_icon_params
{
    my ($name, $icon) = @_;

    ok length $icon->{raw},       sprintf '%s image BASE64 data', $name;
    ok length $icon->{mime},      sprintf '%s image mime type: %s', $name,
                                    $icon->{mime};
#    ok length $icon->{width},     sprintf '%s image width: %s', $name,
#                                    $icon->{width};
#    ok length $icon->{height},    sprintf '%s image height: %s', $name,
#                                    $icon->{height};

    my $size = length $icon->{raw};
    ok $size < 16384,           sprintf '%s image < 16Kb: %s', $name, $size;
}