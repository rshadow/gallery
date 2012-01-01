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

note 'Internal images tests';
_test_icon_params( Folder   => Nginx::Module::Gallery::_raw_folder_base64() );
_test_icon_params( UpDir    => Nginx::Module::Gallery::_raw_updir_base64()  );
_test_icon_params( Generic  =>
    Nginx::Module::Gallery::_raw_image_generic_base64() );

note 'Cache images tests';
my $data_path = catfile rel2abs(dirname __FILE__), 'data/*.png';
for my $path (glob $data_path)
{
    my $name = basename($path, '.png');

    my $md5 = Nginx::Module::Gallery::_get_md5_image( $path );
    ok length $md5,             'Get image MD5: '. $md5;

    my ($raw, $mime, $image_width, $image_height) =
        Nginx::Module::Gallery::make_icon( $path );

    _test_icon_params( Created => ($raw, $mime, $image_width, $image_height) );

    my $cache = Nginx::Module::Gallery::save_icon_in_cache(
        $path, $raw, $mime, $image_width, $image_height);
    SKIP:
    {
        skip 'Cache not aviable', 2 unless $cache;

        ok -f $cache,               'Icon stored in: '. $cache;
        ok -s _,                    'Icon not empty';

        _test_icon_params( Loaded =>
            Nginx::Module::Gallery::get_icon_form_cache( $path ) );
    }
}

sub _test_icon_params
{
    my ($name, $raw, $mime, $image_width, $image_height) = @_;

    ok length $raw,             sprintf '%s image BASE64 data', $name;
    ok length $mime,            sprintf '%s image mime type: %s', $name, $mime;
    ok length $image_width,     sprintf '%s image width: %s', $name,
                                    $image_width;
    ok length $image_height,    sprintf '%s image height: %s', $name,
                                    $image_height;

    my $size = length $raw;
    ok $size < 16384,           sprintf '%s image < 16Kb: %s', $name, $size;
}