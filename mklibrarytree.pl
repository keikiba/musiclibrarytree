#!/usr/bin/perl

# This script parses Music Player Daemon's music database, and then build
# a structure for music collection.

use utf8;
# use encoding "utf8";
# binmode STDOUT, ":encoding(utf8)";
# binmode STDERR, ":encoding(utf8)";
# binmode STDIN, ":encoding(utf8)";
use strict;
use English;
use File::chdir;
use File::Path;
use File::MMagic;
use File::Basename;
use POSIX qw(strftime);
use DFA::Command;
use Log::Dispatch;
# use Encode 'decode';
# use Encode 'encode';

my $DEBUG = 0;
my $dbFile = "/var/lib/mpd/tag_cache";
my $logFile = "/data/music/Resources/log/mklibrarytree.log";
my $stateFile = "/data/music/Resources/script/mpd-dbparser.stt";
my $targetDir = "/data/music/Collections";
my $genreRootDir = "Genre";
my $allRootDir = "All";
my $sourceDir = "/data/music/iTunes/iTunes Library";
my $genreImgDir = "/data/music/Resources/Images";
my $thumbnail = "folder.jpg";

my $tStampFile = ".updated";
my $firstEvent = "infoEvent";
my $dfa = 0;

my %albums;
my $cArtist;
my $cAlbum;
my @dirs;
my %dirInfo;

my $cDiscInfo;
my $nDiscs;
my @discInfo;

my $inSongList;
my $cSongInfo;
my $nSongs;
my @songInfo;

my $log;

##
## Write log message.
##
# sub writelog {
#   my ($msg) = @_;

#   return if !$DEBUG;
#   print strftime("%b %2e %H:%M:%S ", localtime) . $msg . "\n";
# }

##
## initialize
##
sub initialize {
  # Initialize logger
  $log = Log::Dispatch->new(
    # debug
    # info
    # notice
    # warning
    # error
    # critical
    # alert
    # emergency
    outputs => [
      [ 'File',
	min_level => $DEBUG ? 'debug' : 'info',
	filename => $logFile,
	newline   => 1,
      ],
      [ 'Screen', 
	min_level => 'notice',
	stderr    => 1,
	newline   => 1,
      ],
    ],
    callbacks => sub {
      my %args = @_;
      return strftime("%Y/%m/%d %H:%M:%S ", localtime) . 
	"[" . $args{level} . "] " . 
	$args{message};
    },
    );

  # Reset counters.
  %albums = ();
  $cArtist = '';
  $cAlbum = '';
  %dirInfo = ();

  undef($cDiscInfo);
  $nDiscs = 0;
  @discInfo = ();

  $inSongList = 0;
  undef($cSongInfo);
  $nSongs = 0;
  @songInfo = ();

  clearDir();
  $log->info($0 . ' started');
}

sub finalize {
  $log->info($0 . ' finished');
}

##
## Event handlers
##
sub infoHandler {
  $log->debug('parse: info_begin: start');
}

sub formatHandler {
  $log->debug('parse: format: ' . $dfa->{'$1'});
}

sub mpdVerHandler {
  $log->debug('parse: mpd_version: ' . $dfa->{'$1'});
}

sub fsCharsetHandler {
  $log->debug('parse: fs_charset: ' . $dfa->{'$1'});
}

sub tagHandler {
  $log->debug('parse: tag: ' . $dfa->{'$1'});
}

sub endInfoHandler {
  $log->debug('parse: info_end: end');
}

sub directoryHandler {
  if ($dfa->{'$1'} =~ /^$/) { return; }
  setDir($dfa->{'$1'});
  $log->debug('parse: directory: ' . $dfa->{'$1'});
}

sub mtimeHandler {
  if ($dfa->{'$1'} =~ /^$/) { return; }
  $log->debug('parse: mtime: ' . $dfa->{'$1'});
}

