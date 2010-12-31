#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 36;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp;
use IO::File;

# Bad bees. Get away from my sugar.
# Ow. OW. Oh, they're defending themselves somehow.
use_ok 'Mojo::Loader';

# Exception
my $loader = Mojo::Loader->new;
my $e      = $loader->load('LoaderException');
is ref $e, 'Mojo::Exception', 'right object';
like $e->message, qr/Missing right curly/, 'right message';
is $e->lines_before->[0]->[0],   8,         'right line';
like $e->lines_before->[0]->[1], qr/Apu/,   'right value';
is $e->lines_before->[1]->[0],   9,         'right line';
like $e->lines_before->[1]->[1], qr/whizz/, 'right value';
is $e->lines_before->[2]->[0],   10,        'right line';
is $e->lines_before->[2]->[1],   '',        'right value';
is $e->lines_before->[3]->[0],   11,        'right line';
is $e->lines_before->[3]->[1],   'foo {',   'right value';
is $e->lines_before->[4]->[0],   12,        'right line';
is $e->lines_before->[4]->[1],   '',        'right value';
is $e->line->[0], 13,   'right line';
is $e->line->[1], "1;", 'right value';
like "$e", qr/Missing right curly/, 'right message';

# Complicated exception
$loader = Mojo::Loader->new;
$e      = $loader->load('LoaderException2');
is ref $e, 'Mojo::Exception', 'right object';
like $e->message, qr/Exception/, 'right message';
is $e->lines_before->[0]->[0], 1,                           'right line';
is $e->lines_before->[0]->[1], 'package LoaderException2;', 'right value';
is $e->lines_before->[1]->[0], 2,                           'right line';
is $e->lines_before->[1]->[1], '',                          'right value';
is $e->line->[0], 6, 'right line';
is $e->line->[1], 'LoaderException2_2::throw_error();', 'right value';
is $e->lines_after->[0]->[0], 7,    'right line';
is $e->lines_after->[0]->[1], '',   'right value';
is $e->lines_after->[1]->[0], 8,    'right line';
is $e->lines_after->[1]->[1], '1;', 'right value';
like "$e", qr/Exception/, 'right message';

$loader = Mojo::Loader->new;
my $modules = $loader->search('LoaderTest');
my @modules = sort @$modules;

# Search
is_deeply \@modules, [qw/LoaderTest::A LoaderTest::B LoaderTest::C/],
  'found the right modules';

# Load
$loader->load($_) for @modules;
ok LoaderTest::A->can('new'), 'loaded successfully';
ok LoaderTest::B->can('new'), 'loaded successfully';
ok LoaderTest::C->can('new'), 'loaded successfully';

# Class does not exist
ok $loader->load('LoaderTest'), 'nothing to load';

# Reload
my $file = IO::File->new;
my $dir  = File::Temp::tempdir(CLEANUP => 1);
my $path = File::Spec->catfile($dir, 'MojoTestReloader.pm');
$file->open("> $path");
$file->syswrite("package MojoTestReloader;\nsub test { 23 }\n1;");
$file->close;
push @INC, $dir;
require MojoTestReloader;
is MojoTestReloader::test(), 23, 'loaded successfully';
sleep 2;
$file->open("> $path");
$file->syswrite("package MojoTestReloader;\nsub test { 26 }\n1;");
$file->close;
Mojo::Loader->reload;
is MojoTestReloader::test(), 26, 'reloaded successfully';
