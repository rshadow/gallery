use strict;
use warnings;
use utf8;

package Gallery;

=head1 NAME

Gallery - perl module for nginx.

=head SYNOPSIS

Example of nginx http section:

    http{
        ...
        perl_modules  <PATH_TO_LIB>;
        perl_require  Gallery.pm;
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
            perl  Gallery::handler;
            root <PATH_FOR_IMAGE_GALLERY>;
        }
    }
=cut

our $VERSION=0.01;

use constant ICON_SIZE  => 100;

use nginx;

use Mojo::Template;
use MIME::Base64;
use GD;
use File::Spec;
use File::Basename;

sub _raw_folder_base64;

sub handler {
    my $r = shift;

    # Stop unless GET
    return HTTP_BAD_REQUEST unless $r->request_method eq 'GET';
    # Stop unless dir or file
    return HTTP_NOT_FOUND unless -f $r->filename or -d _;
    # Stop if header only
    return OK if $r->header_only;

    # Just send file
    if( -f _ )
    {
        $r->sendfile( $r->filename );
        return OK;
    }

    # Get directory index
    my @index = glob File::Spec->catfile($r->filename, '*');

    # Create two list of dirs and files hash
    my (@dirs, @files);

    # Add updir for non root directory
    unless( $r->uri eq '/' )
    {
        my @updir = File::Spec->splitdir( $r->uri );
        pop @updir;
        my $updir = File::Spec->catdir( @updir );
        undef @updir;

        my ($raw, $width, $height, $mime) = _raw_folder_base64;

        # Push upper directory link for non root directory
        push @dirs, {
            path        => File::Spec->updir,
            filename    => File::Spec->updir,
            type        => 'dir',
            href        => $updir,
            image       => {
                raw     => $raw,
                type    => $mime,
            },
            icon        => {
                width   => $width,
                height  => $height,
            }
        };
    }

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
            my ($raw, $width, $height, $mime) = _raw_folder_base64;

            # Save icon and some image information
            $item{image}{raw}     = $raw;
            $item{image}{type}    = $mime;
            $item{icon}{width}    = $width;
            $item{icon}{height}   = $height;

            $item{type} = 'dir';

            push @dirs, \%item;
        }
        # For images make icons and get some information
        elsif( $filename =~ m{^.*\.(?:png|jpg|jpeg|gif|xbm|gd|gd2)$}i )
        {
            # Get image
            open my $f, '<', $path;
            local $/;
            my $raw = <$f>;
            close $f;

            # Create small icon
            my $image   = GD::Image->new( $raw );
            next unless $image;

            my $width   = $image->width;
            my $height  = $image->height;
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

            my $icon    = GD::Image->new( $width, $height, 1 );
            $icon->copyResampled($image, 0, 0, 0, 0,
                $width, $height,
                $image->width, $image->height
            );

            # Make BASE64 encoding for inline
            $raw = MIME::Base64::encode_base64( $icon->png );

            # Save icon and some image information
            $item{image}{raw}     = $raw;
            ($item{image}{type})  = $filename =~ m{^.*\.(.*?)$};
            $item{image}{width}   = $image->width;
            $item{image}{height}  = $image->height;
            $item{image}{size}    = -s _;
            $item{icon}{width}    = $width;
            $item{icon}{height}   = $height;

            $item{type} = 'img';

            push @files, \%item;
        }
    }

    # Make sorted index
    @index = (
        sort({ uc($a->{filename}) cmp uc($b->{filename}) } @dirs  ),
        sort({ uc($a->{filename}) cmp uc($b->{filename}) } @files ),
    );

    # Render template for directory index
    my $mt = Mojo::Template->new;

    our $template;
    my $output = $mt->render(
        $template,
        'Gallery: '.$r->uri,
        \@index,
    );

    $r->send_http_header("text/html");
    # Send index for client
    $r->print( $output );
    return OK;
}

{
    our $template = <<'EOF';
% my ($title, $index) = @_;
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
        img {
            box-shadow: 0px 0px 3px 2px rgba(0,0,0,0.6);
            border: none;
        }
    </style>
</head>
<body>
    <header>
    </header>
    <article>
        <% for my $item (@$index) { %>
            <div class="item">
                <% if( $item->{type} eq 'dir' ) { %>
                    <a href="<%= $item->{href} %>">
                        <img
                            width="<%= $item->{icon}{width} %>"
                            height="<%= $item->{icon}{height} %>"
                            src="data:image/<%= $item->{image}{type} %>;base64,<%= $item->{image}{raw} %>"
                        />
                        <br/>
                        <details class="filename" open="open">
                            <%= $item->{filename} %>
                        </details>
                    </a>
                <% } elsif( $item->{type} eq 'file' ) { %>
                    <details class="filename" open="open">
                        <%= $item->{filename} %>
                    </details>
                <% } elsif( $item->{type} eq 'img' ) { %>
                    <a href="<%= $item->{href} %>">
                        <img
                            width="<%= $item->{icon}{width} %>"
                            height="<%= $item->{icon}{height} %>"
                            src="data:image/<%= $item->{image}{type} %>;base64,<%= $item->{image}{raw} %>"
                        />
                        <br/>
                        <details class="filename" open="open">
                            <%= $item->{filename} %>
                        </details>
                        <br/>
                        <details class="extended" open="open">
                            <%= $item->{image}{width} %> x <%= $item->{image}{height} %>
                            <br/>
                            <%= $item->{image}{size} || 0 %> bytes
                       </details>
                    </a>
                <% } %>
            </div>
        <% } %>
    </article>
    <footer>
    </footer>
</body>
</html>
EOF
}

=head2 _raw_folder_base64

Return PNG image of folder encoded in base64

=cut

sub _raw_folder_base64
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
fLs9AAAAAElFTkSuQmCC', 100, 100, 'png');

}

=head2 _raw_folder_base64

Return PNG image for non recognized images encoded in base64

=cut

sub _raw_image_generic
{
    return ('
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
HU+RLwE9Tf4HR7mPgteJdpMAAAAASUVORK5CYII=', 100, 100, 'png');
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