sub beginHandler {
  if ($cArtist =~ /^$/) {
    # Beginning of Artist
    $cArtist = $dfa->{'$1'};
    $log->debug('parse: begin artist: "' . $dfa->{'$1'} . '"');
  } else {
    # Beginning of Album
    if ($cAlbum =~ /^$/ && $dfa->{'$1'} =~ /(.*)\/(.*)/) {
      my $art = $1;
      my $alb = $2;
      if ($art =~ /$cArtist/) {
	$cAlbum = $alb;
	$cDiscInfo = initDiscInfo();
	$cDiscInfo->{artist} = $cArtist;
	$cDiscInfo->{album} = $cAlbum;
	$cDiscInfo->{directory} = getDirPath();
	$log->info('parse: album: "' . $dfa->{'$1'} . '"');

      } else {
	$log->error('parse: unexpected token: "begin: ' . $dfa->{'$1'} . '"');
      }

    } else {
      $log->error('parse: unexpected token: "begin: ' . $dfa->{'$1'} . '"');
    }
  }
}

sub endHandler {
  if ($dfa->{'$1'} =~ /^$/) { return; }
  if ($dfa->{'$1'} =~ /(.*)\/(.*)/) {
    # End of album
    my $art = $1;
    my $alb = $2;
    if ($art =~ /\Q$cArtist\E/ && $alb =~ /\Q$cAlbum\E/) {
      # End of album

      # Save current disc information
      saveDiscInfo($cDiscInfo);
      $cDiscInfo = clearDiscInfo();
      $cAlbum = '';
      unsetDir();
      $log->debug('parse: end album: "' . $dfa->{'$1'} . '"');

    } else {
      $log->error('parse: unexpected token: "end: ' . $dfa->{'$1'} . '"');
      $log->error('parse: cArtist="' . $cArtist . '" \$1="' . $art . '"');
      $log->error('parse: cAlbum="' . $cAlbum . '" \$2="' . $alb . '"');
    }

  } elsif ($dfa->{'$1'} =~ /$cArtist/) {
    # End of artist
    $cArtist = '';
    clearDir();
    $log->debug('parse: end artist: "' . $dfa->{'$1'} . '"');

  } else {
    $log->error('parse: unexpected token: "end: ' . $dfa->{'$1'} . '"');
    $log->error('parse: current artist="' . $cArtist . '"');
  }

}

sub bSongHandler {
  if (!$inSongList) {
    $inSongList = 1;
    $log->debug('parse: song: start: "' . $dfa->{'$1'} . '"');

    if (exists $cSongInfo->{key}) {
      # Save the previous record.
      addSongInfoToDiscInfo($cSongInfo);
      $cSongInfo = clearSongInfo();
    }
    $cSongInfo = initSongInfo();
    $cSongInfo->{key} = $dfa->{'$1'};

  } else {
    $log->error('parse: unexpected token in song list: "song_begin: ' . $dfa->{'$1'} . '"');
  }
}

sub eSongHandler {
  if ($inSongList) {
    $inSongList = 0;

    # save cSongInfo
    if (exists $cSongInfo->{key}) {
      # Save the previous record.
      addSongInfoToDiscInfo($cSongInfo);
      $cSongInfo = clearSongInfo();
    }
    $log->debug('parse: song: end');

  } else {
    $log->error('parse: unexpected token in song list: "song_end"');
  }
}

sub songTimeHandler {
  if ($inSongList) {
    $cSongInfo->{time} = $dfa->{'$1'};
    $log->debug('parse: song: Time: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "Time: ' . $dfa->{'$1'} . '"');
  }
}

sub songTitleHandler {
  if ($inSongList) {
    $cSongInfo->{title} = $dfa->{'$1'};
    $log->debug('parse: song: Title: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "Title: ' . $dfa->{'$1'} . '"');
  }
}

sub songArtistHandler {
  if ($inSongList) {
    $cSongInfo->{artist} = $dfa->{'$1'};
    $log->debug('parse: song: Artist: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "Artist: ' . $dfa->{'$1'} . '"');
  }
}

