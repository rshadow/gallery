package Nginx::Module::Gallery;

use strict;
use warnings;
use utf8;
use 5.10.1;

=head1 NAME

Gallery - perl module for nginx.

=head1 SYNOPSIS

Example of nginx http section:

    http{
        ...
        # Path to Gallery.pm
        perl_modules  /usr/share/perl5/;
        perl_require  Nginx/Module/Gallery.pm;
    }

Example of nginx server section:

    server {
        listen                  80;

        server_name             gallery.localhost;

        location / {
            perl  Nginx::Module::Gallery::handler;
            # Path to image files
            root /usr/share/images;
        }
    }

=head1 DESCRIPTION

This module not for nginx event machine! One nginx worker (typically 8) used for
slow create icons!

Icon for image will be created and cached on first request.

=cut

# Module version
our $VERSION        = 0.01;

# Max icon size
our $ICON_SIZE      = 100;
# Path to cache and mode
our $CACHE_PATH     = '/var/cache/gallery';
our $CACHE_MODE     = 0755;
# Template path
our $TEMPLATE_PATH  = '/home/rubin/workspace/gallery/templates';
# Icons path
our $ICONS_PATH  = '/home/rubin/workspace/gallery/icons';
# Fixed icons
use constant ICON_UPDIR => 'edit-undo';
use constant ICON_TEXT  => 'text-x-preview';

use nginx;

use Mojo::Template;
use MIME::Base64 qw(encode_base64);
#use MIME::Types;
use File::Spec;
use File::Basename;
use File::Path qw(make_path);
use Digest::MD5 'md5_hex';
use List::MoreUtils qw(any);

use GD;
# Enable truecolor
GD::Image->trueColor(1);

sub handler($)
{
    my $r = shift;

    # Stop unless GET
    return HTTP_BAD_REQUEST unless $r->request_method eq 'GET';
    # Stop unless dir or file
    return HTTP_NOT_FOUND unless -f $r->filename or -d _;
    # Stop if header only
    return OK if $r->header_only;

    # show file
    return show_image($r) if -f _;
    # show directory index
    return show_index($r);
}

=head2 show_image

Send image to client

=cut

sub show_image($)
{
    my $r = shift;
    $r->send_http_header;
    $r->sendfile( $r->filename );
    return OK;
}

=head2 show_index

Send directory index to client

=cut

