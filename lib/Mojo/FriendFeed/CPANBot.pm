package Mojo::FriendFeed::CPANBot;
use Mojo::Base -base;

use Mojo::FriendFeed;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Mojo::DOM;
use Mojo::URL;
use Mojo::IRC;
use List::Util 'first';

use Getopt::Long;

has nickname => 'release_bot';
has server   => 'irc.perl.org:6667';
has user     => 'new cpan releases';

has jobs     => [];
has messages => [];

has feed   => sub { Mojo::FriendFeed->new( request => '/feed/cpan' ) };
has ioloop => sub { Mojo::IOLoop->singleton };
has irc    => sub {
  my $self = shift;
  Mojo::IRC->new(
    nick   => $self->nickname,
    server => $self->server,
    user   => $self->user,
  );
};
has ua  => sub { Mojo::UserAgent->new };

sub join { shift->irc->write( join    => shift ) };
sub send { shift->irc->write( privmsg => shift, ":@_" ) };

sub parse {
  my $self = shift;
  my $body = shift;
  my ($dist, $version) = $body =~ /^(\S+) (\S+)/;
  my $dom = Mojo::DOM->new($body);
  my $file_url = Mojo::URL->new($dom->at('a')->{href});
  my $pause_id = $file_url->path->parts->[-2];

  my $deps = $self->get_deps_metacpan($dist);

  return {
    dist     => $dist,
    version  => $version,
    file_url => $file_url,
    pause_id => $pause_id,
    text     => $dom->text,
    deps     => $deps,
  };
}

sub get_deps_metacpan {
  my ($self, $dist, $cb) = @_;
  my $url = "http://api.metacpan.org/v0/release/$dist";

  $process = sub {
    my $tx = shift;
    my $deps = $tx->res->json('/dependency') || [];
    my @deps = map { $_->{module} } @$deps; # } # highlight fix
    return \@deps;
  };

  # blocking
  unless ($cb) {
    return $self->ua->get($url)->$process();
  }

  # nonblocking
  $self->ua->get( $url => sub {
    my ($ua, $tx) = @_;
    if (my $err = $tx->error) {
      $self->$cb($err, undef);
    } else {
      my $deps = eval { $tx->$process() };
      $self->$cb($@, $deps);
    }
  });
}

$irc->register_default_event_handlers;
$irc->connect(sub{
  my ($irc, $err) = @_;
  if ($err) {
    warn $err;
    exit 1;
  }
  foreach my $job (@{ $conf{jobs} }) {
    next unless my $chan = $job->{channel};
    $irc->$join($chan) if $chan =~ /^#/;
  }
});

my @msgs;

$ff->on( entry => sub {
  my ($self, $entry) = @_;
  my $data = parse($entry->{body});
  
  my $msg = "$data->{text} http://metacpan.org/release/$data->{pause_id}/$data->{dist}-$data->{version}";
  say $msg;

  my @deps = @{ $data->{deps} || [] };

  for my $job (@{ $conf{jobs} }) {
    if (my $filter = $job->{dist}) {
      if ($data->{dist} =~ $filter) {
        push @{$self->messages}, [ $job->{channel} => $msg ];
        next;
      }
    }
    if (my $filter = $job->{deps}) {
      if (my $dep = first { $_ =~ $filter } @deps) {
        push @{$self->messages}, [ $job->{channel} => "$msg (depends on $dep)" ];
        next;
      }
    }
  }
});

$ff->on( error => sub { 
  my ($ff, $tx, $err) = @_;
  warn $err || $tx->res->message;
  $ff->listen
});

Mojo::IOLoop->recurring( 1 => sub {
  $irc->$send( @{ shift @msgs } ) if @msgs;
});

$ff->listen;

Mojo::IOLoop->start;