sub songDateHandler {
  if ($inSongList) {
    $cSongInfo->{date} = $dfa->{'$1'};
    $log->debug('parse: song: Date: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "Date: ' . $dfa->{'$1'} . '"');
  }
}

sub songAlbumHandler {
  if ($inSongList) {
    $cSongInfo->{album} = $dfa->{'$1'};
    $log->debug('parse: song: Album: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "Album: ' . $dfa->{'$1'} . '"');
  }
}

sub songGenreHandler {
  if ($inSongList) {
    $cSongInfo->{genre} = $dfa->{'$1'};
    $log->debug('parse: song: Genre: "' . $dfa->{'$1'} . '"');
    setGenreDiscInfo($dfa->{'$1'}, $cDiscInfo);
  } else {
    $log->error('parse: unexpected token in song list: "Genre: ' . $dfa->{'$1'} . '"');
  }
}

sub songTrackHandler {
  if ($inSongList) {
    $cSongInfo->{track} = $dfa->{'$1'};
    $log->debug('parse: song: Track: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "Track: ' . $dfa->{'$1'} . '"');
  }
}

sub songComposerHandler {
  if ($inSongList) {
    $cSongInfo->{composer} = $dfa->{'$1'};
    $log->debug('parse: song: Composer: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "Composer: ' . $dfa->{'$1'} . '"');
  }
}

sub songDiscHandler {
  if ($inSongList) {
    $cSongInfo->{Disc} = $dfa->{'$1'};
    $log->debug('parse: song: Disc: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "Disc: ' . $dfa->{'$1'} . '"');
  }
}

sub songMtimeHandler {
  if ($inSongList) {
    $cSongInfo->{mtime} = $dfa->{'$1'};
    $log->debug('parse: song: mtime: "' . $dfa->{'$1'} . '"');
  } else {
    $log->error('parse: unexpected token in song list: "mtime: ' . $dfa->{'$1'} . '"');
  }
}

##
## cDiscInfo routines
sub initDiscInfo {
  my $idx = $nDiscs++;
  $discInfo[$idx] = ();
  return \%{$discInfo[$idx]};
}

sub clearDiscInfo {
  undef($cDiscInfo);
  return $cDiscInfo;
}

sub saveDiscInfo {
  # Save the current disc information.
  $albums{$cDiscInfo->{genre}} = () if (!exists $albums{$cDiscInfo->{genre}});
  push(@{$albums{$cDiscInfo->{genre}}}, $cDiscInfo);
}

sub setGenreDiscInfo {
  my ($genre, $cdi) = @_;
  if (!exists $cdi->{genre} || $cdi->{genre} =~ /^$/) {
    $cdi->{genre} = $genre;
  }
}

sub addSongInfoToDiscInfo {
  my ($csi) = @_;
  push(@{$cDiscInfo->{songs}}, $csi);
}

##
## cSongInfo routines
sub initSongInfo {
  my $idx = $nSongs++;
  $songInfo[$idx] = ();
  return \%{$songInfo[$idx]};
}

sub clearSongInfo {
  undef($cSongInfo);
  return $cSongInfo;
}

##
## dirs routine
##
sub setDir {
  my ($d) = @_;
  push(@dirs, $d);
}

sub unsetDir {
  pop(@dirs);
}

sub clearDir {
  @dirs = ();
}

sub getDirPath {
  return $dirs[-2] . "/" . $dirs[-1];
}

##
## dump
sub dumpSongsInfo {
  # Dump array of song info

  foreach my $si (@_) {
    $log->debug('hdump:  key     : "' . $si->{key} . '"');
    $log->debug('hdump:    file  : "' . $si->{key} . '"');
    $log->debug('hdump:    Time  : "' . $si->{time} . '"');
    $log->debug('hdump:    Artist: "' . $si->{artist} . '"');
    $log->debug('hdump:    Title : "' . $si->{title} . '"');
    $log->debug('hdump:    Album : "' . $si->{album} . '"');
    $log->debug('hdump:    Track : "' . $si->{track} . '"');
    $log->debug('hdump:    Genre : "' . $si->{genre} . '"');
    $log->debug('hdump:    Date  : "' . $si->{date} . '"');
    $log->debug('hdump:    mtime : "' . $si->{mtime} . '"');
  }
}