sub show_index($)
{
    my $r = shift;

    # Templates
    our %template;
    my $mt = Mojo::Template->new;
    # Mime type
    our %icon;
#    my $mimetypes = MIME::Types->new;
#    my $unknown   = MIME::Type->new(
#        encoding    => 'base64',
#        simplified  => 'unknown/unknown',
#        type        => 'x-unknown/x-unknown');

    # Send top of index page
    $r->send_http_header("text/html");
    $r->print( $mt->render( _template('top'), 'Gallery: '.$r->uri) );

    # Add updir for non root directory
    unless( $r->uri eq '/' )
    {
        # make link on updir
        my @updir = File::Spec->splitdir( $r->uri );
        pop @updir;
        my $updir = File::Spec->catdir( @updir );
        undef @updir;

        my ($raw, $mime) = _icon_generic( ICON_UPDIR );

        # Send updir icon
        my %item = (
            path        => File::Spec->updir,
            filename    => File::Spec->updir,
            type        => 'dir',
            href        => $updir,
            icon        => {
                raw     => $raw,
                type    => $mime,
            },
        );

        $r->print( $mt->render( _template('item'), \%item ) );
    }

    # Get directory index
    my $mask = File::Spec->catfile($r->filename, '*');
    $mask =~ s{(\s)}{\\$1}g;
    my @index = sort {-d $b cmp -d $a} sort {uc $a cmp uc $b} glob $mask;

    # Create index
    for my $path ( @index )
    {
        # Get filename
        my ($filename, $dir) = File::Basename::fileparse($path);
        my ($digit, $letter, $bytes, $human) = _as_human_size( -s $path );

        # Make item info hash
        my %item = (
            path        => $path,
            filename    => $filename,
            href        => File::Spec->catfile($r->uri, $filename),
            size        => $human,
            bytes       => $bytes,
        );

        # For folders get standart icon
        if( -d _ )
        {
            my ($raw, $mime) = _icon_generic('folder');

            # Save icon and some image information
            $item{icon}{raw}    = $raw;
            $item{icon}{type}   = $mime;

            # Remove directory size
            delete $item{size};

            $item{type} = 'dir';
        }
        # For images make icons and get some information
        elsif( $filename =~ m{^.*\.(?:png|jpg|jpeg|gif|xbm|gd|gd2|ico)$}i )
        {
            # Load icon from cache
            my ($raw, $mime, $image_width, $image_height) =
                get_icon_form_cache( $path );

            # Try to make icon
            unless( $raw )
            {
                ($raw, $mime, $image_width, $image_height) = make_icon( $path );
                # Try to save in cache
                save_icon_in_cache(
                    $path, $raw, $mime, $image_width, $image_height)
                        if $raw;
            }
            # Make generic image icon
            ($raw, $mime, $image_width, $image_height) =
                _icon_generic('image-x-generic')
                    unless $raw;

            # Save icon and some image information
            $item{icon}{raw}        = $raw;
            $item{icon}{type}       = $mime;
            $item{image}{width}     = $image_width;
            $item{image}{height}    = $image_height;
#            $item{image}{mime}    = $mimetypes->mimeTypeOf( $path ) || $unknown;

            $item{type} = 'image';
        }
        elsif( $filename =~ m{^.*\.(?:mp3|wav|ogg|oga)$}i )
        {
            # Load icon from cache
            my ($raw, $mime, $image_width, $image_height) =
                _icon_generic('audio-x-generic');

            # Save icon and some image information
            $item{icon}{raw}    = $raw;
            $item{icon}{type}   = $mime;

            $item{type} = 'audio';
        }
        elsif( $filename =~ m{^.*\.(?:avi|mov)$}i )
        {
            # Load icon from cache
            my ($raw, $mime, $image_width, $image_height) =
                _icon_generic('video-x-generic');

            # Save icon and some image information
            $item{icon}{raw}    = $raw;
            $item{icon}{type}   = $mime;

            $item{type} = 'video';
        }
        else
        {
            my ($raw, $mime, $image_width, $image_height) =
                _icon_generic( ICON_TEXT );

            # Save icon and some image information
            $item{icon}{raw}    = $raw;
            $item{icon}{type}   = $mime;

            $item{type} = 'file';
        }

        $r->print( $mt->render( _template('item'), \%item ) );
    }

    # Send bottom of index page
    $r->print( $mt->render( _template('bottom') ) );

    return OK;
}

=head2 _get_md5_image

Return unque MD5 hex string for image file

=cut

sub _get_md5_image($)
{
    my ($path) = @_;
    my ($size, $mtime) = ( stat($path) )[7,9];
    return md5_hex join( ',', $path, $size, $mtime );
}

sub get_icon_form_cache($)
{
    my ($path) = @_;

    my ($filename, $dir) = File::Basename::fileparse($path);

    # Find icon
    my $cache_mask = File::Spec->catfile(
        $CACHE_PATH, $dir, sprintf( '%s.*.base64', _get_md5_image( $path ) ) );
    my ($cache_path) = glob $cache_mask;

    # Icon not found
    return () unless $cache_path;

    # Get icon
    open my $f, '<:raw', $cache_path or return ();
    local $/;
    my $raw = <$f>;
    close $f;

    my ($image_width, $image_height, $mime) =
        $cache_path =~ m{^.*\.(\d+)x(\d+)\.(\w+)\.base64$}i;

    return ($raw, $mime, $image_width, $image_height);
}

sub save_icon_in_cache($$$$$)
{
    my ($path, $raw, $mime, $image_width, $image_height) = @_;

    my ($filename, $dir) = File::Basename::fileparse($path);

    # Create dirs
    my $error;
    make_path(
        File::Spec->catdir($CACHE_PATH, $dir),
        {
            mode    => $CACHE_MODE,
            error   => \$error,
        }
    );
    return if $! or @$error;

    # Make path
    my $cache = File::Spec->catfile(
        $CACHE_PATH,
        $dir,
        sprintf( '%s.%dx%d.%s.base64',
            _get_md5_image( $path ), $image_width, $image_height, $mime )
    );

    # Store icon on disk
    open my $f, '>:raw', $cache or return;
    print $f $raw;
    close $f;

    return $cache;
}

