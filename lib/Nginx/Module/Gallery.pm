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
our $VERSION = 0.2.4;

our %CONFIG;

# Fixed icons
use constant ICON_FOLDER    => '/folder.png';
use constant ICON_UPDIR     => '/updir.png';
use constant ICON_FAVICON   => '/favicon.png';

#use constant ICON_FAVICON   => 'emblem-photos';
# MIME type of unknown files
use constant MIME_UNKNOWN   => 'x-unknown/x-unknown';

use nginx 1.1.11;

use Mojo::Template;
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
    simplified  => 'unknown/unknown',
    type        => 'x-unknown/x-unknown'
);

# Default mime for thumbnails and icons
our $mime_png   = $mimetypes->mimeTypeOf( 'png' );

=head1 HANDLERS

=cut

=head2 handler $r

Main loop handler

=cut

sub handler($)
{
    my $r = shift;

    # Get configuration variables
    _get_variables($r);

    # Stop unless GET or HEAD
    return HTTP_BAD_REQUEST unless grep {$r->request_method eq $_} qw{GET HEAD};
    # Stop unless dir or file
    return HTTP_NOT_FOUND unless -f $r->filename or -d _;
    # Stop if header only
    return OK if $r->header_only;

    # show file
    return show_image($r) if -f _;
    # show directory index
    return show_index($r);
}

=head1 FUNCTIONS

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
            path    => $CONFIG{TEMPLATE_PATH},
            title   => $title,
            size    => $CONFIG{ICON_MAX_DIMENSION},
            favicon => {
                icon => {
                    href => _escape_url( $CONFIG{ICONS_PREFIX}, ICON_FAVICON ),
                },
            },
        )
    );

    # Add updir for non root directory
    unless( $r->uri eq '/' )
    {
        # make link on updir
        my @updir = File::Spec->splitdir( $r->uri );
        pop @updir;
        my $updir = _escape_url( File::Spec->catdir( @updir ) );
        undef @updir;

        # Send updir icon
        my %item = (
            path        => File::Spec->updir,
            filename    => File::Spec->updir,
            href        => $updir,
            icon        => {
                href    => _escape_url( $CONFIG{ICONS_PREFIX}, ICON_UPDIR ),
            },
        );

        $r->print( $mt->render( _template('item'), item => \%item ) );
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

        my @href = File::Spec->splitdir( $r->uri );
        my $href = _escape_url( File::Spec->catfile( @href, $filename ) );

        # Make item info hash
        my %item = (
            path        => $path,
            filename    => $filename,
            href        => $href,
            size        => $human,
            mime        => $mime,
        );

        # For folders get standart icon
        if( -d _ )
        {
            $item{icon}{href} = _escape_url($CONFIG{ICONS_PREFIX}, ICON_FOLDER);

            # Remove directory fails
            delete $item{size};
            delete $item{mime};
        }
        # For images make icons and get some information
        elsif( $mime->mediaType eq 'image' or $mime->mediaType eq 'video' )
        {
            # Load icon from cache
            my $icon = get_icon_form_cache( $path, $r->uri );
            # Try to make icon
            $icon = update_icon_in_cache( $path, $r->uri, $mime ) unless $icon;
            # Make mime image icon
            $icon = _icon_mime( $path ) unless $icon;

            # Save icon and some image information
            $item{icon} = $icon;
            $item{image}{width}     = $icon->{orig}{width}
                if defined $icon->{orig}{width};
            $item{image}{height}    = $icon->{orig}{height}
                if defined $icon->{orig}{height};
        }
        # Show mime icon for file
        else
        {
            # Load mime icon
            $item{icon} = _icon_mime( $path );
        }

        $r->print( $mt->render( _template('item'), item => \%item ) );
    }

    # Send bottom of index page
    $r->print( $mt->render( _template('bottom') ) );

    return OK;
}

=head2 get_icon_form_cache $path

Check icon for image by $path in cache and return it if exists

=cut

