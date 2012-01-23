package Nginx::Module::Gallery;

use strict;
use warnings;
use utf8;
use 5.10.1;

=head1 NAME

Nginx::Module::Gallery - Gallery perl module for nginx. Like simple file index
but thumbnail replace default icon for image.

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

This module not for production servers! But for single user usage.
Gallery don`t use nginx event machine, so one nginx worker per connect
(typically 8) used for slow create icons!

All icons cached on first request. Next show will be more fast.

=cut

=head1 VARIABLES

=cut

# Module version
our $VERSION = 0.2.2;

=head2 ICON_MAX_DIMENSION

Max icon dimension. In pixels. All thumbnails well be resized to this dimension.

=cut

our $ICON_MAX_DIMENSION     = 100; # pixels

=head2 ICON_MAX_SIZE

Max icon size. In bytes. Default 128Kb.

=cut

our $ICON_MAX_SIZE          = 131072; # bytes

=head2 ICON_COMPRESSION_LEVEL

Icon comression level 0-9 for use in PNG

=cut

our $ICON_COMPRESSION_LEVEL = 95;

=head2 ICON_QUALITY_LEVEL

Icon quality level 0-9 for use in videos

=cut

our $ICON_QUALITY_LEVEL = 0;

=head2 CACHE_PATH

Path for thumbnails cache

=cut

our $CACHE_PATH     = '/var/cache/gallery';

=head2 CACHE_MODE

Mode for created thumbnails

=cut

our $CACHE_MODE     = 0755;

=head2 TEMPLATE_PATH

Templates path

=cut

our $TEMPLATE_PATH  = '/home/rubin/workspace/gallery/templates';

=head2 ICONS_PATH

Path for MIME and other icons

=cut

our $ICONS_PATH     = '/home/rubin/workspace/gallery/icons';

# Fixed icons
use constant ICON_FOLDER    => 'folder';
use constant ICON_UPDIR     => 'edit-undo';
use constant ICON_FAVICON   => 'emblem-photos';
# MIME type of unknown files
use constant MIME_UNKNOWN   => 'x-unknown/x-unknown';

use nginx 1.1.11;

use Mojo::Template;
use MIME::Base64 qw(encode_base64);
use MIME::Types;
use File::Spec;
use File::Basename;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use File::Find;
use Digest::MD5 'md5_hex';
use List::MoreUtils qw(any);
use URI::Escape qw(uri_escape);

# MIME definition objects
our $mimetypes = MIME::Types->new;
our $mime_unknown   = MIME::Type->new(
    encoding    => 'base64',
    simplified  => 'unknown/unknown',
    type        => 'x-unknown/x-unknown'
);
our $mime_png   = $mimetypes->mimeTypeOf( 'png' );

=head1 FUNCTIONS

=cut

=head2 handler $r

Main loop handler

=cut

sub handler($)
{
    my $r = shift;

    # Stop unless GET or HEAD
    return HTTP_BAD_REQUEST
        unless $r->request_method eq 'GET' or $r->request_method eq 'HEAD';
    # Return favicon
    return show_favicon($r) if $r->filename =~ m{favicon\.png$}i;
    # Stop unless dir or file
    return HTTP_NOT_FOUND unless -f $r->filename or -d _;
    # Stop if header only
    return OK if $r->header_only;

    # show file
    return show_image($r) if -f _;
    # show directory index
    return show_index($r);
}

=head1 PRIVATE FUNCTIONS

=cut

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

=head2 show_favicon

Send favicon

=cut

sub show_favicon($)
{
    my $r = shift;

    # Path to favicon
    my $favicon_path = File::Spec->catfile(
        $ICONS_PATH . '/' . ICON_FAVICON . '.png' );
    # MIME of favicon
    my $mime = $mimetypes->mimeTypeOf( $favicon_path ) || $mime_unknown;

    $r->send_http_header("$mime");
    $r->sendfile( $favicon_path );
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
    $mt->encoding('UTF-8');
    # Mime type
    our %icon;

    # Make title from path
    my @tpath =  File::Spec->splitdir( $r->uri );
    shift @tpath;
    push @tpath, '/' unless @tpath;
    my $title = 'Gallery - ' . join ' : ', @tpath;
    undef @tpath;

    # Send top of index page
    $r->send_http_header("text/html; charset=utf-8");
    $r->print(
        $mt->render(
            _template('top'),
            $TEMPLATE_PATH,
            $title
        )
    );

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
            href        => uri_escape( $updir ),
            icon        => {
                raw     => $icon->{raw},
                mime    => $icon->{mime},
            },
        );

        $r->print( $mt->render( _template('item'), \%item ) );
    }

    # Get directory index
    my $mask  = File::Spec->catfile( _escape_path($r->filename), '*' );
    my @index = sort {-d $b cmp -d $a} sort {uc $a cmp uc $b} glob $mask;

    # Create index
    for my $path ( @index )
    {
        # Get filename
        my ($filename, $dir) = File::Basename::fileparse($path);
        my ($digit, $letter, $bytes, $human) = _as_human_size( -s $path );
        my $mime = $mimetypes->mimeTypeOf( $path ) || $mime_unknown;
        my $href = File::Spec->catfile( $r->uri, $filename);

        # Make item info hash
        my %item = (
            path        => $path,
            filename    => $filename,
            href        => uri_escape( $href ),
            size        => $human,
            mime        => $mime,
        );

        # For folders get standart icon
        if( -d _ )
        {
            my $icon = _icon_common( ICON_FOLDER );

            # Save icon and some image information
            $item{icon}{raw}    = $icon->{raw};
            $item{icon}{mime}   = $icon->{mime};

            # Remove directory fails
            delete $item{size};
            delete $item{mime};
        }
        # For images make icons and get some information
        elsif( $mime->mediaType eq 'image' or $mime->mediaType eq 'video' )
        {
            # Has thumbnail
            $item{icon}{thumb}      = 1;

            # Load icon from cache
            my $icon = get_icon_form_cache( $path );
            # Try to make icon
            unless( $icon )
            {
                $icon = make_icon( $path, $mime, $r );
                # Try to save in cache
                save_icon_in_cache( $path, $icon ) if $icon;
            }
            # Make mime image icon
            unless( $icon )
            {
                $icon = _icon_mime( $path );
                # Can`t create/load thumbnail
                delete $item{icon}{thumb};
            }

            # Save icon and some image information
            $item{icon}{raw}        = $icon->{raw};
            $item{icon}{mime}       = $icon->{mime};
            $item{image}{width}     = $icon->{image}{width}
                if defined $icon->{image}{width};
            $item{image}{height}    = $icon->{image}{height}
                if defined $icon->{image}{height};
        }
        # Show mime icon for file
        else
        {
            # Load mime icon
            my $icon = _icon_mime( $path );

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

=head2 _get_md5_image $path

Return unque MD5 hex string for image file by it`s $path

=cut

sub _get_md5_image($)
{
    my ($path) = @_;
    my ($size, $mtime) = ( stat($path) )[7,9];
    return md5_hex join( ',', $path, $size, $mtime );
}

=head2 get_icon_form_cache $path

Check icon for image by $path in cache and return it if exists

=cut

sub get_icon_form_cache($)
{
    my ($path) = @_;

    my ($filename, $dir) = File::Basename::fileparse($path);

    # Find icon
    my $mask = File::Spec->catfile(
        _escape_path( File::Spec->catdir($CACHE_PATH, $dir) ),
        sprintf( '%s.*.base64', _get_md5_image( $path ) )
    );
    my ($cache_path) = glob $mask;

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
            height  => $image_height,
        },
    };
}

=head2 save_icon_in_cache

Save $icon in cache for image by $path

=cut

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

=head2 make_icon $path

Get $path of image and make icon for it

=cut

sub make_icon($;$$)
{
    my ($path, $mime, $r) = @_;

    # Get MIME type
    $mime //= $mimetypes->mimeTypeOf( $path ) || $mime_unknown;

    # Count icon width and height
    my ($raw, $image_width, $image_height, $image_size);

    if($mime->subType eq 'vnd.microsoft.icon')
    {
        # Show just small icons
        return unless -s $path < $ICON_MAX_SIZE;

        # Get image
        open my $fh, '<:raw', $path or return;
        local $/;
        $raw = <$fh>;
        close $fh or return;
        return unless $raw;
    }
    elsif( $mime->mediaType eq 'video')
    {
        # Full file read
        local $/;

        # Convert to temp thumbnail file
        my ($fh, $filename) =
            tempfile( UNLINK => 1, OPEN => 1, SUFFIX => '.png' );
        return unless $fh;

        system '/usr/bin/ffmpegthumbnailer',
            '-s', $ICON_MAX_DIMENSION,
            '-q', $ICON_QUALITY_LEVEL,
#            '-f',
            '-i', $path,
            '-o', $filename;

        # Get image
        local $/;
        $raw = <$fh>;
        close $fh or return;
        return unless $raw;

        $mime = $mime_png || $mime_unknown;
    }
    else
    {
        # Full file read
        local $/;

        # Get image params
        open my $pipe1, '-|:utf8',
            '/usr/bin/identify',
            '-format', '%wx%h %b',
            $path;
        my $params = <$pipe1>;
        close $pipe1;

        ($image_width, $image_height, $image_size) =
            $params =~ m/^(\d+)x(\d+)\s+(\d+)[a-zA-Z]*\s*$/;

        open my $pipe2, '-|:raw',
            '/usr/bin/convert',
            '-quiet',
            '-strip',
            '-delete', '1--1',
            $path,
            '-auto-orient',
            '-quality', $ICON_COMPRESSION_LEVEL,
            '-thumbnail', $ICON_MAX_DIMENSION.'x'.$ICON_MAX_DIMENSION.'>',
            '-colorspace', 'RGB',
            '-';
        $raw = <$pipe2>;
        close $pipe2;
        return unless $raw;

        # Get mime type as icon type
        $mime = $mime_png || $mime_unknown;
    }

    # Make as is BASE64 encoding for inline
    $raw = MIME::Base64::encode_base64( $raw );

    return {
        raw     => $raw,
        mime    => $mime,
        image   => {
            width   => $image_width,
            height  => $image_height,
            size    => $image_size,
        },
    };
}

=head2 _template $name

Retrun template my $name

=cut

sub _template($)
{
    my ($name) = @_;

    # Return template if loaded
    our %template;
    return $template{ $name } if $template{ $name };

    # Load template
    my $path = File::Spec->catfile($TEMPLATE_PATH, $name.'.html.ep');
    open my $f, '<:utf8', $path or return;
    local $/;
    $template{ $name } = <$f>;
    close $f;

    return $template{ $name };
}

=head2 _icon_common $name

Return common icon by $name

=cut

sub _icon_common
{
    my ($name) = @_;

    our %common;
    # Return if already loaded
    return $common{$name} if $common{$name};

    # Get icon path
    my $icon_path = File::Spec->catfile($ICONS_PATH, $name.'.png');

    # Load icon
    open my $fh, '<:raw', $icon_path or return;
    local $/;
    my $raw = <$fh>;
    close $fh or return;
    return unless $raw;

    # Make as is BASE64 encoding for inline
    $raw = MIME::Base64::encode_base64( $raw );

    # Encode icon
    $common{$name}{raw}     = $raw;
    $common{$name}{mime}    = $mimetypes->mimeTypeOf( $icon_path );

    return $common{$name};
}

=head2 _icon_mime $path

Return mime icon for file by $path

=cut

sub _icon_mime
{
    my ($path) = @_;

    my ($filename, $dir) = File::Basename::fileparse($path);
    my ($extension) = $filename =~ m{\.(\w+)$};

    my $mime    = $mimetypes->mimeTypeOf( $path ) || $mime_unknown;
    my $str     = "$mime";
    my $media   = $mime->mediaType;
    my $sub     = $mime->subType;
    my $full    = join '-', $mime =~ m{^(.*?)/(.*)$};

    # Return icon if already loaded
    our %mime;
    return $mime{$str} if $mime{$str};

    my @icon_path = (
        # Full MIME type
        File::Spec->catfile($ICONS_PATH, 'mime',
            sprintf( '%s-%s.png', $media, $sub ) ),
        # MIME::Type bug subType is empty =(
        File::Spec->catfile($ICONS_PATH, 'mime',
            sprintf( '%s.png', $full ) ),
        # Common by media type
        File::Spec->catfile($ICONS_PATH, 'mime',
            sprintf( '%s.png', $media ) ),
        # By file extension
        File::Spec->catfile($ICONS_PATH, 'mime',
            sprintf( '%s.png', $extension ) ),
    );

    # Load icon from varios paths
    my ($raw, $icon_path);
    for my $search_path ( @icon_path )
    {
        # Skip if file not exists
        next unless -f $search_path;

        # Load icon
        open my $fh, '<:raw', $search_path or next;
        local $/;
        $raw = <$fh>;
        close $fh or next;
        next unless $raw;

        # Save icon and stop search
        $icon_path = $search_path;
        last;
    }
    # Try to load default icon for unknown type
    return _icon_mime( MIME_UNKNOWN ) if ! $raw and $mime ne MIME_UNKNOWN;
    # Return unless icon =(
    return unless $raw;

    # Make as is BASE64 encoding for inline
    $raw = MIME::Base64::encode_base64( $raw );

    # Encode icon
    $mime{$str}{raw}     = $raw;
    $mime{$str}{mime}    = $mimetypes->mimeTypeOf( $icon_path );

    return $mime{$str};
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

=head2 _escape_path $path

Return escaped $path

=cut

sub _escape_path($)
{
    my ($path) = @_;
    my $escaped = $path;
    $escaped =~ s{([\s'".?*\(\)\+\}\{\]\[])}{\\$1}g;
    return $escaped;
}

1;

=head1 AUTHORS

Copyright (C) 2012 Dmitry E. Oboukhov <unera@debian.org>,

Copyright (C) 2012 Roman V. Nikolaev <rshadow@rambler.ru>

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