sub make_icon($)
{
    my ($path) = @_;

    # Get image
    open my $f, '<:raw', $path or return ();
    local $/;
    my $raw = <$f>;
    close $f;

    # Create small icon
    my $image   = GD::Image->new( $raw );
    return () unless $image;

    my ($image_width, $image_height, $width, $height, $mime);

    $image_width  = $width  = $image->width;
    $image_height = $height = $image->height;
    if($width <= $ICON_SIZE and $height <= $ICON_SIZE)
    {
        ;
    }
    elsif($width > $height)
    {
        $height = int( $ICON_SIZE * $height / $width || 1 );
        $width  = $ICON_SIZE;
    }
    elsif($width < $height)
    {
        $width  = int( $ICON_SIZE * $width / $height || 1 );
        $height = $ICON_SIZE;
    }
    else
    {
        $width  = $ICON_SIZE;
        $height = $ICON_SIZE;
    }

    # Create icon image
    my $icon = GD::Image->new( $width, $height, 1 );
    # Fill white
    $icon->fill(0, 0, $icon->colorAllocate(255,255,255) );
    # Copy and resize from original image
    $icon->copyResampled($image, 0, 0, 0, 0,
        $width, $height,
        $image_width, $image_height
    );

    # Make BASE64 encoding for inline
    $raw = MIME::Base64::encode_base64( $icon->png );
    $mime = 'png';

    return ($raw, $mime, $image_width, $image_height);
}

sub _template($$)
{
    my ($part) = @_;

    # Return template if loaded
    our %template;
    return $template{ $part } if $template{ $part };

    # Load template
    my $path = File::Spec->catfile($TEMPLATE_PATH, $part.'.html.tt');
    open my $f, '<:utf8', $path or return;
    local $/;
    $template{ $part } = <$f>;
    close $f;

    return $template{ $part };
}

sub _icon_generic
{
    my ($mime) = @_;

    # Return icon if already loaded
    our %icon;
    return ($icon{$mime}, $mime, $ICON_SIZE, $ICON_SIZE) if $icon{$mime};

    # Load icon
    my $path = File::Spec->catfile($ICONS_PATH, $mime.'.png');
    $icon{$mime}   = GD::Image->new( $path );
    $icon{$mime}->saveAlpha(1);
    return _icon_generic( ICON_TEXT )
        if ! $icon{$mime} and $mime ne ICON_TEXT;
    return () unless $icon{$mime};

    # Encode icon
    $icon{$mime} = MIME::Base64::encode_base64( $icon{$mime}->png );

    return ($icon{$mime}, 'png', $ICON_SIZE, $ICON_SIZE);
}

=head2 as_human_size(NUM)

converts big numbers to small 1024 = 1K, 1024**2 == 1M, etc

=cut

sub _as_human_size($)
{
    my ($size, $sign) = (shift, 1);

    my %result = (
        original    => $size,
        digit       => 0,
        letter      => '',
        human       => 'N/A',
        byte        => '',
    );

    {{
        last unless $size;
        last unless $size >= 0;

        my @suffixes = ('', 'K', 'M', 'G', 'T', 'P', 'E');
        my ($limit, $div) = (1024, 1);
        for (@suffixes)
        {
            if ($size < $limit || $_ eq $suffixes[-1])
            {
                $size = $sign * $size / $div;
                if ($size < 10)
                {
                    $size = sprintf "%1.2f", $size;
                }
                elsif ($size < 50)
                {
                    $size = sprintf "%1.1f", $size;
                }
                else
                {
                    $size = int($size);
                }
                s/(?<=\.\d)0$//, s/\.00?$// for $size;
                $result{digit}  = $size;
                $result{letter} = $_;
                $result{byte}   = 'B';
                last;
            }
            $div = $limit;
            $limit *= 1024;
        }
    }}

    $result{human} = $result{digit} . $result{letter} . $result{byte};

    return ($result{digit}, $result{letter}, $result{byte}, $result{human})
        if wantarray;
    return $result{human};
}

1;

=head1 AUTHORS

Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>,

Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

=head1 LICENSE

This program is free software: you can redistribute  it  and/or  modify  it
under the terms of the GNU General Public License as published by the  Free
Software Foundation, either version 3 of the License, or (at  your  option)
any later version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even  the  implied  warranty  of  MERCHANTABILITY  or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public  License  for
more details.

You should have received a copy of the GNU  General  Public  License  along
with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