sub get_icon_form_cache($$)
{
    my ($path, $uri) = @_;

    my ($filename, $dir) = File::Basename::fileparse($path);

    # Find icon
    my $mask = File::Spec->catfile(
        _escape_path( File::Spec->catdir($CONFIG{CACHE_PATH}, $dir) ),
        sprintf( '%s.*', _get_md5_image( $path ) )
    );
    my ($cache_path) = glob $mask;

    # Icon not found
    return unless $cache_path;

    my ($image_width, $image_height, $ext) =
        $cache_path =~ m{^.*\.(\d+)x(\d+)\.(\w+)$}i;

    my ($icon_filename, $icon_dir) = File::Basename::fileparse($cache_path);

    return {
        href        => _escape_url($CONFIG{CACHE_PREFIX}, $uri, $icon_filename),
        filename    => $icon_filename,
        mime        => $mimetypes->mimeTypeOf( $ext ),
        image       => {
            width   => $image_width,
            height  => $image_height,
        },
        thumb       => 1,
        cached      => 1,
    };
}

=head2 update_icon_in_cache $path, $uri, $mime

Get $path and $uri of image and make icon for it

=cut

sub update_icon_in_cache($)
{
    my ($path, $uri, $mime ) = @_;

    # Get MIME type of original file
    $mime //= $mimetypes->mimeTypeOf( $path ) || $mime_unknown;

    my $icon;

    # Get raw thumbnail data
    if($mime->subType eq 'vnd.microsoft.icon')
    {
        $icon = _get_icon_thumb( $path );
    }
    elsif( $mime->mediaType eq 'video' )
    {
        $icon = _get_video_thumb( $path );
    }
    elsif( $mime->mediaType eq 'image' )
    {
        $icon = _get_image_thumb( $path );
    }

    return unless $icon;

    # Save thunbnail
    $icon = _save_thumb($icon);

    # Make href on thumbnail
    $icon->{href} =
        _escape_url( $CONFIG{CACHE_PREFIX}, $uri, $icon->{filename} );

    # Cleanup
    delete $icon->{raw};

    return wantarray ?%$icon :$icon;
}

=head1 PRIVATE FUNCTIONS

=cut

=head2 _get_video_thumb $path

Get raw thumbnail data for video file by it`s $path

=cut

sub _get_video_thumb($)
{
    my ($path) = @_;

    # Get standart extension
    my @ext     = $mime_png->extensions;
    my $suffix  = $ext[0] || 'png';

    # Full file read
    local $/;

    # Convert to temp thumbnail file
    my ($fh, $filename) =
        tempfile( UNLINK => 1, OPEN => 1, SUFFIX => '.'.$suffix );
    return unless $fh;

    system '/usr/bin/ffmpegthumbnailer',
        '-s', $CONFIG{ICON_MAX_DIMENSION},
        '-q', $CONFIG{ICON_QUALITY_LEVEL},
#            '-f',
        '-i', $path,
        '-o', $filename;

    # Get image
    my $raw = <$fh>;
    close $fh or return;
    return unless $raw;

    my $mime = $mime_png || $mime_unknown;

    my %result = (
        raw     => $raw,
        mime    => $mime,
        orig    => {
            path    => $path,
        },
    );

    return wantarray ?%result :\%result;
}

=head2 _get_image_thumb $path

Get raw thumbnail data for image file by it`s $path

=cut

sub _get_image_thumb($)
{
    my ($path) = @_;

    # Full file read
    local $/;

    # Get image params
    open my $pipe1, '-|:utf8',
        '/usr/bin/identify',
        '-format', '%wx%h %b',
        $path;
    my $params = <$pipe1> || '';
    close $pipe1;

    my ($image_width, $image_height, $image_size) =
        $params =~ m/^(\d+)x(\d+)\s+(\d+)[a-zA-Z]*\s*$/;

    open my $pipe2, '-|:raw',
        '/usr/bin/convert',
        '-quiet',
        '-strip',
        '-delete', '1--1',
        $path,
        '-auto-orient',
        '-quality', $CONFIG{ICON_COMPRESSION_LEVEL},
        '-thumbnail',
        $CONFIG{ICON_MAX_DIMENSION}.'x'.$CONFIG{ICON_MAX_DIMENSION}.'>',
        '-colorspace', 'RGB',
        '-';
    my $raw = <$pipe2>;
    close $pipe2;
    return unless $raw;

    # Get mime type as icon type
    my $mime = $mime_png || $mime_unknown;

    my %result = (
        raw     => $raw,
        mime    => $mime,
        orig    => {
            path    => $path,
            width   => $image_width,
            heigth  => $image_height,
            size    => $image_size,
        },
    );

    return wantarray ?%result :\%result;
}