sub dumpDiscInfo {
  my ($di) = @_;
  $log->debug('hdump: Artist : "' . $di->{artist} . '"');
  $log->debug('hdump: Album  : "' . $di->{album} . '"');
  $log->debug('hdump: Genre  : "' . $di->{genre} . '"');
  $log->debug('hdump: Dir    : "' . $di->{directory} . '"');
  $log->debug('hdump: Songs');
  dumpSongsInfo(@{$di->{songs}});
}

sub dumpAllAlbumsInfo {
  foreach my $genre (keys %albums) {
    $log->debug('hdump: Genre="' . $genre . '"');
    foreach my $di (@{$albums{$genre}}) {
      dumpDiscInfo($di);
    }
  }
}

##
## Directory routines
##
my @wd = ();
sub changeWorkingDirectory {
  my ($d) = @_;
  push(@wd, $CWD);
  $CWD = $d;
  #$log->debug('dir : cwd="' . $CWD . '"');
}
sub backWorkingDirectory {
  $CWD = pop(@wd);
  #$log->debug('dir : cwd="' . $CWD . '"');
}

sub createDir {
  my ($d) = @_;
  my $dir = $d;
  if (!-d $dir) {
    #mkdir($dir);
    mkpath($dir);
    $log->debug('mkdir: mkpath: "' . $dir . '"');
  } else {
    $log->debug('mkdir: found: "' . $dir . '"');
  }
}

