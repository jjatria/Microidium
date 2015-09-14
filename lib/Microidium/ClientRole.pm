package Microidium::ClientRole;

use strictures;

# VERSION

use lib '..';
use 5.010;
use SDL::Constants map "SDLK_$_", qw( q UP LEFT RIGHT d n o l );
use List::Util qw( min max );
use Carp::Always;
use Microidium::Helpers 'dfile';
use PryoNet::Client;
use Acme::MITHALDU::XSGrabBag 'mix';
use Time::HiRes 'time';
use POSIX 'floor';
use IO::All -binary;
use SDL::RWOps;

use Moo::Role;

use experimental 'autoderef';

requires "update_game_state";

has sounds => (
    is      => 'lazy',
    builder => sub {
        my %sounds = map { $_ => SDL::Mixer::Samples::load_WAV( dfile "$_.wav" ) } qw( shot death );
        return \%sounds;
    }
);
has pryo => ( is => 'lazy', builder => 1 );
has console => ( is => 'ro', default => sub { [ time, qw( a b c ) ] } );
has last_network_state => ( is => 'rw' );
around update_game_state => \&client_update_game_state;
has last_player_hit => ( is => 'rw', default => sub { 0 } );
has in_network_game   => ( is => 'rw' );
has local_player_id   => ( is => 'rw' );
has network_player_id => ( is => 'rw' );
has team_colors =>
  ( is => 'ro', default => sub { { 1 => [ .9, .9, .9, 1 ], 2 => [ .9, .7, .2, 1 ], 3 => [ .2, .8, 1, 1 ] } } );
has music_is_playing  => ( is => 'rw' );
has tile_cache        => ( is => 'ro', default => sub { {} } );
has client_game_state => ( is => 'rw', lazy => 1, builder => 1 );
has client_game_state_history => ( is => 'rw', default => sub { [] } );

1;

sub _build_client_game_state {
    my ( $self ) = @_;
    my $game_state = $self->game_state;
    return {
        max_trail  => 45,
        trails     => {},
        explosions => [],
        camera     => $self->_build_camera,
        id         => $game_state->{id},
        tick       => $game_state->{tick} - 1,
    };
}

sub _build_pryo {
    my ( $self ) = @_;
    my $pryo = PryoNet::Client->new( client => shift );
    $pryo->add_listeners(
        connected    => sub { $self->in_network_game( 1 ) },
        disconnected => sub {
            $self->in_network_game( 0 );
            $self->network_player_id( 0 );
        },
        received => sub {
            my ( $connection, $frame ) = @_;
            $self->log( "got: " . ( ref $frame ? ( $frame->{tick} || "input" ) : $frame ) );
            if ( $frame->isa( "Microidium::Gamestate" ) ) {
                my $game_state = $self->game_state;
                return if $frame->{tick} < $game_state->{tick};
                $self->last_network_state( $frame );
            }
            elsif ( $frame->isa( "Microidium::GiveConnectionId" ) ) {
                $self->log( "got network id: $frame->{network_player_id}" );
                $self->network_player_id( $frame->{network_player_id} );
            }
            else {
                die "received unknown frame: " . ref $frame;
            }
            return;
        },
    );
    return $pryo;
}

sub _build_client_state { { fire => 0, thrust => 0, turn_left => 0, turn_right => 0 } }

sub client_update_game_state {
    my ( $orig, $self, @args ) = @_;
    $self->pryo->loop->loop_once( 0 );
    return $self->network_update_game_state( @args ) if $self->in_network_game;
    return $self->local_update_game_state( $orig, @args );
}

sub network_update_game_state {
    my ( $self, $new_game_state ) = @_;
    return if !$self->last_network_state;
    %{$new_game_state} = %{ $self->last_network_state };
    $self->last_network_state( undef );
    return;
}

sub local_update_game_state {
    my ( $self, $orig, $new_game_state, @args ) = @_;
    if ( !$self->local_player_id ) {
        $new_game_state->{players}{1} = { id => 1, actor => undef };
        $self->local_player_id( 1 );
    }
    return $self->$orig( $new_game_state, @args );
}

