#!/usr/bin/env perl

use Mojo::Base -strict;

use Mojo::FriendFeed::CPANBot;
use Mojo::IOLoop;

my $file = shift or die "A configuration file is required.\n";
my $conf = do $file;

my $bot = Mojo::FriendFeed::CPANBot->new($conf);
$bot->run;

Mojo::IOLoop->start;

