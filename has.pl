#!/usr/bin/perl
use strict;
use IO::Select;
use IO::Socket;
use Digest::MD5;

my (%conn,                                                 # connection data
    %world,                        # reverse lookup from world to connection
    $listener,                                                # the listener
    $readable,                                            # sockets to watch
    $hb,                                     # heartbeat connection to world
    @que,                                       # input que to watch out for
    %data,                          # misc data not specific to a connection
   );

#
# code
#    Show the stack dump when needed for debugging
#
sub code
{
   my $type = shift;
   my @stack;

   if(!$type || $type eq "short") {
      for my $line (split(/\n/,Carp::shortmess)) {
         if($line =~ /at ([^ ]+) line (\d+)\s*$/) {
            my ($fun,$ln) = ($1,$2);
            push(@stack,$2);
         }
      }
      return join(',',@stack);
   } else {
      return Carp::shortmess;
   }
}

sub offline
{
   return ($hb eq undef) ? 1 : 0;
}

#
# init_data
#    initalize any data that can be reloaded as needed.
#
sub init_data
{
   # keep track for fail over purposes
   if(@data{prev_mush_address} ne @data{mush_address}) {
      @data{prev_mush_address} = @data{mush_address};
   }

   @data{mush_address} = "192.168.1.7:4096";
   @data{local_port} = 4096;
   @data{beat} = 10;
   @data{timeout} = 2;
   @data{hb_user} = "heartbeat";
   @data{hb_pass} = "heartbeat";
   @data{offline_notice} = <<'   __EOF__';
   # NOTICE # This world is OFFLINE. Please wait till it returns.
   __EOF__
   @data{online_notice}=<<'   __EOF__';
   # NOTICE # This world is ONLINE. Normality has returned.
   __EOF__

   @data{offline_notice} =~ s/^   //gm;
   @data{online_notice} =~ s/^   //gm;
   @data{offline_notice} =~ s/([\r\n]+)$//;
   @data{online_notice} =~ s/([\r\n]+)$//;

   if(@data{prev_mush_address} ne @data{mush_address}) {
      printf("Remote Address: %s\n",@data{mush_address});
   }
}


#
# handle_disconnect
#    Something has disconnected as indicated by select(), figure out
#    what to do with it.
#
sub handle_disconnect
{
   my $id = shift;

   if($hb == $id) {                                   # heartbeat disconnect
      disconnect_hb();
   } elsif(defined @conn{$id}) {                        # client disconnect
      disconnect_client($id);
   } elsif(defined @world{$id}) {
      my $s = id($id);
      if(!defined @conn{$s}->{reconnect} || @conn{$s}->{reconnect} !=1 ) {
         # world may be down, check world status before disconnecting

         @conn{$s}->{disconnect} = time();
   
         if($hb eq undef) {
            disconnect_world($s);
            @conn{$s}->{reconnect} = 1;
         } else {
            @conn{$s}->{reconnect} = 1;
            printf($hb "think ### PING: " . $s . "###\n");
   
#            push(@que, { type => "disconnect",
#                         user => $1,
#                         pass => $2,
#                         sock => $s
#                    }
#                );
         }
      }
   }
}

sub online
{
   return ($hb eq undef) ? 0 : 1;
}

sub socket_open
{
   my $new = shift;

   my $sock = IO::Socket::INET->new(PeerAddr=>@data{mush_address},blocking=>0);
   return $sock;
}


sub world_connect
{
   my ($s,$was_offline) = @_;

   # do we have the info to reconnect?
   if($was_offline && !defined @conn{$s}->{user}&&!defined @conn{$s}->{pass}) {
      disconnect_client($s);
   }

   # assume failure
   @conn{$s} = {} if(!defined @conn{$s});
   @conn{$s}->{client} = $s,
   @conn{$s}->{created} = time() if(!defined @conn{created});

   return 0 if !online();

   my $new = socket_open($s);
   printf($new "\@REMOTEHOSTNAME %s\n",$s->peerhost);
   return 0 if($new eq undef);                            # did not connect

   @conn{$s}->{world} = $new;
   @world{$new} = $s;                                      # reverse lookup
   $readable->add($new);

   if($was_offline) {
      delete @conn{$s}->{disconnect};

      if(defined @conn{$s}->{user} && defined @conn{$s}->{pass}) {
         printf($new "connect %s %s\n",@conn{$s}->{user},@conn{$s}->{pass});
         printf($new "think ### RECONNECT COMPLETE ###\n");
      }
   }
   return 1;
}