sub player_control {
    my ( $self, $actor ) = @_;
    my $state = $self->game_state;
    return $self->client_state if defined $state->{last_input} and $state->{tick} - $state->{last_input} <= 600;
    return $self->computer_ai( $actor, $state );
}

sub on_quit { shift->stop }

sub on_keydown {
    my ( $self, $event ) = @_;
    $self->game_state->{last_input} = $self->game_state->{tick};
    my $sym = $event->key_sym;
    $self->stop if $sym == SDLK_q;
    $self->client_state->{thrust}     = 1 if $sym == SDLK_UP;
    $self->client_state->{turn_left}  = 1 if $sym == SDLK_LEFT;
    $self->client_state->{turn_right} = 1 if $sym == SDLK_RIGHT;
    $self->client_state->{fire}       = 1 if $sym == SDLK_d;
    $self->change_fov( $self->fov - 10 ) if $sym == SDLK_o;
    $self->change_fov( $self->fov + 10 ) if $sym == SDLK_l;

    if ( $self->in_network_game ) {
        $self->log( "sent: DOWN $sym" );
        $self->pryo->send_tcp( bless $self->client_state, "Microidium::Clientstate" );
    }
    return;
}

sub on_keyup {
    my ( $self, $event ) = @_;
    my $sym = $event->key_sym;
    $self->client_state->{thrust}     = 0 if $sym == SDLK_UP;
    $self->client_state->{turn_left}  = 0 if $sym == SDLK_LEFT;
    $self->client_state->{turn_right} = 0 if $sym == SDLK_RIGHT;
    $self->client_state->{fire}       = 0 if $sym == SDLK_d;
    $self->connect if $sym == SDLK_n;
    if ( $self->in_network_game ) {
        $self->log( "sent: UP $sym" );
        $self->pryo->send_tcp( $self->client_state );
    }
    return;
}

sub connect {
    my ( $self ) = @_;
    return if $self->in_network_game;
    $self->pryo->connect( 5, "127.0.0.1", 19366, 19366 );
    return;
}

sub update_client_game_state {
    my ( $self, $game_state, $new_client_game_state ) = @_;

    $self->update_camera( $game_state, $new_client_game_state );
    $self->update_trails( $game_state, $new_client_game_state );
    $self->update_explosions( $game_state, $new_client_game_state );
    $new_client_game_state->{tick} = $game_state->{tick};

    return;
}

sub update_trails {
    my ( $self, $game_state, $new_client_game_state ) = @_;

    my $max_trail = $new_client_game_state->{max_trail};
    my $trails    = $new_client_game_state->{trails};
    my $trail_inc = 1 / $max_trail;

    my $bright = $trail_inc;
    my $dark   = $trail_inc * 0.3;

    my %actors = %{ $game_state->{actors} };
    my $c      = $self->team_colors;
    my $tick   = $game_state->{tick};

    for my $flier ( values %actors ) {
        next if $flier->{is_bullet};

        my $trail = $trails->{ $flier->{id} } ||= { team => $flier->{team}, id => $flier->{id} };
        my ( $x, $y, $brightness ) =
          ( map( $_ - 2.5 + rand 5, $flier->{x}, $flier->{y} ), $flier->{is_thrusting} ? $bright : $dark );
        $brightness *= 0.2 if $y < $game_state->{floor} or $y > $game_state->{ceiling};
        my @color = map { $_ * 1.5 } @{ $c->{ $flier->{team} } }[ 0 .. 2 ];
        my @sprite_data = ( blob => [ $x, $y, 0 => @color, 0 => 0, 0.5, 0 ] );
        push @{ $trail->{segments} }, { brightness => $brightness, created => $tick, sprite => \@sprite_data };
        shift @{ $trail->{segments} } while @{ $trail->{segments} } > $max_trail;
    }

    for my $trail ( values %{$trails} ) {
        next if $actors{ $trail->{id} };

        shift @{ $trail->{segments} };
        next if @{ $trail->{segments} };

        delete $trails->{ $trail->{id} };
    }

    return;
}

