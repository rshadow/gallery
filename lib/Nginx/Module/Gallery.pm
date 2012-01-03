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
use constant ICON_FOLDER    => 'folder';
use constant ICON_UPDIR     => 'edit-undo';

use constant MIME_UNKNOWN   => 'text/plain';

use nginx;

use Mojo::Template;
use MIME::Base64 qw(encode_base64);
use MIME::Types;
use File::Spec;
use File::Basename;
use File::Path qw(make_path);
use Digest::MD5 'md5_hex';
use List::MoreUtils qw(any);

use GD;
# Enable truecolor
GD::Image->trueColor(1);

# MIME definition objects
my $mimetypes = MIME::Types->new;
my $unknown   = $mimetypes->type( MIME_UNKNOWN );

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

    # Make title from path
    my @tpath = split m{/}, $r->uri;
    shift @tpath;
    push @tpath, '/' unless @tpath;
    my $title = 'Gallery - ' . join ' : ', @tpath;
    undef @tpath;

    # Send top of index page
    $r->send_http_header("text/html");
    $r->print( $mt->render( _template('top'), $TEMPLATE_PATH, $title ) );

    # Add updir for non root directory
    unless( $r->uri eq '/' )
    {
        # make link on updir
        my @updir = File::Spec->splitdir( $r->uri );
        pop @updir;
        my $updir = File::Spec->catdir( @updir );
        undef @updir;

        my $icon = _icon_common( ICON_UPDIR );

        # Send updir icon
        my %item = (
            path        => File::Spec->updir,
            filename    => File::Spec->updir,
            type        => 'dir',
            href        => $updir,
            icon        => {
                raw     => $icon->{raw},
                mime    => $icon->{mime},
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
        my $mime = $mimetypes->mimeTypeOf( $path ) || $unknown;

        # Make item info hash
        my %item = (
            path        => $path,
            filename    => $filename,
            href        => File::Spec->catfile($r->uri, $filename),
            size        => $human,
            bytes       => $bytes,
            type        => $mime->mediaType,
        );

        # For folders get standart icon
        if( -d _ )
        {
            my $icon = _icon_common( ICON_FOLDER );

            # Save icon and some image information
            $item{icon}{raw}    = $icon->{raw};
            $item{icon}{mime}   = $icon->{mime};

            # Remove directory size
            delete $item{size};

            $item{type} = 'dir';
        }
        # For images make icons and get some information
        elsif( $mime->mediaType eq 'image' )
        {
            # Load icon from cache
            my $icon = get_icon_form_cache( $path );
            # Try to make icon
            unless( $icon )
            {
                $icon = make_icon( $path );
                # Try to save in cache
                save_icon_in_cache( $path, $icon ) if $icon;
            }
            # Make generic image icon
            unless( $icon )
            {
                $icon = _icon_generic( MIME_UNKNOWN );
            }

            # Save icon and some image information
            $item{icon}{raw}        = $icon->{raw};
            $item{icon}{mime}       = $icon->{mime};
            $item{image}{width}     = $icon->{image}{width}
                if defined $icon->{image}{width};
            $item{image}{height}    = $icon->{image}{height}
                if defined $icon->{image}{height};
        }
        # Show gemeric icon for file
        else
        {
            # Load icon from cache
            my $icon = _icon_generic( $path );

            # Save icon and some image information
            $item{icon}{raw}        = $icon->{raw};
            $item{icon}{mime}       = $icon->{mime};
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

    my ($image_width, $image_height, $ext) =
        $cache_path =~ m{^.*\.(\d+)x(\d+)\.(\w+)\.base64$}i;

    return {
        raw     => $raw,
        mime    => $mimetypes->mimeTypeOf( $ext ),
        image   => {
            width   => $image_width,
            heigth  => $image_height,
        },
    };
}

sub save_icon_in_cache($$)
{
    my ($path, $icon) = @_;

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
            _get_md5_image( $path ),
            $icon->{image}{width},
            $icon->{image}{height},
            $icon->{mime}->subType
        )
    );

    # Store icon on disk
    open my $f, '>:raw', $cache or return;
    print $f $icon->{raw};
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

    # Load image
    my $image   = GD::Image->new( $raw );
    return unless $image;

    # Count icon width and heigth
    my ($image_width, $image_height, $width, $height);

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
    return unless $icon;
    # Fill white
    $icon->fill(0, 0, $icon->colorAllocate(255,255,255) );
    # Copy and resize from original image
    $icon->copyResampled($image, 0, 0, 0, 0,
        $width, $height,
        $image_width, $image_height
    );

    # Make BASE64 encoding for inline
    $raw = MIME::Base64::encode_base64( $icon->png );

    my $mime = $mimetypes->mimeTypeOf( $path ) || $unknown;

    return {
        raw     => $raw,
        mime    => $mime,
        width   => $width,
        heigth  => $height,
        image   => {
            width   => $image_width,
            heigth  => $image_height,
        },
    };
}

sub _template($$)
{
    my ($part) = @_;

    # Return template if loaded
    our %template;
    return $template{ $part } if $template{ $part };

    # Load template
    my $path = File::Spec->catfile($TEMPLATE_PATH, $part.'.html.ep');
    open my $f, '<:utf8', $path or return;
    local $/;
    $template{ $part } = <$f>;
    close $f;

    return $template{ $part };
}

sub _icon_common
{
    my ($type) = @_;

    our %common;
    # Return if already loaded
    return $common{$type} if $common{$type};

    # Get icon path
    my $icon_path = File::Spec->catfile($ICONS_PATH, $type.'.png');

    # Load icon
    my $icon = GD::Image->new( $icon_path );
    return unless $icon;

    # Save alpha channel
    $icon->saveAlpha(1);

    # Encode icon
    $common{$type}{raw}     = MIME::Base64::encode_base64( $icon->png );
    $common{$type}{mime}    = $mimetypes->mimeTypeOf( $icon_path );
    $common{$type}{width}   = $icon->width;
    $common{$type}{height}  = $icon->height;

    return $common{$type};
}

sub _icon_generic
{
    my ($path) = @_;

    my $mime    = $mimetypes->mimeTypeOf( $path ) || $unknown;
    my $str     = "$mime";

    # Return icon if already loaded
    our %generic;
    return $generic{$str} if $generic{$str};

    # Get icon path
    my $icon_path = File::Spec->catfile($ICONS_PATH, 'mime',
        $mime->mediaType.'-x-generic.png');

    # Load icon
    my $icon = GD::Image->new( $icon_path );
    # Try to load default icon for unknown type
    return _icon_generic( MIME_UNKNOWN ) if ! $icon and $mime ne MIME_UNKNOWN;
    return unless $icon;

    # Save alpha channel
    $icon->saveAlpha(1);

    # Encode icon
    $generic{$str}{raw}     = MIME::Base64::encode_base64( $icon->png );
    $generic{$str}{mime}    = $mimetypes->mimeTypeOf( $icon_path );
    $generic{$str}{width}   = $icon->width;
    $generic{$str}{height}  = $icon->height;

    return $generic{$str};
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