sub handle_select
{
   my ($new, $buf,$bytes);

   my ($sockets) = IO::Select->select($readable,undef,undef,1);

   for my $s (@$sockets) {
      if($s == $listener) {                               # new connection
         if(($new = $listener->accept)) {
            $readable->add($new);
            world_connect($new);
         }
      } elsif(($bytes = sysread($s,$buf,1024)) <= 0) {
         handle_disconnect($s);                        # socket disconnected
      } elsif($bytes ne undef) {     # found input, process a line at a time
         @data{pend} = {} if ! defined @data{pend};
         @data{pend}->{$s} .= $buf;

         while(@data{pend}->{$s} =~ /(\r{0,1})\n/) {
            @data{pend}->{$s} = $';
            my $line = $`;

            if($s eq $hb) {                                       # heartbeat
#               printf("hb: '%s'\n",$line);
               io_hb($line);
            } elsif(defined @conn{$s}) {                        # client data
#               printf("client: '%s'\n",$line);
               io_client($s,$line);
            } elsif(defined @world{$s}) {                        # world data
#               printf("world: '%s'\n",$line);
               io_world($s,$line);
            } else {
#               printf("ignored[%s]: '%s'\n",$s,$line);
            }
         }
      }
   }
}

sub io_world
{
   my ($world_sock,$data) = @_;

   my $s = @world{$world_sock}; 

   return if !defined @conn{$s};

   my $sock = @conn{$s}->{client};
   if(defined @conn{$s}->{reconnect} && @conn{$s}->{reconnect} > 0) {
      if($data =~ /### RECONNECT COMPLETE ###/) {   # recon complete, stop gag
         printf($sock "%s\n",@data{online_notice});
         delete @conn{$s}->{reconnect};
      }
   } else {
      my $sock = @conn{$s}->{client};
      printf($sock "%s\n", $data);  # send world output to client
   }
}

#
# ignoreit
#    Ignore certain hash key entries at all depths or just the specified
#    depth.
#
sub ignoreit
{
   my ($skip,$key,$depth) = @_;


   if(!defined $$skip{$key}) {
      return 0;
   } elsif($$skip{$key} < 0 || ($$skip{$key} >= 0 && $$skip{$key} == $depth)) {
     return 1;
   } else {
     return 0;
   }
}

#
# print_var
#    Return a "text" printable version of a HASH / Array
#
sub print_var
{
   my ($var,$depth,$name,$skip,$recursive) = @_;
   my ($PL,$PR) = ('{','}');
   my $out;

   if($depth > 4) {
       return (" " x ($depth * 2)) .  " -> TO_BIG\n";
   }
   $depth = 0 if $depth eq "";
   $out .= (" " x ($depth * 2)) . (($name eq undef) ? "UNDEFINED" : $name) .
           " $PL\n" if(!$recursive);
   $depth++;

   for my $key (sort ((ref($var) eq "HASH") ? keys %$var : 0 .. $#$var)) {

      my $data = (ref($var) eq "HASH") ? $$var{$key} : $$var[$key];

      if((ref($data) eq "HASH" || ref($data) eq "ARRAY") &&
         !ignoreit($skip,$key,$depth)) {
         $out .= sprintf("%s%s $PL\n"," " x ($depth*2),$key);
         $out .= print_var($data,$depth+1,$key,$skip,1);
         $out .= sprintf("%s$PR\n"," " x ($depth*2));
      } elsif(!ignoreit($skip,$key,$depth)) {
         $out .= sprintf("%s%s = %s\n"," " x ($depth*2),$key,$data);
      }
   }

   $out .= (" " x (($depth-1)*2)) . "$PR\n" if(!$recursive);
   return $out;
}

sub user
{
   my $sock = id(shift);

   if(defined @conn{$sock}->{user}) {
      return @conn{$sock}->{user};
   } else {
      return "unconnected";
   }
}

# smaller
#    Return the hash id inside a reference for a socket. This should be
#    able to be passed to the remote world without without any problems.
#
sub smaller
{
    my $txt = shift;

    if($txt =~ /\(0x(.*)\)/) {
       return $1;
    } else {
       return $txt;
    }
}


sub list_sockets
{
   my $s = shift;

   for my $sock ($readable->handles) {
      if(defined @conn{$sock}) {
         printf($s "   client:   %s, status: %-12s, user: %s\n",
                smaller($sock),
                $sock->connected ? "Connected" : "Disconnected",
                user($sock)
               );
         if(user($sock) eq "unconnected" && 
            @conn{$sock}->{created} + 300 < time()) {
            printf($s "             *DISCONNECTING*\n");
            disconnect_client($sock);
         }
      } elsif(defined @world{$sock}) {
         printf($s "   world:    %s, status: %-12s, user: %s\n",
                smaller($sock),
                $sock->connected ? "Connected" : "Disconnected",
                user($sock)
               );
      } elsif($sock eq $hb) {
         printf($s "   hb:       %s, status: %-12s\n",
                smaller($sock),
                $sock->connected ? "Connected" : "Disconnected",
               );
      } elsif($sock eq $listener) {
         printf($s "   listener: %s\n",
                smaller($sock),
               );
       } else {
         printf($s "   unknown:  %s, status: %-12s\n",
                smaller($sock),
                $sock->connected ? "Connected" : "Disconnected",
               );
       }
   }
}


sub io_client
{
   my ($s,$data) = @_;

   return if !defined @conn{$s};
   my $sock = @conn{$s}->{world};

   if(offline()) {
      return;
   } elsif($data =~ /^#\?$/) {
      return list_sockets(@conn{$s}->{client});
   } elsif($data =~ /^\s*connect ([^\;\,\% ]+) ([^\;\,\% ]+)/i) {
      # verify the connect is successfull by having the HB verify the
      # password. The script will need to wait for the responce.
      
      push(@que, { type => "connect",
                   user => $1,
                   pass => $2,
                   sock => $s
                 }
          );
      printf($hb "think ### PASSWORD: [password(*%s,%s)] %s ###\n",
          $1,$2,@conn{$s}->{client});
   }
   printf($sock "%s\n", $data);
}

sub next_event
{
   return @que[0]->{type} if($#que >= 0);
}

sub io_hb
{
   my $data = shift;

   # received input from world, so its up... so disconnected client is
   # really disconnecting and not because the world crashed.
   for my $key (keys %conn) {
      if(defined @conn{$key}->{disconnect}) {
         disconnect_client(@conn{$key}->{client});   # world is up, disconnect
      }
   }

   if($data =~ /### PASSWORD: (0|1) ([^ ]+) ###$/) {
      
      if(next_event() eq "connect") {
 
         my $item = pop(@que);                           # pop event off que

         if($1 eq 1 && $2 eq $$item{sock}) {# successful login, pass was correct
            @conn{$$item{sock}}->{user} = $item->{user};
            @conn{$$item{sock}}->{pass} = $item->{pass};
            loggit("%s@%s has connected.",$item->{user},$$item{sock}->peerhost);
         }
      }
   }
}

sub ts
{
   my $time = shift;

   $time = time() if $time eq undef;
   my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
                                                localtime($time);
   $mon++;

   return sprintf("%02d:%02d:%02d %02d/%02d",$hour,$sec,$min,$mon,$mday);
}

sub loggit
{
   my ($fmt,@args) = @_;

   printf("%s]  $fmt\n",ts(),@args);
}

sub get_checksums
{
   my ($file,$pos,%data);
   my $ln = 1;
#

   open($file,$0) ||
     return printf("%% Unable to read source file, /reload will be disabled\n");

   for my $line (<$file>) {
      if($pos eq undef && $line =~ /^sub\s+([^ \n\r]+)\s*$/) {
         $pos = $1;
         @data{$pos} = { chk => Digest::MD5->new };
         @data{$pos}->{chk}->add($line);
         @data{$pos}->{src} .= qq[#line 0 "$pos"\n] . $line;
         @data{$pos}->{line} = $ln;
      } elsif($pos ne undef && $line =~ /^}\s*$/) {
         @data{$pos}->{src} .= $line;
         @data{$pos}->{chk}->add($line);
         @data{$pos}->{chk} = @data{$pos}->{chk}->hexdigest;
         @data{$pos}->{done} = 1;
         $pos = undef;
      } elsif($pos ne undef) {
         @data{$pos}->{src} .= $line;
         @data{$pos}->{chk}->add($line);
      }
      $ln++;
   }
   close($file);

   for my $pos (keys %data) {
      if(!defined @data{$pos}->{done}) {
         printf("% Warning: Did not find end to %s\n",$pos);
      }
   }
   return \%data;
}

#
# reload_code
#    As long as the global variables do not change, the code can be
#    reloaded without dropping any connections.
#
sub reload_code
{
   my $nomodules = shift;
   my $count = 0;

   my $new = get_checksums();
   my $old = @data{chksum};
   $old = {} if $old eq undef;

   for my $key (keys %$new) {
      if((!defined $$old{$key} || $$old{$key}->{chk} ne $$new{$key}->{chk})) {
         printf("%% Reloading: %s\n",$key);
         eval($$new{$key}->{src});
         $count++;
         if($@) {
            printf("%% Error reloading $key: %s\n",$@);
            $$new{$key}->{chk} = -1;
         }
      }
   }
   @data{chksum} = $new;

   if($count == 0) {
      printf("%% No changes found to reload.\n");
   }
   # test

   init_data();

   # fall over has been requested.
   if(@data{prev_mush_address} ne @data{mush_address}) {
      disconnect_hb();
   }
}

sub server_start
{
   my $port = shift;

   $listener = IO::Socket::INET->new(LocalPort=>@data{local_port},Listen=>1,
      Reuse=>1);
   $readable = IO::Select->new();
   $readable->add($listener);
}

sub hb_open_connect
{
   if(!online() && @data{hb_next} < time()) {
      my $prev = ($hb eq undef) ? 0 : 1;
      @data{hb_next} = time() + @data{beat};
      $hb = socket_open();

      if(online()) {
         $readable->add($hb);
         printf($hb "connect %s %s\n",@data{hb_user},@data{hb_pass});

         for my $key (keys %conn) {
            @conn{$key}->{was_offline} = 1;
            world_connect(@conn{$key}->{client},1);
         }
      } elsif($prev || defined @data{hb_never}) {
         delete @data{hb_never};
      }
   }
}


#
# sig_hup
#    Handle the HUP signal and reload the perl code in case the code can
#    not be reloaded any other way.
#
$SIG{HUP} = sub { sig_hup(); };

sub sig_hup
{
   reload_code();
}

sub id
{
   my $id = shift;

   if(defined @conn{$id}) {
      return @conn{$id}->{client};
   } elsif(defined @world{$id} && defined @conn{@world{$id}}->{client}) {
      return @conn{@world{$id}}->{client};
   }
}

sub disconnect_world
{
   my $id = id(shift);

    if(defined @conn{$id}->{world}) {

       if(defined @world{@conn{$id}->{world}}) {
          delete @world{@conn{$id}->{world}};
       }

       # remove from listener / watched sockets
       $readable->remove(@conn{$id}->{world});
       @conn{$id}->{world}->close;
       @conn{$id}->{world} = undef;
   }
}

sub disconnect_client
{
   my $id = shift;

   if(defined @conn{$id} && defined @conn{$id}->{was_offline}) {
      delete @conn{$id}->{disconnected};
      delete @conn{$id}->{was_offline};
      return;
   }

   disconnect_world($id);

   if(defined @conn{$id}) {
      if(defined @conn{$id}->{client} && @conn{$id}->{client} ne undef) {
         $readable->remove(@conn{$id}->{client});
         @conn{$id}->{client}->close;
      }
      delete @conn{$id};
   }
}

sub disconnect_hb
{
    if($hb ne undef) {
       $readable->remove($hb);
       $hb->close;
       $hb = undef;

       for my $id (keys %conn) {
          disconnect_world($id);
          @conn{$id}->{reconnect} = 1;
          my $sock = @conn{$id}->{client};
          printf($sock "%s\n",@data{offline_notice});
       }
    }
    hb_open_connect();
}

sub disconnect_cleanup
{
   for my $id (keys %conn) {
      if(defined @conn{$id}->{disconnect}) {
         if(@conn{$id}->{disconnect} + 10 < time()) { # max amount of time
            disconnect_hb();
         }
      }
      if(user($id) eq "unconnected" && 
         @conn{$id}->{created} + 300 < time()) {
         disconnect_client(@conn{$id}->{client});
      }
   }
}


@data{hb_never} = 1;
@data{chksum} = get_checksums();
init_data();
@data{prev_mush_address} = @data{mush_address};
server_start();

sub main
{
   eval {
      hb_open_connect();

      disconnect_cleanup();

      handle_select();
   };

   if($@) {
      printf("ERROR: %s\n",@_);
   }
}

while(1) {
   main();
}