=head2 _get_image_thumb $path

Get raw thumbnail data for icon file by it`s $path

=cut

sub _get_icon_thumb($)
{
    my ($path) = @_;

    # Show just small icons
    return unless -s $path < $CONFIG{ICON_MAX_SIZE};

    # Full file read
    local $/;

    # Get image
    open my $fh, '<:raw', $path or return;
    my $raw = <$fh>;
    close $fh or return;
    return unless $raw;

    my $mime = $mimetypes->mimeTypeOf( $path ) || $mime_unknown;

    my %result = (
        raw     => $raw,
        mime    => $mime,
        orig    => {
            path    => $path,
        },
    );

    return wantarray ?%result :\%result;
}

=head2 _save_thumb $icon

Save $icon in cache

=cut

sub _save_thumb($)
{
    my ($icon) = @_;

    my ($filename, $dir) = File::Basename::fileparse($icon->{orig}{path});

    # Create dirs
    my $error;
    make_path(
        File::Spec->catdir($CONFIG{CACHE_PATH}, $dir),
        {
            mode    => oct $CONFIG{CACHE_MODE},
            error   => \$error,
        }
    );
    return if @$error;

    my $icon_filename = sprintf( '%s.%dx%d.%s',
        _get_md5_image( $icon->{orig}{path} ),
        $icon->{orig}{width},
        $icon->{orig}{height},
        $icon->{mime}->subType
    );

    # Make path
    my $cache = File::Spec->catfile(
        $CONFIG{CACHE_PATH}, $dir, $icon_filename );

    # Store icon on disk
    open my $f, '>:raw', $cache or return;
    print $f $icon->{raw};
    close $f;

    # Set path and flag
    $icon->{path}       = $cache;
    $icon->{thumb}      = 1;
    $icon->{cached}     = 1;
    $icon->{filename}   = $icon_filename;

    return $icon;
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
    my $path = File::Spec->catfile($CONFIG{TEMPLATE_PATH}, $name.'.html.ep');
    open my $f, '<:utf8', $path or return;
    local $/;
    $template{ $name } = <$f>;
    close $f;

    return $template{ $name };
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

    my @ext = $mime_png->extensions;

    my $href = _escape_url(
        $CONFIG{MIME_PREFIX},
        sprintf( '%s.%s', $full, ($ext[0] || 'png') ),
    );

    return {
        mime    => $mime,
        href    => $href,
    };
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

=head2 _get_md5_image $path

Return unque MD5 hex string for image file by it`s $path

=cut

sub _get_md5_image($)
{
    my ($path) = @_;
    my ($size, $mtime) = ( stat($path) )[7,9];
    return md5_hex
        join( ',', $path, $size, $mtime,
            $CONFIG{ICON_MAX_DIMENSION}, $CONFIG{ICON_COMPRESSION_LEVEL},
            $CONFIG{ICON_QUALITY_LEVEL}
        );
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

=head2 _escape_url @path

Return escaped uri for list of @path partitions

=cut

sub _escape_url(@)
{
    my (@path) = @_;
    my @dirs;
    push @dirs, File::Spec->splitdir( $_ ) for @path;
    $_ = uri_escape $_ for @dirs;
    return File::Spec->catfile( @dirs );
}

=head2 _get_variables $r

Get configuration variables from request $r

=cut

sub _get_variables
{
    my ($r) = @_;

    $CONFIG{$_} //= $r->variable( $_ )
        for qw(ICON_MAX_DIMENSION   ICON_MAX_SIZE   ICON_COMPRESSION_LEVEL
               ICON_QUALITY_LEVEL
               CACHE_PATH           CACHE_MODE      CACHE_PREFIX
               TEMPLATE_PATH        ICONS_PATH      ICONS_PREFIX
               MIME_PREFIX);
    return 1;
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