sub update_explosions {
    my ( $self, $game_state, $new_client_game_state ) = @_;

    my $explosions = $new_client_game_state->{explosions};

    @{$explosions} = grep $_->{life} > 0, @{$explosions};

    for my $event ( @{ $game_state->{events} } ) {
        next if $event->{type} ne "flier_died";
        my $scale = $event->{is_bullet} ? 0.3 : 1;
        my $life  = $event->{is_bullet} ? 1   : 1.5;
        push @{$explosions},
          { x => $event->{x}, y => $event->{y}, life => $life, scale => $scale, team => $event->{team} };
    }

    $_->{life} -= 0.1 for @{$explosions};

    return;
}

sub render_world {
    my ( $self, $game_state, $client_game_state ) = @_;

    if ( !$self->music_is_playing ) {
        my $data  = io( dfile 'vecinec22.ogg' )->all;
        my $music = SDL::Mixer::Music::load_MUS_RW( SDL::RWOps->new_const_mem( $data ) );
        SDL::Mixer::Music::volume_music( 30 );
        die "music playback error" if SDL::Mixer::Music::play_music( $music, -1 ) == -1;
        $self->music_is_playing( 1 );
    }

    my $cam_pos = $client_game_state->{camera}{pos};

    my $STAR_SEED    = 0x9d2c5680;
    my $tile_size    = 512;
    my $max_bg_depth = 2;            # this relates to $screen_bg_mult, but i'm not sure how

    my $w = $self->display_scale * $self->aspect_ratio;
    my $h = $self->display_scale;
    my $c = $self->team_colors;

    my %actors = %{ $game_state->{actors} };

    $self->with_sprite_setup(
        sub {
            my $screen_bottom = $cam_pos->{y} - $h;
            my $screen_left   = $cam_pos->{x} - $w;
            my $screen_top    = $cam_pos->{y} + $h;
            my $screen_right  = $cam_pos->{x} + $w;

            my @markers = ( 1, 1, 1, 999999 => 0, 0.2, 0 );
            my @sprites = (
                [ bullet => [ 0,             0,              0 => @markers ] ],
                [ bullet => [ $screen_left,  $screen_bottom, 0 => @markers ] ],
                [ bullet => [ $screen_left,  $screen_top,    0 => @markers ] ],
                [ bullet => [ $screen_right, $screen_bottom, 0 => @markers ] ],
                [ bullet => [ $screen_right, $screen_top,    0 => @markers ] ],
            );

            my $screen_bg_mult = 2.9;    # this relates to $max_bg_depth and fov, but i'm not sure how
            my $screen_bottom_bg = $cam_pos->{y} - $h * $screen_bg_mult;
            my $screen_left_bg   = $cam_pos->{x} - $w * $screen_bg_mult;
            my $screen_top_bg    = $cam_pos->{y} + $h * $screen_bg_mult;
            my $screen_right_bg  = $cam_pos->{x} + $w * $screen_bg_mult;

            my $sprite_target_radius = 600;
            my $sprite_mult          = 2 * 2 * $sprite_target_radius / $self->sprite_size;
            my $camera_tile_y        = floor( $cam_pos->{y} / $tile_size );
            my $camera_tile_x        = floor( $cam_pos->{x} / $tile_size );

            my $bottom_start = $camera_tile_y * $tile_size;
            my $bottom_diff  = $bottom_start + $tile_size + $sprite_target_radius - $screen_bottom_bg;
            $bottom_start -= int( $bottom_diff / $tile_size ) * $tile_size;

            my $top_end = $camera_tile_y * $tile_size;
            my $top_diff = $screen_top_bg - ( $top_end - $sprite_target_radius );
            $top_end += int( $top_diff / $tile_size ) * $tile_size;

            my $left_start = $camera_tile_x * $tile_size;
            my $left_diff  = $left_start + $tile_size + $sprite_target_radius - $screen_left_bg;
            $left_start -= int( $left_diff / $tile_size ) * $tile_size;

            my $right_end = $camera_tile_x * $tile_size;
            my $right_diff = $screen_right_bg - ( $right_end - $sprite_target_radius );
            $right_end += int( $right_diff / $tile_size ) * $tile_size;

            my $tile_cache = $self->tile_cache;

            for my $y_tile ( ( $bottom_start / $tile_size ) .. ( $top_end / $tile_size ) ) {
                for my $x_tile ( ( $left_start / $tile_size ) .. ( $right_end / $tile_size ) ) {
                    push @sprites,
                      @{
                        $tile_cache->{"$y_tile:$x_tile"} ||=
                          $self->generate_background_tile( $y_tile, $x_tile, $tile_size, $STAR_SEED, $max_bg_depth,
                            $game_state, $c, $sprite_mult )
                      };
                }
            }

            @sprites = sort { $b->[1][2] <=> $a->[1][2] } @sprites;

            for my $flier ( values %actors ) {
                my @color =
                    ( $flier->{is_bullet} and $flier->{created} + 4 >= $game_state->{tick} )
                  ? ( 0, 0, 0, 1 )
                  : @{ $c->{ $flier->{team} } };
                if ( $flier->{y} < $game_state->{floor} or $flier->{y} > $game_state->{ceiling} ) {
                    $color[$_] *= 0.5 for 0 .. 2;
                }
                push @sprites, [
                    ( $flier->{is_bullet} ? "bullet" : "player1" ),
                    [
                        $flier->{x}, $flier->{y}, 0,    #
                        @color,
                        ( $flier->{is_bullet} ? ( 0, .3 ) : ( $flier->{rot}, 1.5 ) ),
                        0,
                    ],
                ];

                if ( !$flier->{is_bullet} ) {
                    my @wing_color = @{ $c->{ $flier->{team} } };
                    if ( $flier->{y} < $game_state->{floor} or $flier->{y} > $game_state->{ceiling} ) {
                        $wing_color[$_] *= 0.5 for 0 .. 2;
                    }
                    push @sprites,
                      [ player1_wings => [ $flier->{x}, $flier->{y}, 0 => @wing_color => $flier->{rot}, 1.5, 1 ] ];

                    my @color = @{ $c->{ $flier->{team} } };
                    $color[3] *= 0.2 if $flier->{y} < $game_state->{floor} or $flier->{y} > $game_state->{ceiling};
                    my %flames = qw(
                      is_thrusting     thrust_flame
                      is_turning_right thrust_right_flame
                      is_turning_left  thrust_left_flame
                    );
                    push @sprites, [ $flames{$_} => [ $flier->{x}, $flier->{y}, 0 => @color => $flier->{rot}, 1.5, 1 ] ]
                      for grep { $flier->{$_} } keys %flames;
                }
            }

            my $current_tick = $game_state->{tick};
            my $age_offset   = 1 + $client_game_state->{max_trail} - $current_tick;
            for my $trail ( values %{ $client_game_state->{trails} } ) {
                my $segments = $trail->{segments};
                $_->{sprite}[1][6] = $_->{brightness} * ( $age_offset + $_->{created} ) for @{$segments};
                push @sprites, map $_->{sprite}, @{$segments}[ 0 .. $#{$segments} - 2 ];
            }

            for my $ex ( @{ $client_game_state->{explosions} } ) {
                my @color = ( @{ $c->{ $ex->{team} } }[ 0 .. 2 ], 0.8 * $ex->{life} );
                my $scale = $ex->{scale} * $ex->{life};
                push @sprites, [ bullet => [ $ex->{x}, $ex->{y}, 0 => @color => 0, $scale, 0 ] ];
            }

            push $self->timestamps, [ sprite_prepare_end => time ];
            $self->send_sprite_datas( @sprites );
            push $self->timestamps, [ sprite_send_end => time ];
        }
    );
    push $self->timestamps, [ sprite_render_end => time ];

    my $player_actor = $self->local_player_actor;
    my $audio_pickup = $player_actor ? $player_actor : $cam_pos;

    my @new_bullets = grep $_->{is_bullet}, map $actors{$_}, @{ $game_state->{new_actors} };
    $self->play_sound( "shot", $_, $audio_pickup, 3 ) for @new_bullets;

    my @dead_planes = grep !$_->{is_bullet}, @{ $game_state->{removed_actors} };
    $self->play_sound( "death", $_, $audio_pickup, 3 ) for @dead_planes;

    return;
}

sub generate_background_tile {
    my ( $self, $y_tile, $x_tile, $tile_size, $STAR_SEED, $max_bg_depth, $game_state, $c, $sprite_mult ) = @_;

    my @sprites;

    my $j    = $y_tile * $tile_size;
    my $i    = $x_tile * $tile_size;
    my $hash = mix( $STAR_SEED, $i, $j );
    for ( 1 .. 1 ) {
        my $px = $i + ( $hash % $tile_size );
        $hash >>= 3;
        my $py = $j + ( $hash % $tile_size );
        $hash >>= 3;
        my $pz = "0.$hash" * $max_bg_depth;
        $hash >>= 3;
        my $color =
          $py > $game_state->{ceiling} ? $c->{2} : $py < $game_state->{floor} ? $c->{3} : $c->{1};
        push @sprites, [ blob => [ $px, $py, $pz => @{$color} => 0, $sprite_mult, 0 ] ];
    }

    return \@sprites;
}

sub play_sound {
    my ( $self, $sound_id, $flier, $position, $falloff ) = @_;

    my $x_diff = $flier->{x} - $position->{x};
    my $distance = sqrt( ( $x_diff )**2 + ( $flier->{y} - $position->{y} )**2 );
    $distance /= $falloff;
    return if $distance > 255;

    my $angle = $x_diff / $falloff;
    $angle = $angle >= 0 ? ( min $angle, 90 ) : ( 360 + max $angle, -90 );

    my $channel = SDL::Mixer::Channels::play_channel( -1, $self->sounds->{$sound_id}, 0 );
    SDL::Mixer::Channels::volume( $channel, 30 );
    SDL::Mixer::Effects::set_position( $channel, $angle, $distance );
    return;
}

sub render_ui {
    my ( $self, $game_state, $client_game_state ) = @_;
    my $player_actor = $self->local_player_actor;
    my @texts;

    my $cam_pos     = $client_game_state->{camera}{pos};
    my $half_height = $self->height / 2;
    my $half_width  = $self->width / 2;
    my %names       = ( 1 => "Mithaldu", 2 => "burnersk" );

    for my $flier ( grep { !$_->{is_bullet} and $_->{team} == 1 } values %{ $game_state->{actors} } ) {
        my ( $x, $y ) = map { $flier->{$_} - $cam_pos->{$_} } qw( x y );
        $y = $half_height + $half_height * $y / $self->display_scale;
        $x = $half_width + $half_width * $x / $self->display_scale / $self->aspect_ratio;
        my $name = $flier->{player_name};
        push @texts, [ [ $x, $y ], $names{$name} || $name ];
    }

    push @texts,
      [ [ 0, $self->height - 12 ], "Controls: left up right d - Quit: q - Connect to server: n - Zoom in/out: o l" ];

    push @texts, [ [ 0, 90 ], "Perl v$]" ];

    push @texts,
      [
        [ 0, 80 ],
        sprintf "Viewport: %d x %d = %.2f MPix",
        $self->width, $self->height, $self->width * $self->height / 1_000_000
      ];

    push @texts,
      [
        [ 0, 70 ],
        sprintf "Render: %d x %d = %.2f MPix",
        $self->aspect_ratio * $self->fb_height,
        $self->fb_height, $self->aspect_ratio * $self->fb_height * $self->fb_height / 1_000_000
      ];

    push @texts, [ [ 0, 60 ], sprintf "Sprites: %d", $self->sprite_count ];

    push @texts,
      [
        [ 0, 50 ],
        sprintf( "Audio channels:|%s|", join "", map { SDL::Mixer::Channels::playing( $_ ) ? 'x' : ' ' } 0 .. 31 )
      ];
    if ( $player_actor ) {
        push @texts,    #
          [ [ 0, 40 ], "HP: $player_actor->{hp}" ],
          [
            [ 0, 30 ],
            sprintf(
                "X: % 8.2f / Y: % 8.2f / R: % 8.2f / Speed: % 8.2f",
                ( map $player_actor->{$_}, qw( x y rot ) ),
                sqrt( $player_actor->{x_speed}**2 + $player_actor->{y_speed}**2 )
            ),
            "no_cache",
          ];
    }
    push @texts,
      [ [ 0, 20 ], sprintf "FPS: %5.1f // Load: % 7.2f %%", 1 / $self->frame_time, 100 * $self->frame_calc_time * $self->fps_aim ];
    my $tick = $game_state->{tick} || 0;
    push @texts, [
        [ 0, 10 ],
        sprintf( "Frame: %d / Tick: %d / Dropped: %d", $self->frame, $tick, $tick - $self->frame ),    #
        "no_cache",
    ];

    my $con = $self->console;
    my @to_display = grep defined, @{$con}[ max( 0, $#$con - 10 ) .. $#$con ];
    push @texts, [ [ 0, $self->height - 22 - $_ * 10 ], $to_display[$_] ] for 0 .. $#to_display;

    my %timing_types  = %{ $self->timing_types };
    my @timing_colors = $self->timing_colors;
    my $y             = 0;
    my $x             = 70 + $self->width / 2;
    my @used          = grep $self->used_timing_types->{$_}, keys %timing_types;

    for my $timing ( sort { $timing_types{$a} <=> $timing_types{$b} } @used ) {
        push @texts, [ [ $x, $y, undef, $timing_colors[ $timing_types{$timing} ] ], $timing ];
        $y += 12;
    }

    $self->print_text_2D( @texts );

    return;
}

# see bin/generate_colors
sub timing_colors {
    (
        [ 1.0,               0.0,               0.0,               0.85 ],
        [ 0.690196078431373, 1.0,               0.43921568627451,  0.85 ],
        [ 0.650980392156863, 0.0,               1.0,               0.85 ],
        [ 1.0,               0.219607843137255, 0.219607843137255, 0.85 ],
        [ 0.0,               1.0,               0.584313725490196, 0.85 ],
        [ 0.803921568627451, 0.43921568627451,  1.0,               0.85 ],
        [ 1.0,               0.43921568627451,  0.43921568627451,  0.85 ],
        [ 0.43921568627451,  1.0,               0.764705882352941, 0.85 ],
        [ 1.0,               0.0,               0.831372549019608, 0.85 ],
        [ 1.0,               0.517647058823529, 0.0,               0.85 ],
        [ 0.0,               0.901960784313726, 1.0,               0.85 ],
        [ 1.0,               0.43921568627451,  0.905882352941176, 0.85 ],
        [ 1.0,               0.729411764705882, 0.43921568627451,  0.85 ],
        [ 0.0,               0.384313725490196, 1.0,               0.85 ],
        [ 1.0,               0.0,               0.317647058823529, 0.85 ],
        [ 0.964705882352941, 1.0,               0.0,               0.85 ],
        [ 0.219607843137255, 0.517647058823529, 1.0,               0.85 ],
        [ 1.0,               0.219607843137255, 0.466666666666667, 0.85 ],
        [ 0.980392156862745, 1.0,               0.43921568627451,  0.85 ],
        [ 0.43921568627451,  0.654901960784314, 1.0,               0.85 ],
        [ 1.0,               0.43921568627451,  0.615686274509804, 0.85 ],
        [ 0.450980392156863, 1.0,               0.0,               0.85 ],
        [ 0.133333333333333, 0.0,               1.0,               0.85 ],
    );
}

sub player_id {
    my ( $self ) = @_;
    return $self->in_network_game ? $self->network_player_id : $self->local_player_id;
}

sub local_player {
    my ( $self ) = @_;
    my $player_id = $self->player_id;
    return $player_id ? $self->game_state->{players}{$player_id} : undef;
}

sub local_player_actor {
    my ( $self ) = @_;
    my $player = $self->local_player;
    return $player && $player->{actor} ? $self->game_state->{actors}{ $player->{actor} } : undef;
}

sub log { push @{ shift->console }, @_ }
