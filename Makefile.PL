use ExtUtils::MakeMaker;

WriteMakefile(
    NAME            => "Nginx::Module::Gallery",
    VERSION_FROM    => "lib/Nginx/Module/Gallery.pm",
    ABSTRACT_FROM   => "lib/Nginx/Module/Gallery.pm",
    MAKEFILE        => 'Makefile',
    PREREQ_PM       => {
    'nginx'            => 0,
	'Mojo::Template'   => 0,
	'MIME::Base64'     => 0,
	'MIME::Types'      => 0,
	'File::Spec'       => 0,
	'File::Basename'   => 0,
	'File::Path'       => 0,
	'Digest::MD5'      => 0,
	'List::MoreUtils'  => 0,
	'GD'               => 0,
    },
    LICENSE         => 'GPLv3',
    AUTHOR          => [
        'Dmitry E. Oboukhov <unera@debian.org>,',
        'Roman V. Nikolaev <rshadow@rambler.ru>',
    ],
);