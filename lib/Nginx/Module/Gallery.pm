package Nginx::Module::Gallery;

use strict;
use warnings;
use utf8;
use 5.10.1;

=head1 NAME

Gallery - perl module for nginx.

=head SYNOPSIS

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

        server_name             gallery.localhost www.gallery.localhost;

        access_log              /var/log/nginx/gallery.access.log;
        error_log               /var/log/nginx/gallery.error.log;

        gzip                    on;
        gzip_min_length         1000;
        gzip_disable            msie6;
        gzip_proxied            expired no-cache no-store private auth;
        gzip_types              image/png image/gif image/jpeg image/jpg
                                image/xbm image/gd image/gd2;

        location / {
            perl  Nginx::Module::Gallery::handler;
            # Path to image files
            root /usr/share/images;
        }
    }
=cut

our $VERSION=0.01;

#Max icon size
use constant ICON_SIZE  => 100;
# Path to cache and mode
use constant CACHE_PATH => '/var/cache/gallery';
use constant CACHE_MODE => 0755;

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

sub _raw_folder_base64();
sub _raw_updir_base64();
sub _raw_image_generic_base64();
sub _raw_audio_generic_base64();
sub _raw_video_generic_base64();

sub init {}
sub exit {}

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

        my ($raw, $mime) = _raw_updir_base64;

        # Send updir icon
        my %item = (
            path        => File::Spec->updir,
            filename    => File::Spec->updir,
            type        => 'dir',
            href        => $updir,
            image       => {
                raw     => $raw,
                type    => $mime,
            },
        );

        $r->print( $mt->render( _template('item'), \%item ) );
    }

    # Get directory index
    my $mask = File::Spec->catfile($r->filename, '*');
    $mask =~ s{(\s)}{\\$1}g;
    my @index = sort glob $mask;

    # Create index
    for my $path ( @index )
    {
        # Get filename
        my ($filename, $dir) = File::Basename::fileparse($path);

        # Make item info hash
        my %item = (
            path        => $path,
            filename    => $filename,
            href        => File::Spec->catfile($r->uri, $filename),
        );

        # For folders get standart icon
        if( -d $path )
        {
            my ($raw, $mime) = _raw_folder_base64;

            # Save icon and some image information
            $item{image}{raw}     = $raw;
            $item{image}{type}    = $mime;

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
                _raw_image_generic_base64
                    unless $raw;

            # Save icon and some image information
            $item{image}{raw}     = $raw;
            $item{image}{type}    = $mime;
            $item{image}{width}   = $image_width;
            $item{image}{height}  = $image_height;
            $item{image}{size}    = -s _;
#            $item{image}{mime}    = $mimetypes->mimeTypeOf( $path ) || $unknown;

            $item{type} = 'image';
        }
        elsif( $filename =~ m{^.*\.(?:mp3|wav|ogg|oga)$}i )
        {
            # Load icon from cache
            my ($raw, $mime, $image_width, $image_height) =
                _raw_audio_generic_base64;

            # Save icon and some image information
            $item{image}{raw}     = $raw;
            $item{image}{type}    = $mime;
            $item{image}{width}   = $image_width;
            $item{image}{height}  = $image_height;
            $item{image}{size}    = -s _;

            $item{type} = 'audio';
        }
        elsif( $filename =~ m{^.*\.(?:avi|mov)$}i )
        {
            # Load icon from cache
            my ($raw, $mime, $image_width, $image_height) =
                _raw_video_generic_base64;

            # Save icon and some image information
            $item{image}{raw}     = $raw;
            $item{image}{type}    = $mime;
            $item{image}{width}   = $image_width;
            $item{image}{height}  = $image_height;
            $item{image}{size}    = -s _;

            $item{type} = 'video';
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
        CACHE_PATH, $dir, sprintf( '%s.*.base64', _get_md5_image( $path ) ) );
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
        File::Spec->catdir(CACHE_PATH, $dir),
        {
            mode    => CACHE_MODE,
            error   => \$error,
        }
    );
    return if $! or @$error;

    # Make path
    my $cache = File::Spec->catfile(
        CACHE_PATH,
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
    if($width <= ICON_SIZE and $height <= ICON_SIZE)
    {
        ;
    }
    elsif($width > $height)
    {
        $height = int( ICON_SIZE * $height / $width || 1 );
        $width  = ICON_SIZE;
    }
    elsif($width < $height)
    {
        $width  = int( ICON_SIZE * $width / $height || 1 );
        $height = ICON_SIZE;
    }
    else
    {
        $width  = ICON_SIZE;
        $height = ICON_SIZE;
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

=head2 _raw_folder_base64

Return PNG image of folder encoded in base64

=cut

sub _raw_folder_base64()
{
    return ('
iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAEg0lEQVRYhe1ZK3ZcRxC90mlwwYAG
AQOyDMMAAQMBgQEGAgZZgqGXkWUYBAwIGGAQYBAQ4CUEGAxsMOCCOj4BVf15n7F0ougD1KDVr6q6
3n316+rRhX03vKRx+dwA5uMV0F3jFdBd4xXQXSO11fHb8XDYl5MAwITE1TnnfH2z2263jw7ocNjv
drfckAkyAGCiTLPF8Xjc/7HfXe+2Pz8Kpu4yGbihpHISDJLKqSwX+ae8u9kdPh+Ox+NjAErjAxMU
4IS1BRMl5U3e3ez2+0968KnDBG7y1S9Xzd5p5HVPSSRlohWl7BSkgCUTydv3v/qWh8wASil/fflz
9+52YaFEnI48FSUCwElIFMB0lIEmJdIBJcKk4KK4nRrFVFzDPShMyGBkEgDgwr6bPv9Wvu51KiQr
dnkgz2eAwGQOWz7MTiZucn5zzauPCUD5+mn75rqIeTOIkm6MsA0gkIAS6HRAYJjWZ48zK0oZJkIC
aRIAiJ43gOBiUArD41QAlL8PWwcEECo0QIC5GzPKcW6P0VqAUqYVJN8SaJAoMDChNNbS3v0DHChr
4IQWA9oXGIDScLQROGrewYoA1ACqRDcM6NzGatkw1dP0S4Hlsls79rjFAAt85xao63FurJnkuce6
SzAh5QDEBJhkpH+KQarlpy1qyWmUth7npm3cUvVjHLNd4Vw3k1KmAbUwjEbuwdHGjDJEwwTHILOk
zPbKSCsO6BJA1ECU9T3/gXL/EXEtL7YBCGR4dy69No+PazKymjCrlKV+Lx9urRrUudlcRpgkyQhI
RnlUgeH1tnDJ4dEliSIj1PZqQlHEqKN0JbACA5gRqUYOX1z8r+ct4dkrmKKCIw61SO8VAQDFVUWN
HSk97UtYJ1XfDS7LVWhxMrTCNXBXxHoBa16YbFkd871sab/ZwjRWwpX1UNm6cC1uXLCqvevjmv6m
MApsjyHU6gRAIgAVSTD5o1TQq6WYPCCi8EOlw20saXwc6U1/VwgA4iSGXLNUa1V0CwClAngaeuC7
+1kzSG1dH/t5osWiK4zvrO81DDGUCAiTtHfTcrTugt4q0LmZZxZN4fS9rVKDWQZ2Xrtm1MN/5cWt
t/NdAyt2DdpCXpO+oL0IiirYg5peDGpn0z79XMlfytyLvqbNOm5OXdbZrRV5shkANGYZM9SgDMHx
VLN3sd1lIGudqLwq92SUaaWO7r23LPN+aC2BVQ/adRlb07MUxtDq9yyr9weMY+hKXVPIajh9MA3V
H7B+oNAjqa4vfadA1HN4fTbAAnOlV0qsa3salKWMBm7XU1uaqK4pGPX+hnZC+VV1nA2obq10IMn7
85iDi2HvKKOZJKz6xa/LG1ZLedsb98swJKxV0qFQecEEp36pczN+p5+R9DDxNyq6M1g7XJnjUtaL
soNgJY71HgOLfQFU7kBcSg7dQHcZs9vF72XIbz+U3z/q2z94jsG8zW8/OJYL/yVfkk6KEfX6XF/1
P4HwHxva2NCPjov+rwWDTDWnZof/I4wEJvrMTXfixfr/Op7GQmmFfgbQ840X97PwiwP0LzfOZoqf
fLs9AAAAAElFTkSuQmCC', 'png', ICON_SIZE, ICON_SIZE);
}

=head2 _raw_updir_base64

Return PNG image for updir encoded in base64

=cut

sub _raw_updir_base64()
{
    return ('
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
AAAASUVORK5CYII=', 'png', ICON_SIZE, ICON_SIZE);
}


=head2 _raw_image_generic_base64

Return PNG image for non recognized images encoded in base64

=cut

sub _raw_image_generic_base64()
{
    return ('
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
HU+RLwE9Tf4HR7mPgteJdpMAAAAASUVORK5CYII=', 'png', ICON_SIZE, ICON_SIZE);
}

sub _raw_audio_generic_base64()
{
    return ('
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',
    'png', ICON_SIZE, ICON_SIZE);
}

sub _raw_video_generic_base64()
{
    return ('
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
AABJRU5ErkJggg==',
    'png', ICON_SIZE, ICON_SIZE);
}

sub _template($)
{
    my ($part) = @_;

    our %template;

    if( $part eq 'top' )
    {
        return $template{top} if $template{top};

        $template{top} = <<'EOF';
% my ($title) = @_;
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <title><%= $title || '' =%></title>
    <style type="text/css">
        body {
            font: 10pt sans-serif;
        }
        a {
            text-decoration: none;
            color: #000;
        }
        div.item {
            max-width: 128px;
            height: 128px;
            max-height: 128px;
            float: left;
            text-align: center;
            margin: 8px;
        }
        details.filename {
            word-wrap: break-word;

        }
        details.extended {
            font-size: 8pt;
            color: #667;
        }
        img.image {
            box-shadow: 0px 0px 3px 2px rgba(0,0,0,0.6);
            border: none;
        }
    </style>
</head>
<body>
    <header>
    </header>
    <article>
EOF
        return $template{top};
    }
    if( $part eq 'item' )
    {
        return $template{item} if $template{item};

        $template{item} = <<'EOF';
        % my ($item) = @_;
        <div class="item">
            <% if( $item->{type} eq 'dir' ) { %>
                <a href="<%= $item->{href} %>">
                    <img
                        src="data:image/<%= $item->{image}{type} %>;base64,<%= $item->{image}{raw} %>"
                    />
                    <br/>
                    <details class="filename" open="open">
                        <%= $item->{filename} %>
                    </details>
                </a>
            <% } elsif( $item->{type} eq 'image' ) { %>
                <a href="<%= $item->{href} %>">
                    <img
                        class="image"
                        src="data:image/<%= $item->{image}{type} %>;base64,<%= $item->{image}{raw} %>"
                    />
                    <br/>
                    <details class="filename" open="open">
                        <%= $item->{filename} %>
                    </details>
                    <br/>
                    <details class="extended" open="open">
                        <% if(defined $item->{image}{width} and defined $item->{image}{height} ) { %>
                            <%= $item->{image}{width} %> x <%= $item->{image}{height} %>
                            <br/>
                        <% } %>
                        <% if( defined $item->{image}{size} ) { %>
                            <%= $item->{image}{size} || 0 %> bytes
                        <% } %>
                   </details>
                </a>
            <% } elsif( List::MoreUtils::any { $item->{type} eq $_ } qw(audio video) ) { %>
                <a href="<%= $item->{href} %>">
                    <img
                        src="data:image/<%= $item->{image}{type} %>;base64,<%= $item->{image}{raw} %>"
                    />
                    <br/>
                    <details class="filename" open="open">
                        <%= $item->{filename} %>
                    </details>
                </a>
            <% } else { %>
                <details class="filename" open="open">
                    <%= $item->{filename} %>
                </details>
            <% } %>
        </div>
EOF
        return $template{item};
    }
    elsif( $part eq 'bottom' )
    {
        return $template{bottom} if $template{bottom};

        $template{bottom} = <<'EOF';
    </article>
    <footer>
    </footer>
</body>
</html>
EOF
        return $template{bottom};
    }
    else
    {
        return;
    }
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
