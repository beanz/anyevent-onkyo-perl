use strict;
use warnings;
package AnyEvent::Onkyo;
use base 'Device::Onkyo';
use AnyEvent::Handle;
use AnyEvent::Socket;
use Carp qw/croak carp/;
use Sub::Name;
use Scalar::Util qw/weaken/;

use constant {
  DEBUG => $ENV{ANYEVENT_ONKYO_DEBUG},
};


# ABSTRACT: AnyEvent module for controlling Onkyo/Integra AV equipment

=head1 SYNOPSIS

  use AnyEvent;
  use AnyEvent::Onkyo;
  $| = 1;
  my $cv = AnyEvent->condvar;
  my $onkyo = AnyEvent::Onkyo->new(device => 'discover',
                                   callback => sub {
                                     my ($cmd, $args, $obj) = @_;
                                     print "$cmd $args\n";
                                     unless ($cmd eq 'NLS') {
                                       $cv->send;
                                     }
                                   });
  $onkyo->command('volume up');
  $cv->recv;

=head1 DESCRIPTION

AnyEvent module for controlling Onkyo/Integra AV equipment.

B<IMPORTANT:> This is an early release and the API is still subject to
change. The serial port usage is entirely untested.

=cut

sub new {
  my ($pkg, %p) = @_;
  croak $pkg.'->new: callback parameter is required' unless ($p{callback});
  my $self = $pkg->SUPER::new(device => 'discover', %p);
  $self;
}

sub command {
  my $self = shift;
  my $cv = AnyEvent->condvar;
  my $weak_cv = $cv;
  weaken $weak_cv;
  $self->SUPER::command(@_, subname 'command_cb' => sub {
                          $weak_cv->send() if ($weak_cv);
                        });
  return $cv;
}

sub _handle_setup {
  my $self = shift;
  my $handle = $self->{handle};
  my $weak_self = $self;
  weaken $weak_self;
  $handle->on_rtimeout(subname 'on_rtimeout_cb' => sub {
    my ($handle) = @_;
    my $rbuf = \$handle->{rbuf};
    if ($$rbuf ne '') {
      print STDERR $handle, ": discarding '",
        (unpack 'H*', $$rbuf), "'\n" if DEBUG;
      $$rbuf = '';
    }
    $handle->rtimeout(0);
  });
  $handle->on_read(subname 'on_read_cb' => sub {
    my ($hdl) = @_;
    $hdl->push_read(ref $self => $self,
                    subname 'push_read_cb' => sub {
                      $weak_self->{callback}->(@_);
                      $weak_self->_write_now();
                      return 1;
                    });
  });
  1;
}

sub _open {
  my $self = shift;
  $self->SUPER::_open($self->_open_condvar);
  return 1;
}

sub _open_serial_port {
  my ($self, $cv) = @_;
  my $fh = $self->SUPER::_open_serial_port;
  $cv->send($fh);
  return $cv;
}

sub DESTROY {
  $_[0]->cleanup;
}

sub cleanup {
  my ($self, $error) = @_;
  print STDERR $self."->cleanup\n" if DEBUG;
  $self->{handle}->destroy if ($self->{handle});
  delete $self->{handle};
  undef $self->{discard_timer};
}

sub _open_condvar {
  my $self = shift;
  print STDERR "open_cv\n" if DEBUG;
  my $cv = AnyEvent->condvar;
  my $weak_self = $self;
  weaken $weak_self;

  $cv->cb(subname 'open_cb' => sub {
            my $fh = $_[0]->recv;
            print STDERR "start cb $fh @_\n" if DEBUG;
            my $handle; $handle =
              AnyEvent::Handle->new(
                fh => $fh,
                on_error => subname('on_error' => sub {
                  my ($handle, $fatal, $msg) = @_;
                  print STDERR $handle.": error $msg\n" if DEBUG;
                  $handle->destroy;
                  if ($fatal) {
                    $weak_self->cleanup($msg);
                  }
                }),
                on_eof => subname('on_eof' => sub {
                  my ($handle) = @_;
                  print STDERR $handle.": eof\n" if DEBUG;
                  $weak_self->cleanup('connection closed');
                }),
              );
            $weak_self->{handle} = $handle;
            $weak_self->_handle_setup();
            $weak_self->_write_now();
          });
  $weak_self->{_waiting} = ['fake for async open'];
  return $cv;
}

sub _open_tcp_port {
  my ($self, $cv) = @_;
  my $dev = $self->{device};
  print STDERR "Opening $dev as tcp socket\n" if DEBUG;
  my ($host, $port) = split /:/, $dev, 2;
  $port = $self->{port} unless (defined $port);
  $self->{sock} = tcp_connect $host, $port, subname 'tcp_connect_cb' => sub {
    my $fh = shift
      or do {
        my $err = (ref $self).": Can't connect to device $dev: $!";
        warn "Connect error: $err\n" if DEBUG;
        $self->cleanup($err);
        $cv->croak($err);
      };

    warn "Connected\n" if DEBUG;
    $cv->send($fh);
  };
  return $cv;
}

sub _real_write {
  my ($self, $str, $desc, $cb) = @_;
  print STDERR "Sending: ", $desc, "\n" if DEBUG;
  $self->{handle}->push_write($str);
}

sub _time_now {
  AnyEvent->now;
}

sub anyevent_read_type {
  my ($handle, $cb, $self) = @_;

  my $weak_self = $self;
  weaken $weak_self;

  subname 'anyevent_read_type_reader' => sub {
    my ($handle) = @_;
    my $rbuf = \$handle->{rbuf};
    $handle->rtimeout($weak_self->{discard_timeout});
    while (1) { # read all message from the buffer
      print STDERR "Before: ", (unpack 'H*', $$rbuf||''), "\n" if DEBUG;
      my $res = $weak_self->read_one($rbuf);
      return unless ($res);
      print STDERR "After: ", (unpack 'H*', $$rbuf), "\n" if DEBUG;
      $res = $cb->($res);
    }
  }
}

1;