sub prepareGenreDir {
  my ($d) = @_;

  my @dirs = ();
  my $dir = "";
  foreach my $_d (split(/\//, $d)) {
    $dir .= (length($dir) > 0 ? '/' : '') . $_d;
    push(@dirs, $dir);
  }
  $dir = "";

  foreach my $genreDir (@dirs) {
    if (!-d $genreDir) {
      mkpath($genreDir);
      $log->debug('mkdir: mkpath: "' . $genreDir . '"');
    } else {
      $log->debug('mkdir: found: "' . $genreDir . '" (unchanged)');
    }
    # Build link to a genre thumbnail image.
    createSymlink($genreImgDir . '/' . $genreDir . '.jpg', $genreDir . '/' . $thumbnail);
  }

}

sub createSymlink {
  my ($of, $nf) = @_;
  unless (-e $of) {
    $log->warn('slink: cannot crate symlink : no source file: "' . $of . '"');
  }
  if (-l $nf) {
    my $f = readlink($nf);
    if ($f eq $of) {
      $log->debug('slink: found: "' . $nf . '" (unchanged)');
    } else {
      $log->debug('slink: found but different: "' . $nf . '" (changed)');
      unlink($nf);
      symlink($of, $nf);
      $log->debug('slink: "' . $nf . '"');
    }
  } else {
    symlink($of, $nf);
    $log->debug('slink: "' . $nf . '"');
  }
}

sub createTimeStamp {
  ;
}

sub clearTarget {
  changeWorkingDirectory($targetDir);
  system("rm -rf *");
  $log->debug('build: target directory cleared: "' . $targetDir . '"');
  backWorkingDirectory();
}

sub buildTarget {
  $log->info('build: source="' . $sourceDir . '"');
  $log->info('build: target="' . $targetDir . '"');

  changeWorkingDirectory($targetDir);
  clearTarget();

  # Create Genre/
  $log->info('build: generating genres under "' . $genreRootDir . '/" ...');
  createDir($genreRootDir);
  changeWorkingDirectory($genreRootDir);

  my $num = 0;
  foreach my $genre (keys %albums) {
    prepareGenreDir($genre);
    changeWorkingDirectory($genre);
    $num++;

    foreach my $di (@{$albums{$genre}}) {
      my $album ;

      unless ($di->{artist} =~ /^Compilations$/) {
	$album = $di->{artist} . ' - ';
      }
      $album .= $di->{album};

      createDir($album);
      changeWorkingDirectory($album);

      # Build symlinks to song files.
      foreach my $si (@{$di->{songs}}) {
	my $of = $sourceDir . '/' . $di->{directory} . '/' . $si->{key};
	createSymlink($of, $si->{key});
      }

      # Build link to a thumbnail image.
      createSymlink($sourceDir . '/' . $di->{directory} . '/' . $thumbnail, $thumbnail);

      # Finished.
      backWorkingDirectory();
    }
    $log->info('build: generated "' . $genreRootDir . '/' . $genre . '"');
    backWorkingDirectory();
  }
  $log->info('build: ' . $num  . ' categories generated in "' . $genreRootDir . '"');
  backWorkingDirectory();

  # Create All/
  $log->info('build: generating artist/album info under "' . $allRootDir . '/" ...');
  createDir($allRootDir);
  changeWorkingDirectory($allRootDir);

  my $num = 0;
  foreach my $genre (keys %albums) {
    foreach my $di (@{$albums{$genre}}) {
      my $cDir = '';

      createDir($di->{artist});
      changeWorkingDirectory($di->{artist});
      createDir($di->{album});
      changeWorkingDirectory($di->{album});
      $num++;

      # Build symlinks to song files.
      $cDir = $sourceDir . '/' . $di->{directory} . '/';
      foreach my $si (@{$di->{songs}}) {
	createSymlink($cDir . $si->{key}, $si->{key});
      }
      # Build link to a thumbnail image.
      createSymlink($cDir . $thumbnail, $thumbnail);

      # Finished.
      backWorkingDirectory(); # album
      backWorkingDirectory(); # artist
    }
  }
  backWorkingDirectory();
  $log->info('build: ' . $num  . ' discs generated in "' . $allRootDir . '"');
}

sub getMimeType {
  my ($tgtf) = @_;
  my $mm = new File::MMagic;
  my $f;
  my $nd;

  if (-l $tgtf) {
    # File is a symbolic link.
    $f = readlink($tgtf);

    # Complete if it is a relative path.
    $nd = dirname($f);
    if ($nd =~ /^\/.*$/) {
	; # an absolute path
    } else {
      $f = dirname($tgtf) . '/' . $nd . '/' . basename($f);
    }
    $log->info('parse: database is a symbolic link to "' . $f . '"');
  } else {
    $f = $tgtf;
  }
  return $mm->checktype_filename($f);
}

sub isGzippedDb {
  my ($dbf) = @_;
  my $mtype = getMimeType($dbf);
  my $ret = 0;

  if ($mtype =~ "application\/x-gzip") {
    # Databse is compressed by Gzip
    $log->debug('parse: database is compressed (' . $mtype . ')');
    $ret = 1;  
      
  } elsif ($mtype =~ "text\/plain") {
    # Plan text
    $log->debug('parse: database is not compressed (' . $mtype . ')');
  } else {
    # Unknown mime type
    $log->emergency('parse: database format is not supported (' . $mtype . ')');
    die;
  }
  return $ret;
}

##
## main routine
##
sub main {
  initialize();
  $dfa = new DFA::Command($firstEvent);
  $dfa->load($stateFile);
  $log->info('parse: start [database="' . $dbFile . '"]');

  if (isGzippedDb($dbFile)) {
    $dfa->process("zcat $dbFile |");
  } else {
    $dfa->process($dbFile);
  }
  $log->info('parse: finished');

  # Debug
  dumpAllAlbumsInfo() if $DEBUG;

  # Build directories.
  buildTarget();

  # Record time stamp.
  createTimeStamp();

  # Done
  finalize();
}

main;

# end of script
