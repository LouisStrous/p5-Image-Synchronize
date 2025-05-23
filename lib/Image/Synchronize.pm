package Image::Synchronize;

use Modern::Perl;

=head1 NAME

Image::Synchronize - a module for synchronizing filesystem
modification timestamps of images, movies, and related files.

=head1 SYNOPSIS

  use Image::Synchronize;

  $ims = Image::Synchronize->new(%options);
  $ims->process(@pathpatterns);

=head1 DESCRIPTION

This module is the backend of L<imsync> and was not designed to be
used outside of that context.

=head1 SEE ALSO

See the documentation of L<imsync> for more details.

=head1 AUTHOR

Louis Strous, E<lt>imsync@quae.nl<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2018-2025 by Louis Strous

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.26.2 or,
at your option, any later version of Perl 5 you may have available.

=cut

use parent 'Exporter';
our @EXPORT_OK = qw(normalize_options);

use feature 'state';

use Carp;
use Clone qw(clone);
use File::Copy qw(
  copy
  move
);
use File::Spec qw(
  case_tolerant
);
use Image::ExifTool 10.14;
use Image::Synchronize::CameraOffsets;
use Image::Synchronize::GpsPositionCollection;
use Image::Synchronize::GroupedInfo;
use Image::Synchronize::Logger qw(
  default_logger
  log_error
  log_message
  log_warn
);
use Image::Synchronize::ProgressBar;
use Path::Class qw(
  dir
  file
);
use Path::Iterator::Rule;
use POSIX qw(
  floor
);
use Scalar::Util qw(
  blessed
  looks_like_number
);
use Text::Glob qw(match_glob);
use XML::Twig;
use YAML::Any qw(
  Dump
  DumpFile
  LoadFile
);

BEGIN {
  if ($^O eq 'MSWin32'
      and (!$^V or $^V lt v5.33.5)
      and eval 'require Win32::UTCFileTime')
  {
    import Win32::UTCFileTime;
  }
}

# always use x.yyy version numbering, so that string comparison and
# numeric comparison give the same ordering, to avoid trouble due to
# different ways of interpreting version numbers.
our $VERSION = '2.013';

# TODO: check each folder for an .imsync-cameraoffsets.yaml file
# TODO: allow timezone specification on --time

my $CASE_TOLERANT;
my $PIRname; # for 'name' or 'iname' as appropriate for
             # case-sensitiveness of the operating system
my $PIRnotname;               # likewise for 'not_name' or 'not_iname'

# capture and log warnings and errors, so they end up in the log file
# as well as being printed to standard output
BEGIN {
  $SIG{__WARN__} = sub {
    log_warn( $_[0] );
  };
  $SIG{__DIE__} = sub {
    log_error( Carp::longmess( $_[0] ) ) unless $^S;
  };
  $CASE_TOLERANT = File::Spec->case_tolerant();
  $PIRname = $CASE_TOLERANT? 'iname': 'name';
  $PIRnotname = 'not_' . $PIRname;
}

my @gps_location_tags      = qw(GPSLatitude GPSLongitude GPSAltitude);
my %gps_location_tags      = map { $_ => 1 } @gps_location_tags;

# The ExiftimeVersion is here temporarily. It is associated with a
# predecessor of the current application that was not released to the
# general public but was extensively used by the author.  He wants to
# know if he's processing files using the current application that
# already contain tags embedded by the predecessor.
my @own_xmp_tags = qw(
  CameraID
  ImsyncVersion
  TimeSource
  ExiftimeVersion
);

my @all_tags;
{
  my %tags = map { $_ => 1 }
    (
     'CreateDate',
     'DateTimeOriginal',
     'Duration',
     'FileModifyDate',
     'GPSAltitude',
     'GPSAltitudeRef',
     'GPSDateTime',
     'GPSLatitude',
     'GPSLatitudeRef',
     'GPSLongitude',
     'GPSLongitudeRef',
     'ImageWidth',
     'Make',
     'MIMEType',
     'Model',
     'QuickTime:CreationDate',
     'QuickTime:AndroidManufacturer',
     'QuickTime:AndroidModel',
     'SerialNumber',
     map { "XMP:$_" } @own_xmp_tags,
   );
  @all_tags = sort keys %tags;
}

my %all_tags = map { $_ => 1 } @all_tags;

my %time_tags;

# non-UTC time tags
$time_tags{$_} = 1 foreach qw(FileModifyDate CreateDate DateTimeOriginal);

# UTC time tags
$time_tags{$_} = 0 foreach qw(GPSDateTime QuickTime:CreationDate);

=head1 METHODS

=head2 new

  $ims = Image::Synchronize->new(%options);

Construct and return a new instance of the class.  The following
C<%options> keys are recognized:

=over

=item logfile

Specifies the file to write the log messages to (in addition to
printing them to standard output).  If not set, then I<imsync.log>
in the current working directory is used.

=back

=cut

sub new {
  my ( $class, %options ) = @_;

  my $self = bless {
    backend     => Image::ExifTool->new,
    gps_offsets => Image::Synchronize::CameraOffsets->new(
      log_callback => sub { log_message( 16, @_ ) }
    ),
    gps_positions => Image::Synchronize::GpsPositionCollection->new,
    options       => \%options,
  }, $class;

  # write XMP tags without padding.
  $self->{backend}->Options( Compact => 1, );

  return $self;
}

=head2 process

  $ims->process(@arguments);

Processes the specified C<@arguments>, of which the elements are
interpreted as path name patterns matching files and/or directories.

Returns C<$ims>.

=cut

sub process {
  my ( $self, @arguments ) = @_;
  $self->set_working_directory->initialize_logging->report_program_and_options;

  my $done = 0;
  my $result;

  if ( $self->option('restoreoriginals') ) {
    $result = $self->restore_original_files(@arguments);
    $done   = 1;
  }

  if ( $self->option('removebackups') ) {
    $result = $self->delete_backups(@arguments);
    $done   = 1;
  }

  my @files;
  if ( not($done) or $self->option('removeourtags') ) {
    log_message("Seeking files.\n");
    @files = resolve_files( { recurse => $self->option('recurse') },
      Path::Iterator::Rule->new->$PIRnotname('*_original')->file, @arguments );
    log_message( 'Found ' . scalar(@files) . ' file(s).' . "\n" );

    $self->process_follow(@files)        # must happen before the first
                                         # file-specific message gets printed
      ->initialize_own_xmp_namespace;    # must happen before using any
                                         # Image::Exiftool functionality

    if ( $self->option('removeourtags') ) {
      $result = $self->remove_our_tags(@files);
      $done   = 1;
    }
  }

  if ( not $done ) {
    $self->inspect_files(@files);

    # must happen before determining new values

    $self->import_camera_offsets->process_user_camera_ids->process_user_times
      ->process_user_locations->process_summer_wintertime->read_gpx_tracks;

    $self->determine_new_values_for_all_files->modify_files->report->exportgpx(
      $self->option('exportgpx') );

    $self->export_camera_offsets if $self->option('modify');
  }

  log_message( "\nResults logged to file '"
      . file( $self->{logfile} )->absolute
      . "'.\n" );

  # clean up the logging to file
  default_logger()->clear_printer('file');
  close $self->{logfh};

  if ( ( $self->option('removebackups') and $self->option('clearlog') )
    or $self->option('unsafe') )
  {
    print "Removing logfile.\n";
    unlink( $self->{logfile} );
  }

  return 0;
}

# below here, specify subs in alphabetical order

# output a key-value pair only if the value is defined.
sub add_maybe {
  if ( @_ == 2 ) {
    my ( $key, $value ) = @_;
    return ( $key => $value ) if defined $value;
  }
  elsif ( @_ == 1 ) {
    my ($key) = @_;
    return defined($key) ? $key : ();
  }
  return ();
}

#  ($quotient, $remainder) = split_number($value, $divisor);
#  $quotient = split_number($value, $divisor);
#
# Divides two numbers and returns their quotient and (in list mode)
# non-negative remainder.
sub split_number {
  my ($value, $period) = @_;
  $period = abs($period);
  my $q = sprintf('%d', $value/$period)*$period;
  my $r = $value - $q;
  if ($r < 0) {
    $r += $period;
    $q -= $period;;
  } elsif ($r >= $period) {
    $r -= $period;
    $q += $period;
  }
  return wantarray? ($q, $r): $q;
}

#  $corrected_time = apply_camera_offset($time, $offset);
#
# Applies camera offset C<$offset> (in seconds) to a clone of
# C<$time>, which must be a Synchronize::Timestamp.  Returns the
# clone.
sub apply_camera_offset {
  my ( $t, $offset ) = @_;
  $t = $t->clone;        # don't modify object that argument refers to

  # In v2.0.0, we processed as follows:
  # - remove the timezone (if any) from $t
  # - set the timezone offset of $t to $offset, which was a plain number
  # - move $t to the local timezone

  if (Image::Synchronize::Timestamp->istypeof($offset)) {
    # the timezone offset has a time part and perhaps a timezone part
    $offset = $offset->clone; # don't modify object that argument
                              # refers to
  } else {
    # deprecated: offset is a number; support for backward
    # compatibility
    $t->set_timezone_offset($offset)
      ->adjust_to_local_timezone;
  }

  # If $offset has no timezone offset, then split its time part into
  # two parts: (1) the whole number of hours nearest its value, which
  # becomes the timezone part of $offset; (2) the remainder, which
  # becomes the new time part of $offset.
  #
  # For example, if $offset is +02:11:03 then it gets changed to
  # +0:11:03+02:00.
  if (not $offset->has_timezone_offset) {
    my ($q, $r) = split_number($offset->time_local, 3600);
    if ($r >= 1800) { # the offset is nearer the next higher hour than
                      # the current hour
      $r -= 3600;
      $q += 3600;
    }
    $offset = Image::Synchronize::Timestamp
      ->new($r)
      ->adjust_timezone_offset($q)
      ->adjust_nodate;
  }

  # Add the time part of $offset to $t and then adjust the timezone
  # of $t to the timezone of $offset.  For example, if $t is
  # 12:40:00+02:00 and $offset is +00:05+03:00, then the result is
  # 13:45:00+03:00.
  $t += $offset->time_local;
  $t->adjust_timezone_offset($offset->timezone_offset);

  return $t;
}

#  $backend = $ims->backend;
#
# Returns the L<Image::ExifTool> backend that is used to interact with
# the image files.
sub backend {
  my ($self) = @_;
  return $self->{backend};
}

#   $base_camera_id = base_camera_id($camera_id)
#
# Returns the camera ID without the "always UTC" suffix "|U", if any.
sub base_camera_id {
  my ($camera_id) = @_;

  # Camera IDs that we construct are like Make|Model|SerialNumber or,
  # if the file's CreateDate is always in UTC,
  # Make|Model|SerialNumber|U.  However, camera IDs that the user
  # supplies through --cameraid can have any format, and perhaps we
  # appended the "|U" suffix.
  return $1 if defined($camera_id) and $camera_id =~ /^(.*?)\|U$/;
  return $camera_id;
}

#   $pattern = basename_pattern($path);
#
# Returns text identifying the structure of the base name of the
# C<$path>, suitable for use as a camera ID if no explicit camera ID is
# known for the file.
#
# The returned text consists of the base name of the C<$path>, omitting
# the last period and any following text, and replacing any sequence of
# digits with the length of that sequence.
sub basename_pattern {
  my ($path) = @_;
  my $name = file($path)->basename;
  $name =~ s/\.[^.]+$//;    # remove file extension
  $name =~ s/(\d+)/length($1)/eg;
  return $name;
}

my %camera_id_tags
  = (
     Make => [qw(Make QuickTime:AndroidManufacturer)],
     Model => [qw(Model QuickTime:AndroidModel)],
     SerialNumber => [qw(SerialNumber)],
   );

#   $camera_id = camera_id($info);
#
# returns the ID of the camera, based on information extracted from an
# image file through Image::ExifTool::ImageInfo.  For some but not all
# types of camera, the camera ID includes a serial number that is
# unique to the camera.
sub camera_id {
  my ( $info ) = @_;
  my @values;
  foreach my $maintag (qw(Make Model SerialNumber)) {
    my $value;
    foreach my $tagtry (@{$camera_id_tags{$maintag}}) {
      my $v = $info->get(split /:/, $tagtry);
      if (defined $v) {
        $value = $v;
        last;
      }
    }
    push @values, $value // '';
  }
  my $id = join( '|', @values );
  if ($id =~ /^\|+$/) {
    $id = undef;
  } elsif ($info->get('supposedly_utc')) {
    $id .= '|U';
  }
  return $id;
}

#   $camera_id = $ims->camera_id_from_fallback($fallback_camera_id);
#
# Returns the regular camera ID of a camera that has a fallback camera
# ID equal to C<$fallback_camera_id>, or C<$fallback_camera_id> if
# there is no such camera.
sub camera_id_from_fallback {
  my ( $self, $fallback_camera_id ) = @_;
  my $r = $self->{fallback_to_camera_id}->{$fallback_camera_id};
  if ( defined $r ) {
    my @candidates =
      sort { ( $r->{$b} <=> $r->{$a} ) or ( $a cmp $b ) } keys %{$r};
    return $candidates[0];
  } else {
    return $fallback_camera_id;
  }
}

#   $camera_offsets_path = $ims->camera_offsets_path
#
# Returns the camera offsets path, which is taken from the
# C<offsetspath> option if defined.  If C<offsetspath> is not defined,
# then uses C<'.imsync-cameraoffsets.yaml'> if that file exists in the
# current working directory or if the C<HOME> environment variable
# isn't set, and otherwise uses that file name in the directory
# defined by the C<HOME> environment variable.
sub camera_offsets_path {
  my ( $self ) = @_;
  my $path = $self->option('offsetspath');
  if ( not defined $path ) {
    $path = '.imsync-cameraoffsets.yaml';
    if ( not(-e $path) and exists $ENV{HOME}) {
      $path = file( $ENV{HOME}, $path );
    }
  }
  return $path;
}

#  $ims->cleanup_progressbar($progressbar);
#
# Cleans up and removes the specified $progressbar.
sub cleanup_progressbar {
  my ( $self, $progressbar ) = @_;
  $progressbar->done;

  # Restore the original logger for logging to the screen, now that
  # the progress bar has disappeared.
  default_logger()->set_printer(
    {
      bitflags => ( $self->option('verbose') // 1 ),
      action   => sub { print @_; }
    }
  );
  return $self;
}

#  $prefix = common_prefix($separator, @values);
#
# Determines the common prefix of a collection of text values.  The
# returned common prefix ends with the specified separator, unless the
# common prefix is empty (or the separator is empty).
#
# For example, if (':', 'foo:bar:fie', 'foo:bar:zoo') are passed as
# arguments, then 'foo:bar:' is returned.
sub common_prefix {
  my ( $separator, @values ) = @_;
  return '' unless @values;
  my $value = shift @values;
  my @prefix = split /($separator)/, $value;
  my $shorter;
  foreach $value (@values) {
    my @next = split /($separator)/, $value;
    for my $i ( 0 .. $#prefix ) {
      if ( not( defined( $next[$i] ) ) or $next[$i] ne $prefix[$i] ) {
        @prefix  = @prefix[ 0 .. $i - 1 ];
        $shorter = 1;
        last;
      }
    }
  }
  pop @prefix if not($shorter) and $separator;
  return '' unless @prefix;
  my $result = join( '', @prefix );
  return $result;
}

#  $prefix = common_prefix_path(@paths);
#
# Determines the common prefix of a collection of file paths.  The
# returned common prefix ends with a path name separator, unless the
# common prefix is empty.  The returned path is in Unix style, with
# forward slashes as path separators.
#
# For example, if 'foo/bar/fie' and 'foo/bar/zoo' are passed as
# arguments, then 'foo/bar/' is returned.
sub common_prefix_path {
  my @args = map { file($_)->as_foreign('Unix')->stringify } @_;
  return common_prefix( '/', @_ );
}

# This is a callback function
sub convert_to_xmp {
  my ( $tag, $in, $out ) = @_;
  $out->{ 'XMP:' . $tag } = $in;
}

#  $offset = deduce_camera_offset($camera_time, $target_time);
#
# deduce the camera offset from the C<$camera_time> and the
# C<$target_time>.  The $target_time must have a timezone offset.  The
# $camera_time may or may not have a timezone offset.
#
# The deduced camera offset has a time part and a timezone part.  The
# time part says how much to add to the instant expressed by the
# camera time to get the instant expressed by the target time (if both
# are converted to the same timezone).  The timezone part says how
# much to add to UTC to get the nominal timezone offset of the camera.
# The nominal timezone is the timezone that the camera's clock was
# intended to follow.  The time part of the offset says how much the
# "true" camera timezone differed from the nominal one, perhaps due to
# misconfiguration or clock drift.
#
# If the camera time is 2020-07-30T08:22:30+02:00 and the target time
# is 2020-07-30T09:23:05+03:00 then the deduced camera offset is
# +00:00:35+02:00.
#
# TODO: what timezone should we assume for the target time if it has
# none, to get backward compatibility with versions of imsync
# predating the introduction of the timezone part of the camera
# offset?
#
# In the past the camera offset did not have a timezone part yet.
# Then the camera offset was added to the camera time (which was
# assumed to have no timezone offset) and the resulting timestamp was
# assumed to be given relative to the system's timezone for that
# instant.
#
# If the camera time was 2020-07-30T08:22:30 and the target time was
# 2020-07-30T09:23:05+03:00 (with the system's timezone offset
# UTC+03:00) then the deduced camera offset was +01:00:35.
sub deduce_camera_offset {
  my ( $camera_time, $target_time ) = @_;

  croak "Target time must have a timezone offset\n"
    unless $target_time->has_timezone_offset;

  my $d = Image::Synchronize::Timestamp->new($target_time - $camera_time)
    ->adjust_nodate;

  $d->adjust_timezone_offset($target_time->timezone_offset);
  return $d;
}

#   $ims->delete_backups(@file_patterns);
#
# Deletes any backup files matching the C<@file_patterns>.  Backup
# files have a name that ends in '_original'.
sub delete_backups {
  my ( $self, @arguments ) = @_;
  my @files = resolve_files( { recurse => $self->option('recurse') },
    Path::Iterator::Rule->new->$PIRname('*_original')->file, @arguments );

  log_message( "Removing " . scalar(@files) . " backup file(s).\n" );
  my $progressbar;
  if ( scalar(@files) ) {
    $progressbar = $self->setup_progressbar( scalar(@files), 'delete' );
    foreach my $file (@files) {
      unlink($file);
      $progressbar->add;
    }
    $self->cleanup_progressbar($progressbar);
  }
  log_message("Done removing backup file(s).\n");
  $self;
}

#  @best_scorers = best_scorers(sub { ... }, @targets)
#
# Return the best-scoring items.  The code reference, when called for
# a target, should return a numerical score.  The highest score among
# the @targets is determined, and all elements of @targets that have
# that highest score are returned.
sub best_scorers {
  my ($code, @targets) = @_;
  my %score = map { $code->($_) } @targets;
  my @order = sort { $score{$b} <=> $score{$a} } @targets;
  my $bestscore = $score{ $order[0] };
  return grep { $score{$_} == $bestscore } keys %score;
}

sub potential_donors {
  my ($self, $file, $info) = @_;
  my $number = $info->get('image_number');
  my @targets;
  if ( defined($number)
       && defined( $self->{files_for_image_numbers}->{$number} ) ) {
    my $target;
    @targets = grep { $_ ne $file }
      @{ $self->{files_for_image_numbers}->{$number} };
    if (@targets > 1) {
      # multiple files with the same number.  Arrange them in
      # descending order of priority; metadata that is missing from
      # the current file will be copied from the first target file
      # that has it.

      # descending priority order:
      # 1. current file name with '.yaml' appended
      # 2. greatest directory prefix in common with current file
      # 3. metadata file
      # 4. greatest basename pattern prefix in common with current file
      # 5. lexicographic order
      my $t1 = "${file}.yaml";
      my $t3 = basename_pattern($file);
      @targets = map { $_->[0] }
        sort {
               $b->[1] <=> $a->[1] # with .yaml suffix
            or $b->[2] <=> $a->[2] # common directory prefix
            or $b->[3] <=> $a->[3] # metadata file
            or $b->[4] <=> $a->[4] # common base name pattern
            or $a->[0] cmp $b->[0] # fallback: lexicographic order
            }
        map { [
               $_,
               ($_ eq $t1)? 1: 0,
               length_of_common_directory_prefix($_, $file),
               ($self->{original_info}->{$_}->get('is_metadata') // 0),
               length_of_common_prefix(basename_pattern($_), $t3)
             ] } @targets;
    }
  }
  return @targets;
}

#    $ims->determine_new_values_for_all_files;
#
# Determines the proposed final values (target timestamp, location, and
# so on) for the files, as far as possible.
#
# Returns C<$ims>.
sub determine_new_values_for_all_files {
  my ($self) = @_;

  my @files = sort keys %{ $self->{original_info} };

  my $progressbar = $self->setup_progressbar( scalar(@files), 'Determine' );

  # Process the files
  my @files_handle_by_number;
  my $count_modified    = 0;
  my %count_needs_force;
  foreach my $file (@files) {
    my $info = $self->{original_info}->{$file};

    if ( $self->has_useful_timestamp($file, $info) ) {

      # remember which files with embedded timestamps have which image
      # number
      push @{ $self->{files_for_image_numbers}->{ $info->get('image_number') } }, $file
        if defined $info->get('image_number');

      my @potential_donors = $self->potential_donors($file, $info);
      my $modification_type = $self->determine_new_values_for_file($file, \@potential_donors);

      ++$count_modified    if $modification_type == 1;

      my $extra_info = $self->{extra_info}->{$file};
      if (defined($extra_info)) {
        my $f = $extra_info->get('min_force_for_change');
        ++$count_needs_force{$f} if $f;
      }
    }
    elsif ( defined $info->get('image_number') ) {

      # mark but otherwise skip files that aren't image or movie files
      # but that have a potential image number; we can hopefully copy
      # the target time from another image or movie file with the same
      # number later, so we must make sure to process those
      push @files_handle_by_number, $file;
      next;
    }
    else {
      log_message(
        8,
        { name => $file },
        sub {
          <<EOD; } );

Processing '$file'.
 No relevant embedded timestamps or image number found -- skipped.
EOD
    }
    $progressbar->add;
  }

  # now process files with a file number but no embedded timestamp;
  # maybe we can copy the target timestamp from a file processed
  # earlier that has the same image number
  foreach my $file (@files_handle_by_number) {
    my $info   = $self->{original_info}->{$file};
    my $number = $info->get('image_number');
    if ( defined( $self->{files_for_image_numbers}->{$number} ) ) {
      my @potential_donors = $self->potential_donors($file, $info);
      $count_modified +=
        ($self->determine_new_values_for_file( $file, \@potential_donors ) == 1);
      my $extra_info = $self->{extra_info}->{$file};
      if (defined($extra_info)) {
        my $f = $extra_info->get('min_force_for_change');
        ++$count_needs_force{$f} if $f;
      }
    }
    else {
      log_message(
        8,
        { name => $file },
        sub {
          <<EOD; } );

Processing '$file'.
 No file from which to copy a target timestamp -- skipped.
EOD
    }

    $progressbar->add;
  }

  $self->cleanup_progressbar($progressbar);

  log_message("$count_modified file(s) need modification.\n");
  log_message($count_needs_force{1} . " file(s) need --force for modification.\n")
    if $count_needs_force{1} && $self->option('force', 0) < 1;
  log_message($count_needs_force{2} . " file(s) need --force --force for modification.\n")
    if $count_needs_force{2} && $self->option('force', 0) < 2;
  return $self;
}

sub get_from_targets {
  my ($self, $tag, $target_files) = @_;
  foreach my $tf (@{$target_files}) {
    my $v = $self->{new_info}->{$tf}->get($tag);
    if (defined $v) {
      return wantarray? ($v, $tf): $v;
    }
  }
  return;
}

# Compares $info and $new_info (which must be of type
# Image::Synchronize::GroupedInfo) to determine which tags need to be
# changed.
#
# $messages, if defined, is a reference to an array to which relevant
# progress messages are appended.
#
# $changes, if defined, is a reference to a hash to which key-value
# pairs are added in which the keys are the tags for which a change is
# needed and the values are the amount of force that is needed for the
# change.
#
# Returns 0 if no changes are needed.  If changes are needed, then
# returns 1 plus the minimum amount of force that is needed for any of
# the changes.
sub get_changes {
  my ($self, $file, $info, $new_info, $extra_info, $messages, $changes) = @_;

  $messages //= [];
  $changes //= {};

  my $can_change = is_image_or_movie($info);

  # In general, the file needs modification if FileModifyDate has
  # changed or if the GPS location and timestamp are newly added
  # or if the GPS location or timestamp have changed and
  # TimeSource was set but not equal to 'GPS'.
  #
  # If the user specified --force or --force 1, then the file also
  # needs modification if CameraID, DateTimeOriginal, or
  # TimeSource have changed or are newly added.
  #
  # If the user specified --force 2, then the file also needs
  # modification if the GPS location or timestamp have changed and
  # TimeSource was not set or was equal to 'GPS'.

  my $gps_location_tags_count;
  my $min_force_for_change = 99;
  if ($can_change) {
    # not a metadata file
    foreach my $tag (
                     qw(
                         CameraID
                         DateTimeOriginal
                         ImsyncVersion
                         FileModifyDate
                         GPSAltitude
                         GPSLatitude
                         GPSLongitude
                         TimeSource
                     )
                   ) {
      my $new    = $new_info->get($tag);
      my $old    = $info->get($tag);
      my $change = 1;

      if ( (defined($gps_location_tags{$tag}))
           and (defined($old) or defined($new)) ) {
        ++$gps_location_tags_count;
        next;                   # handle these separately
      }

      if ( defined $old ) {
        if ( defined $new ) {
          if ( $new ne $old ) {
            push @{$messages}, " $tag has changed.";
          } else {
            $change = 0;
          }
        } else {                # old but not new
          push @{$messages}, " $tag has disappeared,";
        }
      } elsif ( defined $new ) { # new but not old
        push @{$messages}, " $tag is new.";
      } else {                  # neither new nor old
        $change = 0;
      }
      if ($change) {
        state $force_1_tags = {
                               map { $_ => 1 }
                               qw(
                                   CameraID
                                   DateTimeOriginal
                                   ImsyncVersion
                                   TimeSource
                               )
                             };
        if ( $tag eq 'FileModifyDate' ) {
          $min_force_for_change = 0
            if $min_force_for_change > 0;
          $changes->{$tag} = 0;
        } elsif ( exists $force_1_tags->{$tag} ) {
          $min_force_for_change = 1
            if $min_force_for_change > 1;
          $changes->{$tag} = 1;
        }
      }
    }
  } else {
    # a non-image file; cannot change any embedded tags, only file
    # modification timestamp
    my $tag = 'FileModifyDate';
    my $new = $new_info->get($tag);
    my $old = $info->get($tag);
    my $change = 1;

    if ( defined $old ) {
      if ( defined $new ) {
        if ( $new ne $old ) {
          push @{$messages}, " $tag has changed.";
        } else {
          $change = 0;
        }
      } else {                # old but not new
        push @{$messages}, " $tag has disappeared,";
      }
    } elsif ( defined $new ) { # new but not old
      push @{$messages}, " $tag is new.";
    } else {                  # neither new nor old
      $change = 0;
    }
    if ($change) {
      $min_force_for_change = 0
        if $min_force_for_change > 0;
      $changes->{$tag} = 0;
    }
  }

  if ($gps_location_tags_count) {
    # Some cameras, for example the LG-H870, can record a GPS altitude
    # by itself, without a GPS latitude and longitude, when the camera
    # doesn't know its location.  We treat those cases as if the GPS
    # altitude wasn't there, but if the file gets modified anyway and
    # get no new GPS position then we remove the troublesome and
    # to us useless GPS altitude.
    my $change        = 1;
    my $old_pos_count = 0;
    my @old_pos       = map {
      my $v = $info->get($_);
      ++$old_pos_count
        if defined $v
        and $_ ne 'GPSAltitude';
      $v
    } @gps_location_tags;
    my $new_pos_count = 0;
    my @new_pos       = map {
      my $v = $new_info->get($_);
      ++$new_pos_count
        if defined $v
        and $_ ne 'GPSAltitude';
      $v
    } @gps_location_tags;
    my $distance = geo_distance( \@old_pos, \@new_pos );
    if ( defined $distance ) {  # the GPS location was complete in old
                                # and new

      # The precision of the updated or new coordinates as written in
      # the image file may differ from the precision provided by the
      # source of the coordinates.  Then later runs of this
      # application with the same inputs and configuration may report
      # a non-zero distance.  To avoid this problem we ignore
      # distances less than 1 cm.
      if ( $distance >= 0.01 ) {
        my ( $value, $prefix ) = si_prefix($distance);
        push @{$messages}, " GPS position has changed by $value ${prefix}m.";
        $extra_info->set( 'position_change', $distance );
        if ( $distance > ( $self->{max_gps_distance} // 0 ) ) {
          $self->{max_gps_distance} = $distance;
          $self->{max_gps_file}     = $file;
        }
      }
      else {
        $change = 0;
      }
    }
    elsif ( $old_pos_count == 2 ) {
      push @{$messages}, " GPS position has disappeared,";
      $new_info->delete($_) foreach ( @gps_location_tags, 'GPSDateTime' );
    }
    elsif ( $new_pos_count ) {
      push @{$messages}, " GPS position is new.";
    } elsif ($old_pos_count == 0) {
      # no old location and no new location and yet we got here.  Must
      # be the case where the file contains a solitary GPS altitude.
      push @{$messages}, ' Solitary GPS altitude.';
      $new_info->delete('GPSAltitude');
    } else {
      push @{$messages}, ' GPS position is incomplete.';
      $new_info->delete($_) foreach ( @gps_location_tags, 'GPSDateTime' );
    }
    if ($change) {

      # if the GPS position already existed and the TimeSource is
      # absent or equal to GPS, then we assume the GPS information was
      # embedded by a GPS device and should only be modified if the
      # --force level is at least 2.  Otherwise we assume that the old
      # GPS position (if any) was added by us in an earlier run; then
      # we can already modify it even if no --force is specified.
      if ( ( $info->get('TimeSource') // 'GPS' ) eq 'GPS' )
      {
        $min_force_for_change = 2
          if $min_force_for_change > 2;
        foreach my $tag (@gps_location_tags, 'GPSDateTime') {
          $changes->{$tag} = 2
          if stringify($info->get($tag)) ne stringify($new_info->get($tag));
        }
      }
      else {
        $min_force_for_change = 0
          if $min_force_for_change > 0;
        foreach my $tag (@gps_location_tags, 'GPSDateTime') {
          $changes->{$tag} = 0
            if stringify($info->get($tag)) ne stringify($new_info->get($tag));
        }
      }
    }
  }

  push @{$messages}, $new_info->stringify(' ');

  if (scalar(keys %{$changes}) == 1
      and exists $changes->{ImsyncVersion}
      and defined $info->get('ImsyncVersion')) {
    # The only thing that changed is the ImsyncVersion value: the file
    # already has that tag but the current version of imsync is newer
    # than the one that modified the file last.  This is not a good
    # reason to change the file, so we suppress that change.
    %{$changes} = ();
    $min_force_for_change = 99;
    $new_info->set('ImsyncVersion', $info->get('ImsyncVersion'));
    push @{$messages}, ' Only ImsyncVersion has changed -- suppressing.';
  }

  $extra_info->set( 'min_force_for_change', $min_force_for_change );

  my $result = 0;
  if ( $min_force_for_change < 99 ) {    # some changes
    if ( ( $extra_info->get('explicit_change') // 0 ) > 0
      or $self->option( 'force', 0 ) >= $min_force_for_change )
    {
      $extra_info->set( 'needs_modification', 1 );
      push @{$messages}, ' Modification of this file is indicated.';
      $extra_info->set( 'changes', [ sort keys %{$changes} ] )
        if keys %{$changes};
      $result = 1;
    }
    else {
      push @{$messages}, ' Modification of this file is suppressed, needs --force'
        . ( $min_force_for_change > 1 ? ' --force' : '' ) . '.';
      $result = $min_force_for_change + 1;
    }
  }
  else {
    push @{$messages}, ' No changes.';
  }

  return $result;
}

# returns 0 if the file needs no modification, 1 if the file needs
# modification (for the current level of force), or 1 + minimum needed
# force if the file needs more force if it is to be modified.
sub determine_new_values_for_file {
  my ( $self, $file, $donator_files ) = @_;

  # The user may have chosen to get progress messages printed only
  # when the file needs modification, but we can't tell yet if that is
  # the case.  Save up the messages until we can tell if we need them.
  my @messages;
  push @messages, "\nProcessing '$file'";

  my $info     = $self->{original_info}->{$file};
  my $new_info = $self->{new_info}->{$file} =
    new Image::Synchronize::GroupedInfo;
  my $extra_info = $self->{extra_info}->{$file} =
    new Image::Synchronize::GroupedInfo;

  # copy preferred tags to final list
  my @tagstoget = qw(
    CameraID
    CreateDate
    DateTimeOriginal
    FileModifyDate
    GPSAltitude
    GPSDateTime
    GPSLatitude
    GPSLongitude
    TimeSource
    );

  foreach my $tag (@tagstoget)
  {
    my $v = $info->get($tag);
    if (blessed $v) {
      # create a clone; we don't want to accidentally adjust the $info
      # member by adjusting the $new_info member
      $v = clone($v);
    }
    $new_info->set( $tag, $v ) if defined $v;
  }

  # TODO: only report donators when sufficiently verbose
  if (defined($donator_files) and @{$donator_files})
  {
    push @messages, " Possible donators in order of descending priority:";
    push @messages, "  $_" foreach @{$donator_files};
  }

  # for files that aren't image or movie files, we suppress changes of
  # any tags except FileModifyDate.
  my $can_change = is_image_or_movie($info);

  # For image and movie files, if there is at least one donator file
  # and if the first of them is a metadata file then we prefer the
  # metadata from the donator file.
  if ($can_change
      and defined($donator_files)
      and @{$donator_files}) {
    my $first_donator_info = $self->{original_info}->{$donator_files->[0]};
    if ($first_donator_info->get('is_metadata')) {
      foreach my $tag (@tagstoget) {
        my $v = $first_donator_info->get($tag);
        if (blessed $v) {
          # create a clone; we don't want to accidentally adjust the $info
          # member by adjusting the $new_info member
          $v = clone($v);
        }
        my $current = $new_info->get($tag);
        if (defined $current
            and (not(defined $v)
                 or $v ne $current)) {
          $new_info->set( $tag, $v );
        }
      }
    }
  }

  # determine final camera ID.

  # user-specified camera ID?
  my $camera_id = $self->user_camera_id($file);
  if ( defined $camera_id ) {
    push @messages, ' Camera ID set by user (--cameraid).';
    $extra_info->set( 'explicit_change', 1 ) if $can_change;
  } else {
    $camera_id = $info->get('camera_id');

    if ( not( defined $camera_id ) ) {
      ($camera_id, my $donator) =
        $self->get_from_targets('CameraID', $donator_files);
      if ( defined($camera_id) ) {
        push @messages, " Camera ID copied from '$donator'.";
      } else {
        my $fallback_camera_id = $info->get('fallback_camera_id')
          // fallback_camera_id($file);
        $camera_id = $self->camera_id_from_fallback($fallback_camera_id);
        if ( defined $camera_id ) {
          push @messages, ' Got camera ID via fallback.';
        }
      }
    }
  }
  $new_info->set( 'CameraID', $camera_id );

  # get creation timestamp if available

  my $timesource;           # value for TimeSource tag
  my $timesource_letter;    # letter to identify time source in report

  my $create_time = $new_info->get('CreateDate');
  if (not defined $create_time) {
    ($create_time, my $donator) =
      $self->get_from_targets('CreateDate', $donator_files);
    if (defined $create_time) {
      push @messages, " Creation timestamp copied from '$donator'.";
      $timesource_letter = 'n';
      $timesource = 'Other';
    }
  }

  # determine the target time

  my $target_time = $self->repository('user_times')->{$file};
  if (defined $target_time) {
    push @messages, " Target time is set by user.";
    $extra_info->set( 'explicit_change', 1 ) if $can_change;
    $timesource_letter //= 't';   # source is user's --time
    $timesource        //= 'User';
  } elsif (defined($camera_id) and defined($create_time)) {
    # An image file may or may not have a timezone offset specified
    # for its CreateDate.  How do we handle both kinds of timestamps
    # when applying a camera offset?
    #
    # A CreateDate timestamp is schematically T+Z (e.g.,
    # 2020-11-23T14:23+02:00) where T is the timestamp
    # (2020-11-23T14:23) and Z is the timezone offset (+02:00), in
    # such a way that T − Z = U aims for UTC (2020-11-23T12:23Z) -- if
    # a timezone offset is known.  If no timezone offset is known,
    # then the timestamp is just T.
    #
    # The camera offset is schematically t+z where t is the timestamp
    # part and z is the timezone part, similar to T and Z.
    #
    # Camera offsets written by versions < 2.001 don't have a timezone
    # part z.  They get treated as if the specified value were t + z
    # where z is the timezone offset that the current system would
    # have had on the indicated date in the current location.
    #
    # The target timestamp is schematically τ+ζ where τ is the
    # timestamp part and ζ is the timezone part, similar to T and Z.
    # The corresponding UTC time is τ − ζ = υ.
    #
    # If we don't know Z, then we want the target timestamp to be
    # calculated as
    #
    #  τ = T + t
    #  ζ =     z
    #
    # i.e., t is how much to add to T, and z is the timezone to assume
    # for the result.
    #
    # If we do know Z, then we still want t to indicate how far off
    # the CreateDate was, so
    #
    #  υ = U + t  ⇔  τ − ζ = T − Z + t  ⇔  τ = t + ζ + T − Z
    #
    # And we still want to end up in timezone z, so
    #
    #  ζ = z
    #  τ = t + z + T − Z
    #
    # If we compare the with-Z result with the no-Z result then we see
    # that they are equivalent if z = Z, i.e., equivalent to the
    # assumption that the CreateDate timezone is equal to the camera
    # offset timezone.

    my $cto = $self->gps_offsets->get($camera_id, $create_time);
    if ( defined $cto) {
      push @messages, " Target time is based on camera timezone offsets.";
      $timesource_letter //= 's'; # source is CreateDate plus other images
      $timesource        //= 'Other';

      unless ($cto->has_timezone_offset) {
        # timezone offset for local system at given instant
        my $tz = $cto->local_timezone_offset;
        # $cto_before->time_local
        # == $cto_after->time_local + $cto_after->timezone_offset
        # and $cto_after->timezone_offset = $tz
        # so $cto_after->time_local = $cto_before->time_local - $tz
        $cto = ($cto - $tz)->set_timezone_offset($tz);
      }

      $target_time = apply_camera_offset( $create_time, $cto );
    }
  }
  if (not defined $target_time) {
    $target_time = $new_info->get('DateTimeOriginal');
    if (defined $target_time) {
      push @messages,
        " Target time is embedded original time (DateTimeOriginal).";
      $timesource_letter //= 'o'; # source is DateTimeOriginal
    } else {
      ($target_time, my $donator) =
        $self->get_from_targets('DateTimeOriginal', $donator_files);
      if (defined $target_time) {
        push @messages, " Target timestamp copied from '$donator' (DateTimeOriginal).";
        $timesource_letter //= 'n'; # source is other file
      }
    }
    if (not defined $target_time) {
      $target_time = $new_info->get('CreateDate');
      if (defined $target_time) {
        push @messages, " Target time is embedded creation time (CreateDate).";
        $timesource_letter //= 'c'; # source is CreateDate
      }
    }
  }
  if (not defined $target_time) {
    ($target_time, my $donator) =
      $self->get_from_targets('FileModifyDate', $donator_files);
    if (defined $target_time) {
      push @messages, " Target timestamp copied from '$donator' (FileModifyDate).";
      $timesource_letter //= 'n'; # source is other file
    }
  }

  if (defined($target_time)) {
    $timesource //= 'Other';

    # the timezone part of the camera offset is the target timezone of
    # the target time
    my $cto = $self->gps_offsets->get($camera_id, $create_time // $target_time);

    if (defined $cto) {
      unless ($cto->has_timezone_offset) {
        # timezone offset for local system at given instant
        my $tz = $cto->local_timezone_offset;
        # $cto_before->time_local
        # == $cto_after->time_local + $cto_after->timezone_offset
        # and $cto_after->timezone_offset = $tz
        # so $cto_after->time_local = $cto_before->time_local - $tz
        $cto = ($cto - $tz)->set_timezone_offset($tz);
      }
      $target_time->adjust_timezone_offset($cto->timezone_offset);
    } else {
      $target_time->adjust_to_local_timezone;
    }

    if ( defined( my $j = $self->repository('jump')->{$file} ) ) {
      $target_time += $j * 3600;
      push @messages, " Clock time of camera jumped by $j hours.";
    }
  }

  if ($can_change) {
    $new_info->set('DateTimeOriginal', $target_time);
    $new_info->set( 'TimeSource', $timesource );
  }
  $extra_info->set( 'timesource_letter', $timesource_letter );

  # the File Modification Time may be in a different timezone than the
  # target time, because of --relativetime
  # TODO: suppress if target time is donated FileModifyDate?
  $new_info->set('FileModifyDate', $self->file_from_dto($target_time));

  push @messages, " Target time is $target_time.";

  # determine the camera offset

  if ($timesource_letter ne 'n'
      and defined($create_time)
      and defined($target_time)
      and defined ($camera_id)) {
    my $camera_timezone_offset =
      deduce_camera_offset( $create_time, $target_time );

    push @messages, ' Timezone offset for camera is '
      . $camera_timezone_offset->display_time . '.';

    # record the offset so it can be used for later files
    $self->gps_offsets->set($camera_id, $create_time, $camera_timezone_offset);
  }

  # determine position

  if ( defined($target_time) and $can_change) {
    my $position = $self->repository('user_locations')->{$file};
    if ( defined $position ) {
      $extra_info->set( 'explicit_change', 1 );
    } elsif (
             not( $info->get('GPSDateTime') ) # none yet
             or (
                 ( $info->get('TimeSource') // 'GPS' ) ne 'GPS' # not original
                 or $self->option( 'force', 0 ) >= 2 # or force is at least 2
               )
           ) {
      # presumably able to store a GPS position; deduce one if
      # possible.
      #
      # Do we have a target file with GPS information?
      (undef, my $donator) = $self->get_from_targets('GPSDateTime', $donator_files);
      if (defined $donator) {
        my $donator_info = $self->{new_info}->{$donator};
        # TODO: store in $positions
        # push @messages, " GPS information copied from '$donator'.";
        # foreach my $tag (@gps_location_tags, 'GPSDateTime') {
        #   $new_info->set($tag, $donator_info->get($tag));
        # }
      }
      #
      # If the file already had a GPS position, then should we
      # update it?  If TimeSource was absent or equal to 'GPS', then
      # the existing GPS position was embedded in the file when the
      # file was created, presumably directly from an attached GPS
      # device.
      #
      # In that case we should be very reluctant to update that
      # position, only updating the GPS position if --force has at
      # least a value of 2.  If --force is less than 2, then we
      # should propose to update the TimeSource to 'GPS' if it was
      # empty.
      #
      # If a GPS position and TimeSource were already present but
      # TimeSource is not equal to 'GPS', then the GPS position is
      # assumed to have been added by an earlier run of an
      # application like this one, and then it is OK to update it.
      my @gps_positions =
        $self->gps_positions->position_for_time( $target_time,
                                                 scope => scope_for_file($file) );
      if (@gps_positions) {
        my $l = length( $gps_positions[0]->{scope} );

        # ignore positions from other than the first (longest) scope
        @gps_positions = grep { length( $_->{scope} ) == $l } @gps_positions;

        if ( @gps_positions > 1 ) {

          # sort by track ID
          @gps_positions =
            sort { $a->{track} cmp $b->{track} } @gps_positions;
          @gps_positions = ( $gps_positions[0] );
        }
        $position = $gps_positions[0]->{position};
      }
    }
    if ( defined $position ) {
      if (@{$position}) {
        foreach my $ix (0..$#gps_location_tags) {
          my $v = $info->get($gps_location_tags[$ix]);
          $new_info->set( $gps_location_tags[$ix],  $position->[$ix] )
            if defined($position->[$ix]) and (not(defined $v) or $position->[$ix] != $v);
        }
        my $v = $info->get('GPSDateTime');
        $new_info->set( 'GPSDateTime', $target_time )
          if not(defined $v) or $target_time != $v;
        croak "Expected new TimeSource to have been set already\n"
          unless defined $new_info->get('TimeSource');
      } else {                  # remove position
        foreach my $ix (0..$#gps_location_tags) {
          $new_info->delete( $gps_location_tags[$ix] );
        }
        $new_info->delete( 'GPSDateTime' );
      }
    }
  }

  # If the current image is acquiring an embedded GPSDateTime,
  # then it is vital that it also ends up with an embedded
  # TimeSource, because imsync interprets a GPSDateTime without
  # a TimeSource as having been embedded in the image by the
  # original recording device (such as a smartphone), for which
  # the GPS fix may differ a few seconds from the image recording
  # time (with the difference not necessarily being the same from
  # one image to the next), which may cause imsync to round the
  # camera offset.
  #
  # However, if the new GPSDateTime is embedded by imsync
  # (together with a location), then the camera offset is deemed
  # to be exact and must not be rounded.  So, such a new
  # GPSDateTime must be accompanied by a suitable TimeSource, to
  # avoid it being interpreted later as an original GPSDateTime
  # for which the camera offset may get rounded, thus differing
  # from the previous camera offset and leading to the target time
  # being modified again (and erroneously).
  #
  # A TimeSource may be deduced during the Inspect phase even if
  # the image has no embedded TimeSource, so if the final
  # TimeSource (deduced during this Determine phase) is equal to
  # the TimeSource from the Inspect phase, then the above
  # $register call for XMP:TimeSource won't have registered a new
  # value for XMP:TimeSource, but if a GPSDateTime is being added
  # then we must also have a TimeSource.

  if ( $can_change ) {
    $new_info->set( 'DateTimeOriginal', $new_info->get('FileModifyDate') )
      unless defined $new_info->get('DateTimeOriginal');
    $new_info->set( 'ImsyncVersion',    $VERSION );

    # our XMP tags must go in the XMP namespace
    foreach my $tag (@own_xmp_tags) {
      my $value = $new_info->get($tag);
      if ( defined $value ) {
        $new_info->delete($tag);    # clear old value (not in a group)
        $new_info->set( 'XMP', $tag, $value );
      }
    }

    # We want to store DateTimeOriginal with a timezone, which means
    # we must put it in the XMP group, because DateTimeOriginal in the
    # default Exif group likely has no room for a timezone.
    {
      my $dto = $new_info->get('DateTimeOriginal');
      if (defined $dto) {
        $new_info->set( 'XMP', 'DateTimeOriginal', $dto );
        my $o = $info->get('DateTimeOriginal');
        if (defined($o) && not($o->has_timezone_offset)) {
          # original DateTimeOriginal has no timezone offset, so the
          # new one (for the Exif group) can't have one
          $new_info->set('DateTimeOriginal', $dto->clone->remove_timezone);
        }
      }
    }
  }

  my %changes;

  my $result = $self->get_changes($file, $info, $new_info, $extra_info,
                                  \@messages, \%changes);

  {
    my $camera_id = $new_info->get('CameraID');
    $self->{camera_ids}->{$camera_id} = 1 if defined $camera_id;
  }

  # if verbose & 4 then only print if needs_modification
  # if verbose & 8 then print even if not needs_modification
  # otherwise don't print
  my $bitflag = 8;
  $bitflag |= 4 if $extra_info->get('needs_modification');
  log_message( $bitflag, { name => $file }, join( "\n", @messages ) . "\n" );

  return $result;
}

#  $text = display_offset($offset, $maxlength);
#
# Returns a text representation of the time $offset measured in
# seconds, that is at most $maxlength characters wide.  The text
# representation uses 'y' for years, 'd' for days, 'h' for hours, 'm'
# for minutes, and 's' for seconds.  If the allowed width is too
# narrow to fit the entire representation, then only as many of the
# largest components are returned as will fit, and a period '.' is
# appended to indicate the truncation.  If $maxlength is undefined
# then the length is unrestricted.
sub display_offset {
  use integer;
  my ( $offset, $maxlength ) = @_;
  $maxlength //= 80;
  return '0' unless $offset;
  my $a       = abs($offset);
  my @steps   = ( 60, 60, 24, 365 );
  my @symbols = ( 's', 'm', 'h', 'd', 'y' );
  my @values;

  foreach my $step (@steps) {
    push @values, $a % $step;
    $a /= $step;
    last unless $a;
  }
  push @values, $a if $a;
  my @result;
  for my $i ( 0 .. $#values ) {
    push @result, $values[$i] . $symbols[$i] if $values[$i];
  }
  my $result = ( $offset > 0 ) ? '+' : '-';
  while ( my $value = pop @result ) {
    my $new_result = $result . $value;
    if ( length($new_result) > $maxlength ) {
      $result = $result . '.';
      last;
    }
    if ( length($new_result) == $maxlength
      and @result )
    {
      $result = $result . '.';
      last;
    }
    $result = $new_result;
  }
  return $result;
}

#  $regex = end_glob_to_regex($pattern);
#
# return a regular expression corresponding to glob C<$pattern>.
sub end_glob_to_regex {
  my ($pattern) = @_;
  $pattern = perlish_path($pattern);
  $pattern =~ s/([.+()])/\\$1/g;  # lose special meaning
  $pattern =~ s|\*|[^/]*|g;       # match zero or more characters not equal to /
  $pattern =~ s|\?|[^/]|g;        # match one character not equal to /
  my $case = $CASE_TOLERANT ? '(?i)' : '';
  return qr/${case}${pattern}$/;
}

#  $success = $ims->ensure_backup($file);
#
# Ensures that there is a backup of the $file.  The name of the backup
# is equal to $file with '_original' appended.  If such a file does
# not yet exist, then a copy of $file is made with that name.
#
# Returns a true value upon success, and otherwise a false value.
sub ensure_backup {
  my ( $self, $file ) = @_;
  my $copy  = "${file}_original";
  my $short = file($copy)->basename;
  if ( -e $copy ) {
    log_message(
      4,
      { name => $file },
      sub { "Backup '$short' of '$file' already exists.\n" }
    );
    return 1;
  }
  if ( copy( $file, $copy ) ) {
    log_message(
      4,
      { name => $file },
      sub { "Created backup '$short' of '$file'.\n" }
    );
    return 1;
  }
  else {
    log_error("Creating backup '$short' of '$file' failed; reason: $!\n");
    return;
  }
}

#  $ims->export_camera_offsets;
#
# Export the camera offsets.  Returns C<$ims>.
sub export_camera_offsets {
  my ($self) = @_;
  my $path   = $self->camera_offsets_path;
  if ($path) {
    my $data   = $self->gps_offsets->export_data;
    log_message("Exporting camera offsets to '$path'.\n");
    DumpFile( $path, $data );
  } else {
    log_message("Not exporting camera offsets because --offsetspath value was empty.\n");
  }
  $self;
}

#  $ims->exportgpx($exportfile);
#
# Exports the positions to GPX file C<$exportfile>.  Returns C<$ims>.
sub exportgpx {
  my ( $self, $exportfile ) = @_;

  return $self unless defined $exportfile;

  $exportfile = 'export.gpx' unless $exportfile;

  my ( $xmlroot, $minlat, $maxlat, $minlon, $maxlon, $count );
  foreach my $file ( sort keys %{ $self->{new_info} } ) {
    my $new_info = $self->{new_info}->{$file};
    next unless defined( my $longitude = $new_info->get('GPSLongitude') );
    # get GPSDateTime, not FileModifyDate, because of GPS fix lag
    next unless defined( my $time = $new_info->get('GPSDateTime') );

    ++$count;

    my $latitude = $new_info->get('GPSLatitude');
    my $altitude = $new_info->get('GPSAltitude');
    $time = $time->display_utc;

    $minlat = $latitude
      if not( defined $minlat )
      or $latitude < $minlat;
    $maxlat = $latitude
      if not( defined $maxlat )
      or $latitude > $minlat;
    $minlon = $longitude
      if not( defined $minlon )
      or $longitude < $minlon;
    $maxlon = $longitude
      if not( defined $maxlon )
      or $longitude > $minlon;

    $xmlroot //= XML::Twig::Elt->new(
      'gpx',
      {
        'xmlns'     => 'http://www.topografix.com/GPX/1/1',
        'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
        version     => '1.1',
        'xsi:schemaLocation' =>
'http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd',
        creator => 'Exiftime',
      }
    );

    # latitude must be between -90 and +90, inclusive
    # longitude must be between -180 and +180, inclusive
    my $wpt = $xmlroot->insert_new_elt(
      'last_child',
      wpt => {
        lat => $latitude,
        lon => $longitude
      }
    );
    $wpt->insert_new_elt( 'name', file($file)->basename );
    $wpt->insert_new_elt( 'time', $time ) if defined $time;
    $wpt->insert_new_elt( 'ele',  $altitude ) if defined $altitude;
  }

  if ( defined $xmlroot ) {
    my $metadata = $xmlroot->insert_new_elt('metadata');
    $metadata->insert_new_elt(
      bounds => {
        maxlat => $maxlat,
        maxlon => $maxlon,
        minlat => $minlat,
        minlon => $minlon
      }
    );

    $xmlroot->set_pretty_print('indented');
    $xmlroot->set_empty_tag_style('html');
    $xmlroot->print_to_file($exportfile);
    log_message(
      sub {
        "\nExported "
          . ( $self->option('modify') ? '' : '(intended) ' )
          . "GPS tags of "
          . ( $count // 0 )
          . " images to '$exportfile'.\n";
      }
    );
  }
  else {
    log_message( sub { "\nNo GPS tags to export to '$exportfile'.\n" } );
  }
  return $self;
}

#   $fallback_camera_id = fallback_camera_id($path);
#
# Returns the fall-back camera ID, to be used in case the usual
# information from which to deduce a camera ID is not available.
sub fallback_camera_id {
  my ( $path ) = @_;
  return '?' . basename_pattern($path);
}

#   @targets = $ims->find_info_targets($t);
#
# Returns the files that match C<$t>, which must be a
# Synchronize::Timestamp or a Synchronize::Timerange.
sub find_info_targets {
  my ( $self, $t ) = @_;
  my @targets;
  foreach my $file ( keys %{ $self->{original_info} } ) {
    my $create_date = $self->{original_info}->{$file}->get('CreateDate');
    next unless defined $create_date;
    push @targets, $file
      if $t->contains_local($create_date);
  }
  return @targets;
}

#  $r = geo_distance([$latitude1, $longitude1, $altitude1],
#                    [$latitude2, $longitude2, $altitude2]);
#
# Calculate the approximate distance in meters between the two
# positions.  The latitude and longitude are measured in degrees and
# the optional altitudes in meters.
sub geo_distance {
  my ( $pos1, $pos2 ) = @_;
  return unless ref $pos1 eq 'ARRAY' and ref $pos2 eq 'ARRAY';
  return unless scalar( @{$pos1} ) >= 2 and scalar( @{$pos2} ) >= 2;
  foreach my $p ( $pos1, $pos2 ) {
    foreach my $i ( 0 .. 1 ) {
      return unless defined $p->[$i];
    }
  }

  # Image::Exiftool stores longitude and latitude with a resolution of
  # 0.01 seconds of arc, and altitude with a resolution of 0.01 m, so
  # it is not useful to report a difference that is smaller than that
  # resolution.

  my @pos1_r = @{$pos1};
  @pos1_r[ 0 .. 1 ] = map { floor( $_ * 360000 + 0.5 ) } @pos1_r[ 0 .. 1 ];
  $pos1_r[2] = floor( $pos1_r[2] * 100 + 0.5 ) if defined $pos1_r[2];
  my @pos2_r = @{$pos2};
  @pos2_r[ 0 .. 1 ] = map { floor( $_ * 360000 + 0.5 ) } @pos2_r[ 0 .. 1 ];
  $pos2_r[2] = floor( $pos2_r[2] * 100 + 0.5 ) if defined $pos2_r[2];

  return 0
    if $pos1_r[0] == $pos2_r[0]
    && $pos1_r[1] == $pos2_r[1]
    && ( $pos1_r[2] // 'X' ) eq ( $pos2_r[2] // 'X' );

  use constant DEG => 45 / atan2( 1, 1 );
  use constant R => 6378000;

  my ( $lat1, $lon1, $alt1 ) =
    ( $pos1->[0] / DEG, $pos1->[1] / DEG, ( $pos1->[2] // 0 ) );
  my ( $lat2, $lon2, $alt2 ) =
    ( $pos2->[0] / DEG, $pos2->[1] / DEG, ( $pos2->[2] // 0 ) );
  my $x1 = ( R + $alt1 ) * cos($lon1) * cos($lat1);
  my $y1 = ( R + $alt1 ) * sin($lon1) * cos($lat1);
  my $z1 = ( R + $alt1 ) * sin($lat1);
  my $x2 = ( R + $alt2 ) * cos($lon2) * cos($lat2);
  my $y2 = ( R + $alt2 ) * sin($lon2) * cos($lat2);
  my $z2 = ( R + $alt2 ) * sin($lat2);
  my $dx = $x1 - $x2;
  my $dy = $y1 - $y2;
  my $dz = $z1 - $z2;
  my $rr = $dx * $dx + $dy * $dy + $dz * $dz;
  return sqrt($rr);
}

=head2 get_image_info

  $et->get_image_info($file);

Extract relevant information from the C<$file>, using
L<Image::ExifTool>, and returns a reference to a hash map containing
the extracted information.  The extracted tags are:

=over

=item CreateDate

=item DateTimeOriginal

=item Duration

=item FileModifyDate

=item GPSAltitude

=item GPSAltitudeRef

=item GPSDateTime

=item GPSLatitude

=item GPSLatitudeRef

=item GPSLongitude

=item GPSLongitudeRef

=item ImageWidth

=item Make

=item MIMEType

=item Model

=item QuickTime:CreationDate

=item SerialNumber

=item XMP:CameraID

=item XMP:ImsyncVersion

=item XMP:TimeSource

=item XMP:ExiftimeVersion

=back

Some of the requested tags may occur in the embedded information
multiple times (for example, once as an EXIF tag and once as an XMP
tag).  We store all occurrences in the returned map, with keys that
consist of the requested tag name with the tag group (= source) name
prefixed, separated by a colon (e.g., C<"Exif:DateTimeOriginal">).
Additionally, the preferred occurrence is stored in the map with a key
that has only the tag name without the group name (e.g.,
C<"DateTimeOriginal">).

If the ImageWidth tag is present, then the file is considered to be an
image, and then the returned hash map also includes the effective
camera ID, as the value for key C<effective_camera_id>.  The
ImageWidth tag is omitted from the hash map.

QuickTime images/movies (recognized by there being a
C<QuickTime:CreateDate> tag) get '|U' appended to their effective
camera ID, and the C<QuickTime::CreateDate> tag is omitted from the
hash map.

Each value is stored for the Image::ExifTool tag including the group
name, and also for the tag without the group name.  If a value occurs
in multiple groups (for example EXIF and XMP), then the preferred
value is stored for the tag without the group name.

=cut

sub get_image_info {
  my ( $self, $file ) = @_;

  my $info = new Image::Synchronize::GroupedInfo;

  {
    my $image_info = $self->backend->ImageInfo
      (
       $file,
       @all_tags,
       {
        PrintConv => 0,
        defined( $self->option('fastscan') )
        ? ( FastScan => $self->option('fastscan') )
        : (),
      }
     );

    if ( ( $image_info->{MIMEType} // '' ) =~ m|^image/| ) {
      $info->set( 'file_type', 'image' );
    }
    elsif ( ( $image_info->{MIMEType} // '' ) =~ m|^video/| ) {
      $info->set( 'file_type', 'video' );
    }
    elsif ( $image_info->{ImageWidth} ) {
      $info->set( 'file_type', $image_info->{Duration} ? 'video' : 'image' );
    }
    remove_tag( $image_info, 'ImageWidth', 'Duration' );    # no longer needed

    # There are some problems with the hash map returned by
    # Image::ExifTool::ImageInfo:
    #
    # The keys in the hash map may be different from the requested tag
    # names -- even if only a single instance of the requested
    # information occurs in the file.  The letter case of the keys may
    # be different from that of the requested tags.  The keys do not
    # include a tag group, even if the requested tag did include a tag
    # group.  If there are multiple values for a requested tag, then
    # each key gets a parenthesized 1-based index number appended to
    # it (e.g., "DateTimeOriginal (1)" and "DateTimeOriginal (2)".  In
    # such a case we want to know what the source (e.g., Exif, XMP) of
    # each of the values is, otherwise we cannot pick the preferred
    # value if the values are not identical.
    #
    # In the case of timestamps, some of them include timezone
    # information, but others do not.

    my $t = $self->backend->GetInfo("File:FileModifyDate");
    if ( $t and scalar keys %{$t} ) {

      # $t is a hash reference with one element.  We cannot predict
      # its tag name exactly; It lacks the 'File:' group name prefix
      # but might have a parenthesized instance number affixed.
      # Image::ExifTool::GetTagName merely removes the instance
      # number, if any, so is no help here.
      my $ts =
        Image::Synchronize::Timestamp->new( ( values %{$t} )[0] );
      if ($ts) {
        $info->set( 'File', 'FileModifyDate', $ts );
        remove_tag( $image_info, 'FileModifyDate' );
      }
    }

    # now treat the other tags
    foreach my $tag ( sort keys %{$image_info} ) {
      my $group    = $self->backend->GetGroup($tag);
      my $bare_tag = $tag =~ s/ \(\d+\)$//r;          # omit index number if any

      my $value    = $image_info->{$tag};

      if ( exists $time_tags{$bare_tag}
        or exists $time_tags{"$group:$bare_tag"} )
      {                                               # it expresses a time
        $value = Image::Synchronize::Timestamp->new($value);
      }

      if (defined $value) {
        $info->set( $group, $bare_tag, $value );
      } # otherwise $value was undefined, for example because a
        # timestamp tag's value wasn't valid.
    }

    # The GPS tags need special treatment.  The sign of the
    # longitude/latitude/altitude is generally stored separately from
    # the value, and we need to combine them.  Exiftool may provide
    # already combined values in the 'Composite' and 'XMP' groups,
    # except that XMP:GPSAltitude appears not to include a sign yet.
    foreach my $tag (@gps_location_tags) {
      foreach my $composite_group (qw(Composite XMP)) {
        my $composite = $info->get($composite_group, $tag);
        if (defined($composite)
            && ($tag ne 'GPSAltitude'
                || $composite_group ne 'XMP')) {
          # We have a composite value, store in the group with the
          # empty name ('') so it is the preferred value
          $info->set('', $tag, $composite);
          last;
        }
      }
      if (not defined $info->get('', $tag)) {
        # no composite value yet, so try to construct one from the
        # separate parts
        foreach my $group ($info->groups($tag)) {
          my $value = $info->get($group, $tag);
          my $ref = $info->get($group, $tag . 'Ref');
          if (defined($value) and defined($ref)) {
            if ((   $tag eq 'GPSLongitude' and $ref eq 'W')
                || ($tag eq 'GPSLatitude'  and $ref eq 'S')
                || ($tag eq 'GPSAltitude'  and $ref eq '1')) {
              $value = -$value;
            }
            $info->set('', $tag, $value);
            last;
          }
        }
      }
    }
  }

  if ( is_supposedly_utc($info) ) {

    if ( defined $info->get( 'QuickTime', 'CreationDate' )
      and $info->get( 'QuickTime', 'CreationDate' )->has_timezone_offset )
    {
      # We expect that this tag represents absolute time, and allows
      # UTC to be deduced.  We rename the tag from CreationDate to
      # CreateDate so it has the same name as for the other sources.
      $info->set( 'QuickTime', 'CreateDate',
        $info->get( 'QuickTime', 'CreationDate' ) );
      $info->delete( 'QuickTime', 'CreationDate' );
    }

    if ( defined $info->get('GPSLongitude')
      and not( defined $info->get('GPSDateTime') ) )
    {
      # Some QuickTime files with a GPS position embedded in the
      # QuickTime section have no explicit GPSDateTime defined,
      # because some other timestamp serves the same purpose.
      # (E.g., for Apple iPod Touch.)  The remainder of this program
      # assumes that if GPS information is present then it includes
      # at least longitude, latitude, and time, so copy a suitable
      # timestamp to GPSDateTime
      $info->set( 'GPSDateTime', $info->get( 'QuickTime', 'CreateDate' ) );
      $info->get('GPSDateTime')->adjust_to_utc;    # just in case
    }
  }

  if (not(defined $info->get('CreateDate'))) {
    # can we get a CreateDate from another tag?
    my $ct = $info->get('RIFF', 'DateTimeOriginal');
    if (defined $ct) {
      $info->set('CreateDate', $ct);
    }
  }

  # for synchronizing the times of non-image files with those of
  # related image files, we determine the "image number" of each file.
  {
    my $number = get_image_number($file);
    $info->set( 'image_number', $number ) if defined $number;
  }

  return $info;
}

# read image/movie metadata from a text file.  The metadata is assumed
# to be in JSON or YAML format and to contain tags as produced by
# "exiftool -n -j", optionally (and preferably) also with the "-G"
# option.
sub get_image_info_from_metadata_file {
  my ($file) = @_;

  my $info;

  my $metadata = LoadFile($file);

  if (ref($metadata) eq 'ARRAY' && scalar(@{$metadata}) == 1) {
    # single-element array, uncover the single element
    $metadata = $metadata->[0];
  }
  if (ref($metadata) eq 'HASH') {
    $info = new Image::Synchronize::GroupedInfo;

    foreach my $k (keys %{$metadata}) {
      my ($group, $tag) = $k =~ /^(?:([^:]+):)?(.*)$/;
      if (defined $tag) {
        if (exists($all_tags{$k}) || exists($all_tags{$tag})) {
          # a tag that interests us
          $info->set($group, $tag, $metadata->{$k});
        }
      }
    }
    if ($info->tags_count > 0) {
      # mark that this information is metadata about another file
      $info->set('is_metadata', 1);
    }
  }
  return $info;
}

# extract the image number from the C<$file> name.  The image number
# is found as follows: (1) remove the directory part and the file name
# extension from the file name, where the file name extension begins
# at the last period '.'; (2) remove the part after the last digit;
# (3) remove the part up to and including the last letter; (4)
# concatenate the digits that remain.  Some examples that yield image
# number 1234: IMG_1234.JPG IMG_1234-extra.txt foo6x1.2_3.4-y.mov
sub get_image_number {
  my ($file) = @_;
  my $file2 = file($file)->basename; # remove directory part, if any
  $file2 =~ s/\.([^.]*)$//;          # remove file extension, if any
  $file2 =~ s/(\d)\D*$/$1/;          # (2)
  $file2 =~ s/^.*?[[:alpha:]]([^[:alpha:]]*)$/$1/; # (3)
  my $number = join('', split /\D+/, $file2);
  return unless defined $number;
  return if $number eq '';
  return $number + 0;
}

#   $gps_offsets = $ims->gps_offsets;
#
# Returns a reference to the offsets of GPS times relative to file
# creation times.
sub gps_offsets {
  my ($self) = @_;
  return $self->{gps_offsets};
}

#   $gpc = $ims->gps_positions;
#
# Returns an C<Image::Synchronize::GpsPositionCollection> object
# representing GPS positions as a function of time, obtained from GPX
# files.
sub gps_positions {
  my ($self) = @_;
  return $self->{gps_positions};
}

sub has_embedded_timestamp {
  my ($image_info) = @_;
  foreach my $tag (qw(CreateDate DateTimeOriginal GPSDateTime)) {
    my ( $group, $value ) = $image_info->get_context($tag);
    return 1 if defined($value) and $group ne 'File' and $group ne '';
  }
  return 0;
}

sub has_useful_timestamp {
  my ($self, $file, $image_info) = @_;
  return ( has_embedded_timestamp($image_info)
           || defined($self->repository('user_times')->{$file}) );
}

# identify @files that match the $pattern.  The match is case
# sensitive, except on case-insensitive operating systems.
sub identify_files {
  my ( $pattern, @files ) = @_;
  my %original;
  my @tfiles;
  if ($CASE_TOLERANT) {
    # lowercase the file names and pattern if the operating system
    # uses case insensitive path names so the match becomes case
    # insensitive.  Remember the original path names so we can return
    # those (the matching ones) instead of the lowercased versions.
    $pattern = lc $pattern;
    @tfiles = map { lc =~ s|^\./||r } @files;
  } else {
    @tfiles = map { s|^\./||r } @files;
  }
  foreach my $i (0..$#files) {
    $original{$tfiles[$i]} = $files[$i];
  }
  $pattern = '*' . $pattern unless $pattern =~ /^\*/;
  return map { $original{$_} } match_glob($pattern, @tfiles);
}

#  $ims->import_camera_offsets;
#
# Imports camera offsets from the camera offsets file.  Returns
# C<$ims>.
sub import_camera_offsets {
  my ($self) = @_;
  my $path = $self->camera_offsets_path;
  if ($path) {
    if ( -e $path ) {
      log_message("Importing camera offsets from '$path'.\n");
      my $data = LoadFile($path);
      $self->gps_offsets->parse($data)
        or croak "Imported camera offsets are invalid: $@\n";
      log_message(
                  16,
                  sub {
                    "Camera Offsets:\n", Dump( $self->gps_offsets->export_data ), "\n";
                  }
                );
    } else {
      log_message("No camera offsets file found to import from.\n");
    }
  } else {
    log_message("Not importing camera offsets because --offsetspath has an empty value.\n");
  }
  $self;
}

# initialize_logging
#
#   $ims->initialize_logging
#
# Set up logging to a file.  Returns <$ims>.
sub initialize_logging {
  my ($self) = @_;

  # configure logging to standard output
  Image::Synchronize::Logger->new(
    {
      bitflags => $self->option( 'verbose', 1 ),
      action   => sub { print @_; }
    }
  )->set_as_default;

  # configure logging to the log file
  my $logfile = $self->option( 'logfile', 'imsync.log' );
  my $ofh;
  if ( $self->option('clearlog') ) {
    open $ofh, '>', $logfile
      or croak "Cannot open '$logfile' for writing: $^E\n";
  }
  else {
    open $ofh, '>>', $logfile
      or croak "Cannot open '$logfile' for appending: $^E\n";
  }
  $ofh->autoflush;    # we may be watching the file
  $self->{logfh}   = $ofh;
  $self->{logfile} = $logfile;

  default_logger()->set_printer(
    {
      name     => 'file',
      bitflags => $self->option( 'verbose', 1 ),
      action   => sub { print $ofh @_; }
    }
  );

  $self;
}

# initialize_own_xmp_namespace
#
#   $ims = $ims->initialize_own_xmp_namespace;
#
# Initialize our own XMP namespace for embedding our own tags into
# image files through Image::ExifTool.  Returns C<$ims>.
sub initialize_own_xmp_namespace {
  my ($self) = @_;

  # to delete all XMP tags using exiftool, use exiftool -XMP:all=
  # <files>

  {
    no warnings;    # suppress warning about ..::imsync being used only once

    %Image::ExifTool::UserDefined::imsync = (
      GROUPS    => { 0        => 'XMP', 1 => 'XMP', 2 => 'Image' },
      NAMESPACE => { 'imsync' => 'http://imsync.quae.nl/' },
      WRITABLE  => 'string',
      map { $_ => {} } @own_xmp_tags
    );

    %Image::ExifTool::UserDefined = (

      # add new XMP namespace to the Main XMP table
      'Image::ExifTool::XMP::Main' => {
        imsync => {
          SubDirectory => {
            TagTable => 'Image::ExifTool::UserDefined::imsync'
          },
        },
      }
    );
  }

  $self;
}

sub enhance_image_info {
  my ($self, $file, $info) = @_;

  # TODO: remove this when the author no longer needs it to transition
  # from exiftime to imsync
  if ( defined $info->get('ExiftimeVersion') ) {
    log_warn("ExiftimeVersion found in $file.\n");
  }

  my $count_essential_gps_tags = 0;
  foreach (qw(GPSDateTime GPSLongitude GPSLatitude)) {
    ++$count_essential_gps_tags if defined $info->get($_);
  }
  if (  $count_essential_gps_tags
        and $count_essential_gps_tags < 3 ) {
    log_warn(<<EOD);
File '$file' has some but not all of GPSDateTime,
GPSLongitude, GPSLatitude.  Ignoring its GPS information.
EOD
    $info->delete($_)
      foreach qw(GPSLatitude GPSLongitude GPSAltitude GPSDateTime);
  }

  $info->set( 'supposedly_utc', 1 ) if is_supposedly_utc($info);

  # determine the camera ID.

  my $camera_id;
  {
    my $embedded_camera_id = $info->get('CameraID');

    if (defined $embedded_camera_id
        and not $self->option('force', 0)) {
      # no --force was applied, so just reuse the embedded
      # camera ID
      $camera_id = $embedded_camera_id;
    } else {
      # construct a camera ID from the embedded information
      $camera_id = camera_id($info);
    }
  }

  # there may not be sufficient information to deduce a camera
  # ID in the preferred way; also deduce a fallback camera ID
  # that is always available
  my $fallback_camera_id = fallback_camera_id( $file );

  if (defined $camera_id
      and $camera_id eq $fallback_camera_id) {
    $camera_id = undef;
  }

  if ( defined $camera_id ) {
    $info->set( 'camera_id', $camera_id );

    # remember for later, so we can hopefully substitute real
    # camera IDs for some fallback ones.
    ++$self->{fallback_to_camera_id}->{$fallback_camera_id}->{$camera_id};
  }
  $info->set( 'fallback_camera_id', $fallback_camera_id );
}

#   $ims->inspect_files(@files);
#
# Inspects the @files.  The files are inspected but not modified,
# because we may be able to use information from a later image to
# synchronize the time of an earlier image, but we can't tell until
# we've inspected all files.
#
# Relevant properties are remembered, and files that provide too
# little information (or are found to not be image or movie files) are
# omitted from further consideration.
#
# Returns the object.
sub inspect_files {
  my ( $self, @files ) = @_;

  my $count_image_files     = 0;
  my $count_gps_times       = 0;
  my $count_gps_track_files = 0;

  # We display a progress bar to show how far we are in processing all
  # files.
  my $progressbar = $self->setup_progressbar( scalar(@files), 'Inspect' );

  my %gpx_files;

  $self->{fallback_to_camera_id} = {};

  # Now process the files.
  foreach my $file (@files) {

    log_message( 2, { name => $file }, sub { "\nInspecting '$file'\n" } );

    if ( is_gpx_track($file) ) {    # a GPX track
      ++$count_gps_track_files;
      push @{ $self->{gpx_tracks} }, $file;
      $self->{gpx_total_size} += -s $file;
      log_message( 2, { name => $file }, " Is a GPX file.\n" );
    }
    else {
      my $info =
        $self->get_image_info( $file );

      # if we have the creation timestamp only from the file system
      # and not from an embedded tag, then we cannot deduce the target
      # timestamp from the creation timestamp (because the file
      # apparently wasn't created by a camera).  We need to be able to
      # detect this.
      my ( $group, $createdate ) = $info->get_context('CreateDate');
      $info->set( 'createdate_was_embedded', 1 )
        if defined($createdate)
        and $group ne 'File';

      if (is_image_or_movie($info)) {
        $self->enhance_image_info($file, $info);
        ++$count_image_files;
        ++$count_gps_times if defined $info->{GPSDateTime};
      } else {
        my $type;
        if (($info->get('MIMEType') // '') =~ m'application/(json|yaml)') {
          # the MIMEType is detected based on the file's contents,
          # regardless of its file name extension
          $type = uc($1);
        } elsif ($file =~ /\.ya?ml$/i) {
          # but at the time of writing this there is no YAML-specific
          # MIMEType yet, so we can also detect YAML files based on
          # the file name extension
          $type = 'YAML';
        }
        if ($type) {
          my $metainfo = get_image_info_from_metadata_file($file);
          if (defined $metainfo) {
            $self->enhance_image_info($file, $metainfo);
            my @tags = $metainfo->tags;
            if (@tags) {
              log_message(2, { name => $file }, " Is a $type metadata file.\n" );
              # $info->set('is_metadata', 1);
              foreach my $tag ($metainfo->tags) {
                my ($group, $value) = $metainfo->get_context($tag);
                if (not defined($info->get($group, $tag))) {
                  # this group/tag is not in $info yet
                  if (exists $time_tags{$tag}) {
                    $value = Image::Synchronize::Timestamp->new($value);
                  }
                  $info->set($group, $tag, $value);
                }
              }
              ++$count_gps_times if defined $info->{GPSDateTime};
            }
          }
        }
      }

      $self->{original_info}->{$file} = $info;
      log_message( 2, { name => $file }, $info->stringify(' Found ') . "\n" );
    }

    $progressbar->add;
  }
  $self->cleanup_progressbar($progressbar);

  log_message("\n");
  log_message("Found $count_gps_track_files GPS track file(s).\n")
    if $count_gps_track_files;
  log_message("Found $count_image_files image file(s).\n");
  log_message("$count_gps_times file(s) have a GPS timestamp.\n");
  return $self;
}

#   $ok = is_gpx_track($file);
#
# determines whether the named file is a GPX file, by looking for
# "<gpx " in its first line.  This is much faster than trying to parse
# the entire file using an XML parser.
sub is_gpx_track {
  my ($file) = @_;
  if ( open my $ifh, '<', $file ) {
    my $line;
    do {
      $line = <$ifh>;
    } until eof($ifh) or $line =~ /<[^?]/;
    close $ifh;
    return 1 if defined($line) and $line =~ /<gpx /;
  }
  else {
    log_message( { name => $file },
      sub { "Cannot open file '$file' for reading: $^E\n" } );
  }
  return 0;
}

#   $ok = is_image_or_movie($image_info);
#
# Queries whether the C<$image_info> indicates that the source was an
# image or movie file.  Returns a true value if yes, a false value if
# no.
sub is_image_or_movie {
  my ($image_info) = @_;
  return ( $image_info->get('file_type') // '' ) =~ /^image|video$/;
}

#   $ok = is_supposedly_utc($image_info);
#
# Queries whether the C<$image_info> indicates an image source whose
# CreateDate is supposedly in UTC instead of in the local timezone.
# Returns a true value if yes, a false value if no.
#
# Such timestamps that are supposed to be in UTC sometimes are not,
# for instance when the image source doesn't know what timezone it is
# in.
sub is_supposedly_utc {
  my ($image_info) = @_;

  # For a QuickTime file, QuickTime:CreateDate does not include an
  # explicit timezone.  It is supposed to be in UTC, but sometimes
  # isn't.  (For example, if the camera doesn't know what timezone it
  # is in.)  Sometimes QuickTime:CreateDate is in neither UTC nor the
  # camera's local timezone.

  return defined( $image_info->get( 'QuickTime', 'CreateDate' ) );
}

sub length_of_common_prefix {
  my ( $a, $b ) = @_;
  my @a = split //, $a;
  my @b = split //, $b;
  splice @a, scalar(@b);
  foreach my $i (0..$#a) {
    return $i if $a[$i] ne $b[$i];
  }
  return scalar(@a);
}

sub length_of_common_directory_prefix {
  my ($a, $b) = @_;
  my $a2 = file($a)->parent->stringify;
  my $b2 = file($b)->parent->stringify;
  return length_of_common_prefix($a2, $b2);
}

my %convert_for_writing = (
  GPSLatitude => sub {
    my ( $tag, $in, $out ) = @_;

    # don't set coordinates to abs($in).  If the coordinate is
    # writting to XMP rather than EXIF, then there is no GPSxRef so
    # then the sign on GPSx is needed.
    $out->{"${tag}#"} = $in;
    $out->{"${tag}Ref#"} = ( $in > 0 ) ? 'N' : 'S';
  },
  GPSLongitude => sub {
    my ( $tag, $in, $out ) = @_;
    $out->{"${tag}#"} = $in;
    $out->{"${tag}Ref#"} = ( $in > 0 ) ? 'E' : 'W';
  },
  GPSAltitude => sub {
    my ( $tag, $in, $out ) = @_;
    $out->{"${tag}#"} = $in;
    $out->{"${tag}Ref#"} = ( $in > 0 ) ? 0 : 1;
  },
  GPSDateTime => sub {
    my ( $tag, $in, $out ) = @_;
    my $t = Image::Synchronize::Timestamp->new($in)->adjust_to_utc;

    # GPSDateStamp and GPSTimeStamp are needed for EXIF.
    $out->{GPSDateStamp} = $t->date;
    $out->{GPSTimeStamp} = $t->time;

    # GPSDateTime is for XMP, in case the GPS coordinates ended up in
    # XMP.
    $out->{$tag} = "$t";
  },
  DateTimeOriginal => sub {
    my ( $tag, $in, $out ) = @_;

    # make sure to also write in XMP
    $out->{$tag} = $in;
    $out->{ 'XMP:' . $tag } = $in;
  },
  ImsyncVersion => \&convert_to_xmp,
  CameraID      => \&convert_to_xmp,
  TimeSource    => \&convert_to_xmp,
);

sub set_file_modification_time {
  my ($self, $file, $time_utc) = @_;
  utime undef, $time_utc, $file;
#  return $self->backend->SetFileTime($file, undef, $time_utc);
}

#   $et->modify_file($file);
#
# Modify the $file as indicated in the information gathered in
# C<$self>.  Ensures that there is a backup of the file before
# modifying the original -- and refuses to modify the original
# otherwise.
#
# Returns 1 if the file was modified OK, 2 if the file was written but
# no changes were made, 3 if the file was not modified because no
# backup could be created for it, 4 if there was an error writing the
# file but the metadata could be written to a separate file, 5 if
# there were errors writing the file and writing the separate metadata
# file, and 0 if there were no changes to make.
sub modify_file {
  my ( $self, $file ) = @_;

  my $new_info   = $self->{new_info}->{$file};
  my $extra_info = $self->{extra_info}->{$file};
  my $changes    = $extra_info->get('changes');
  return 0 unless defined($changes) and scalar( @{$changes} );

  my $status;
  my $b = $self->backend;

  {
    my $size = -s $file;
    log_message(
      2,
      { name => $file },
      sub { "Modifying '$file' ($size bytes)\n" }
    );
  }
  if ( $self->option('unsafe') || $self->ensure_backup($file) ) {

    $b->SaveNewValues();    # so we can return to a clean slate

    # then we treat all requested tags
    $b->ExtractInfo($file);

    my $changed;
    my $found_filemodifydate_tag;
    foreach my $tag ( @{$changes} ) {
      $found_filemodifydate_tag = 1, next
        if $tag eq 'FileModifyDate';    # done separately
      my $value = $new_info->get($tag);
      my %values;
      if ( defined $value ) {
        $value = "$value";              # stringify
        if ( $convert_for_writing{$tag} ) {
          $convert_for_writing{$tag}->( $tag, $value, \%values );
        }
        else {
          $values{$tag} = $value;
        }
      }
      else {
        # delete this tag
        if ( $convert_for_writing{$tag} ) {

          # figure out which tags we need to adjust
          # use "dummy" value 0
          $convert_for_writing{$tag}->( $tag, 0, \%values );

          # set value to undef so tag will get deleted by
          # SetNewValue
          $values{$_} = undef foreach keys %values;
        }
        else {
          $values{$tag} = undef;
        }
      }
      foreach my $t ( sort keys %values ) {
        my ( $success, $error ) = $b->SetNewValue( $t, $values{$t} );
        if ($success) {
          log_message(
            4,
            {
              name => $file
            },
            sub {
              defined( $values{$t} )
                ? " Set $t of '$file' to '" . $values{$t} . "'\n"
                : " Removed $t from '$file'\n";
            }
          );
          $changed += $success;
        }
        else {
          log_warn(
            defined( $values{$t} )
            ? " ExifTool error setting $t of '$file' to '" . $values{$t} . "': $error\n"
            : " ExifTool error removing $t from '$file': $error\n"
          );
        }
      }
    }

    if ( $changed ) {

      $status = $b->WriteInfo($file);    # write to file
      if ( $status == 2 ) {
        log_warn(" '$file' written but no changes made.\n");
      }
      if ( $status == 1 ) {
        my $warning = $b->GetValue('Warning');
        if ($warning) {

          # We suppress warnings about the FileName encoding not being
          # specified.  We don't invent or modify the byte values of the
          # file name, so the encoding should be unimportant as long as
          # Image::ExifTool doesn't modify any file name byte values,
          # either.
          my @warnings = split /\n/, $warning;
          @warnings = grep { !/
                                FileName[ ]encoding[ ]not[ ]specified
                              |Maker[ ]notes[ ]could[ ]not[ ]be[ ]parsed
                              /x } @warnings;
          if (@warnings) {
            $warning = join( "\n", @warnings );
            log_warn(" Writing '$file' succeeded with ExifTool warning: $warning\n");
          }
        }
      }
      else {
        # Writing via Image::ExifTool failed.  We write the tags to a
        # corresponding metadata file instead.  If the writing failed
        # because Image::ExifTool does not support the file type
        # (yet), then we report that problem only for the first file
        # of that type -- to avoid numerous otherwise unavoidable
        # warnings.

        my @messages;
        my $error = $b->GetValue('Error');
        if ($error =~ /(Writing of (?:.*?) files is not yet supported)/) {
          state %suppress;
          if (not $suppress{$1}) {
            push @messages,
              " Writing '$file' failed, ExifTool reports:\n  $error\n",
              " This message is suppressed for similar following files.\n";
            # mark that we reported this problem already
            $suppress{$1} = 1;
          }
        } else {
          push @messages,
            join( ', ',
                  " Writing '$file' failed",
                  ( $error ? "ExifTool reports:\n $error" : () ))
            . "\n"
            ;
        }

        # write the tags to a metadata file instead, if any of the
        # tags have changed relative to what is in the metadata file
        # already
        my $metafile = "${file}.yaml";
        my $old_metainfo;
        if (-r $metafile) {
          $old_metainfo = get_image_info_from_metadata_file($metafile);
        } else {
          $old_metainfo = new Image::Synchronize::GroupedInfo;
        }
        my %changes;
        $changed = $self->get_changes($file, $old_metainfo, $new_info, $extra_info,
                                      undef, \%changes);
        if ($changed) {
          if (exists $changes{FileModifyDate}
              and scalar keys %changes == 1) {
            # only FileModifyDate needs to be changed
            $self->set_file_modification_time($metafile,
                                              $new_info->get('FileModifyDate')->time_utc);
            $status = 4;
          } else {
            # the contents of the metadata file needs changes
            my %values_for_export;
            foreach my $tag ($new_info->tags) {
              foreach my $group ($new_info->groups($tag)) {
                my $v = $new_info->get($group, $tag);
                $values_for_export{$group? "$group:$tag": $tag} = "$v";
              }
            }
            if (DumpFile($metafile, \%values_for_export)) {
              push @messages, " Wrote metadata to '$metafile'.\n";
              $self->set_file_modification_time($metafile,
                                                $new_info->get('FileModifyDate')->time_utc);
              $status = 4;
            } else {
              push @messages, " Writing metadata to '${file}.yaml' failed: $@\n";
              $status = 5;
            }
          }
        } else {
          $changed = 0; # no changes (perhaps excluding FileModifyDate) after all
        }
        if (@messages) {
          log_message(join("\n", @messages) . "\n");
        }
      }
    }

    if ( $changed or $found_filemodifydate_tag ) {
      # Updating the FileModifyDate (the file system modification
      # timestamp) via WriteInfo doesn't always work; for example,
      # ExifTool 10.63 does not support modifying AVI files.
      #
      # Unfortunately, on Microsoft Windows setting the file
      # modification time via utime() is problematic, because the zero
      # point depends on the timzone settings (at least it depends on
      # whether Daylight Savings Time is in effect when this code is
      # executed).
      #
      # The author of Image::ExifTool faced and overcame the same
      # problem, and using the resulting Image::ExifTool functionality
      # worked for me on Windows 10 but no longer on Windows 11.
      #
      # Then I found Win32::UTCFileTime, which allows overriding utime
      # with a version that hopefully works on Windows 11.

      my $cur_mt = -M $file;
      my $fmt = $new_info->get('FileModifyDate');
      my $success = $self->set_file_modification_time($file, $fmt->time_utc);

      if ($success) {
        my $new_mt = -M $file;
        if ($new_mt == $cur_mt) {
          log_message( 4, { name => $file },
                       sub { " Setting FileModifyDate of '$file' to '$fmt' FAILED\n" } );
          $success = 0;
        }
      }
      if ($success) {
        log_message( 4, { name => $file },
                    sub { " Set FileModifyDate of '$file' to '$fmt'\n" } );
        $changed += $success;
      } else {
        log_warn( " Error setting FileModifyDate of '$file' to '$fmt'\n");
      }
    } else {
      # TODO: don't report any changes for this file, either
    }
    $b->RestoreNewValues();     # return to clean slate
  }
  else {
    log_error(" Could not create backup file for '$file': not modified.\n");
    $status = 3;
  }
  return $status;
}

#   $et->modify_files;
#
# Makes another pass over all of the files of interest left over from
# the previous pass.  During this pass, the target timestamp for each
# file is applied to that file, if the 'modify' option is true.
sub modify_files {
  my ($self) = @_;
  return $self unless $self->option('modify');    # nothing to do
  my $totalsize = 0;
  my @files     = grep {
    my $n = $self->{extra_info}->{$_}->get('needs_modification');
    $totalsize += -s $_ if $n;
    $n;
  } keys %{ $self->{extra_info} };
  return $self unless @files;

  @files = sort @files;

  if (@files) {
    my $count_modified = 0;

    my $progressbar = $self->setup_progressbar( $totalsize, 'Modify' );

    foreach my $file (@files) {
      my $ok = $self->modify_file($file);
      $progressbar->add( -s $file );
      ++$count_modified if $ok;
    }
    $self->cleanup_progressbar($progressbar);
    if ($count_modified) {
      log_message("$count_modified file(s) changed.\n");
    }
    $self->cleanup_progressbar($progressbar);
  }
  return $self;
}

#   $value = $ims->option($name);
#   $value = $ims->option($name, $default);
#
# Retrieves the value of the option with the specified C<$name>.
# Accesses the options specified in the constructor and through
# L</set_option>.  If the option is not defined, then returns
# C<$default> if specified, and C<undef> otherwise.
sub option {
  my ( $self, $option, $default ) = @_;
  return $self->{options}->{$option} // $default;
}

sub parse_coordinate {
  my ($value) = @_;
  return unless defined $value;
  my $result;
  if ( looks_like_number($value) ) {
    $result = $value;
  }
  else {
    my @components;
    my $rest = $value;

    # may be signed
    my $sign = +1;
    if ( $rest =~ /^([-+])(.*)$/ ) {
      $sign = -1 if $1 eq '-';
      $rest = $2;
    }

    # a possibly fractional number at the end
    if ( $rest =~ /^(.*?)(\d+(?:\.\d+)?)\D*$/ ) {
      unshift @components, $2;
      $rest = $1;
    }
    else {    # not valid input
      return undef;
    }
    if ($rest) {
      unshift @components, split /\D+/, $rest;
    }
    $result = 0;
    while (@components) {
      my $next_component = pop(@components);
      next unless defined $next_component;
      $result = $result / 60 + $next_component;
    }
    $result *= $sign;
  }
  return $result;
}

# convert the path to Perl style
sub perlish_path {
  my ($path) = @_;
  return file($path)->as_foreign('Unix')->stringify;
}

#   %display_cameras = $ims->prepare_display_cameras;
#
# Determines a two-letter abbreviation for all of the camera IDs seen.
# The abbreviation consists of the first two characters of the camera
# ID, unless that conflicts with an abbreviation assigned earlier.
# Progressively more distant abbreviations are tried until one is
# found that isn't used yet.  If all else fails, then '**' is used, so
# that is the only abbreviation that might be assigned to multiple
# cameras.

sub prepare_display_cameras {
  my ($self) = @_;
  my %display_cameras;
  my %used;
  foreach my $camera ( sort keys %{ $self->{camera_ids} } ) {
    my $candidate = uc( substr( $camera, 0, 2 ) );
    $candidate .= ' ' x ( 2 - length($candidate) ) if length($candidate) < 2;
    if ( $used{$candidate} ) {    # try first letter with digit suffix
      my $prefix = uc( substr( $camera, 0, 1 ) );
      for my $i ( 0 .. 9 ) {
        $candidate = $prefix . $i;
        last unless $used{$candidate};
      }
    }
    if ( $used{$candidate} ) {   # try first letter with lowercase letter suffix
      my $prefix = uc( substr( $camera, 0, 1 ) );
      for my $a ( 'a' .. 'z' ) {
        $candidate = $prefix . $a;
        last unless $used{$candidate};
      }
    }
    if ( $used{$candidate} ) {   # try first letter with uppercase letter suffix
      my $prefix = uc( substr( $camera, 0, 1 ) );
      for my $a ( 'A' .. 'Z' ) {
        $candidate = $prefix . $a;
        last unless $used{$candidate};
      }
    }
    if ( $used{$candidate} ) {    # try any two lowercase letters
      $candidate = 'aa';
      do {
        last unless $used{$candidate};
        ++$candidate;
      } while length($candidate) == 2;
    }
    if ( $used{$candidate} ) {    # give up
      $candidate = '**';
    }
    $display_cameras{$camera} = $candidate;
    $used{$candidate}         = 1;
  }
  return %display_cameras;
}

sub process_gpx_track {
  my ( $self, $file ) = @_;
  my $gps_point_count;
  my $time_parse_problem_count;
  my $gpc = $self->gps_positions;
  my ( $mintime, $maxtime );
  my $track_count = 0;
  my $twig        = XML::Twig->new(
    twig_handlers => {
      trkseg => sub {
        my ( $twig, $section ) = @_;
        ++$track_count;
        my $id = "$file-$track_count";
        foreach my $point ( $section->children('trkpt') ) {
          my $lat  = $point->att('lat');
          my $lon  = $point->att('lon');
          my $time = $point->first_child_text('time');
          next unless $time;
          $time = Image::Synchronize::Timestamp->new($time);
          unless ( defined $time ) {
            ++$time_parse_problem_count;
            next;
          }
          $mintime = $time
            if not( defined $mintime )
            or $time < $mintime;
          $maxtime = $time
            if not( defined $maxtime )
            or $time > $maxtime;
          my $ele = $point->first_child_text('ele');
          ++$gps_point_count;
          $gpc->add( $time->time_utc, $lat, $lon, $ele, $id,
            scope_for_file($file) )
            if $time;
        }
      }
    }
  );
  log_message( 2, { name => $file }, "Reading '$file'.\n" );
  if ( $twig->safe_parsefile($file) ) {
    if ( defined $gps_point_count ) {
      log_message(
        2,
        { name => $file },
        sub {
          my $min           = $mintime->display_utc;
          my $max           = $maxtime->display_utc;
          my $common_prefix = common_prefix( '[-T]', $min, $max );
          $max =~ s/^\Q$common_prefix\E//;
          " Read $gps_point_count positions ($min/$max).\n";
        }
      );
    }
    log_message(
      "Could not parse $time_parse_problem_count times from GPX file '$file'\n"
    ) if defined $time_parse_problem_count;
    return 1;
  }
  else {
    # some error
    log_message("Problem parsing GPX tracks from $file: $@\n");
    return 0;
  }
}

sub process_summer_wintertime {
  my ($self) = @_;
  my %jumps = ( summertime => +1, wintertime => -1 );
  my @files = keys %{ $self->{original_info} };
  foreach my $jump ( keys %jumps ) {
    my $target = $self->option($jump);
    my $match;
    if ($target) {
      my @matches = identify_files( $target, @files );
      if (@matches) {
        $self->repository('jump')->{ $matches[0] } = $jumps{$jump};
      }
      else {
        croak "--$jump pattern matches no files.\n";
      }
    }
  }
  return $self;
}

# (FILE_END|TIMESTAMP(/TIMESTAMP)?)=CAMERAID
sub process_user_camera_ids {
  my ( $self, @files ) = @_;
  my $action_cref = sub {
    my ($rhs) = @_;

    # strip surrounding whitespace
    $rhs = $1 if $rhs =~ /^\s*(.*?)\s*$/;
    if ($rhs) {
      return $rhs;
    }
    else {
      log_warn("None or an empty camera ID was specified; ignored.\n");
      return;
    }
  };
  return $self->process_user_items( 'cameraid', 'user_camera_ids', $action_cref,
    @files );
}

#    t  a  r  g  e  t              =  s o u r c e
# (FILE_END|TIMESTAMP(/TIMESTAMP)?)=(LOCATION|FILE_END)
sub process_user_locations {
  my ($self) = @_;
  my $action_cref = sub {
    my ( $rhs, $file ) = @_;
    my @sources;
    if ($rhs) {
      @sources = identify_files( $rhs, keys %{ $self->{original_info} } );
      if ( @sources > 1 ) {
        log_warn("--location RHS '$rhs' matches more than one file; ignored.\n");
        return;
      }
      elsif ( @sources == 0 ) {    # is it a location?
        my ( $latitude, $longitude, $altitude ) = split /,/, $rhs;
        $latitude  = parse_coordinate($latitude);
        $longitude = parse_coordinate($longitude);
        if ( defined($latitude) and defined($longitude) ) {
          return [ $latitude, $longitude, add_maybe($altitude) ];
        }
      }
      if ( @sources == 1 ) {
        my $source_info = $self->{original_info}->{ $sources[0] };
        if ( defined $source_info ) {
          return [
                  $source_info->get('GPSLatitude'),
                  $source_info->get('GPSLongitude'),
                  add_maybe( $source_info->get('GPSAltitude') )
                ];
        }
      }
    } else {                    # empty rhs -- reset position
      return [];
    }
    log_warn("Could not resolve --location RHS '$rhs'.\n");
    return;
  };
  return $self->process_user_items( 'location', 'user_locations',
    $action_cref );
}

# (FILE_END|TIMESTAMP(/TIMESTAMP)?)=(TIME|OFFSET|FILE_END)
sub process_user_times {
  my ($self) = @_;
  my $action_cref = sub {
    my ( $rhs, $file, $info ) = @_;
    my $value;
    if ( looks_like_number($rhs) ) {    # offset in seconds
      my $createdate = $info->get('CreateDate');
      if ( defined $createdate ) {
        $value = $createdate->clone->adjust_to_local_timezone + $rhs;
      }
      else {
        # no CreateDate; cannot apply offset
        log_warn(
"Cannot apply --time offset for $file because it lacks an embedded CreateDate.\n"
        );
      }
    }
    elsif (
          $rhs
      and $rhs =~ /^
                              (?<sign>[-+])?
                              (?:(?<year>\d+)y)?
                              (?:(?<day>\d+)d)?
                              (?:(?<hour>\d+)h)?
                              (?:(?<minute>\d+)m)?
                              (?:(?<second>[\d.]+)s)?
                              $/x
      )
    {    # multi-unit offset
      # TODO: support timezone offset
      $value = ( $+{year} // 0 ) * 365;
      $value = ( $value + ( $+{day} // 0 ) ) * 24;
      $value = ( $value + ( $+{hour} // 0 ) ) * 60;
      $value = ( $value + ( $+{minute} // 0 ) ) * 60;
      $value += ( $+{second} // 0 );
      $value = -$value if ( $+{sign} // '+' ) eq '-';
      my $createdate = $info->get('CreateDate');
      if ( defined $createdate ) {
        $value = $createdate->clone->adjust_to_local_timezone + $value;
      }
      else {
        # no CreateDate; cannot apply offset
        log_warn(
"Cannot apply --time offset for $file because it lacks an embedded CreateDate.\n"
        );
      }
    }
    elsif ( $rhs =~ /^(\d+:\d+(?::\d+)?)$/ ) {    # clock time
      # TODO: support timezone offset
      my $createdate = $info->get('CreateDate');
      if ( defined $createdate ) {
        $value = Image::Synchronize::Timestamp->new( $rhs, $createdate );
      }
      else {
        # no CreateDate; cannot apply offset
        log_warn(
"Cannot apply --time clock time for $file because it lacks an embedded CreateDate.\n"
        );
      }
    }
    elsif ( $rhs =~ /^(\d+-\d+-\d+\D\d+:\d+(?::\d+)?)$/
            && defined($value = Image::Synchronize::Timestamp->new( $rhs )) ) {
      # clock date/time
    }
    else {                                        # path end
      my @files = keys %{ $self->{original_info} };
      @files = identify_files( $rhs, @files );
      if (@files) {
        if ( @files > 1 ) {
          croak "--time RHS value matched by multiple files: "
            . join( ', ', sort @files ) . "\n";
        }
        else {
          $value = $files[0];
          $value = $self->{original_info}->{$value}->get('DateTimeOriginal');
          croak "--time RHS file '$value' had no DateTimeOriginal.\n"
            unless defined $value;
        }
      }
      else {    # timestamp
        $value = Image::Synchronize::Timestamp->new($rhs);
        if ( defined $value ) {
          $value->adjust_to_local_timezone
            unless $value->has_timezone_offset;
        }
        else {
          log_error(
            "--time value $rhs does not have a valid format (for $file).\n");
        }
      }
    }
    return $value;
  };
  return $self->process_user_items( 'time', 'user_times', $action_cref );
}

# process the 'follow' option.
#
# Returns the object.
sub process_follow {
  my ( $self, @files ) = @_;
  my $count       = 0;
  my $action_cref = sub {
    my ($item) = @_;
    $self->{follow}->{$item} = 1;
    ++$count;
    return undef;    # don't need to remember anything else
  };
  $self->process_user_items( 'follow', undef, $action_cref, @files );
  if ($count) {
    default_logger()
      ->set_printer_condition( '', 'follow',
      sub { $_ && $self->{follow}->{ $_->{name} } } );
  }
  return $self;
}

#   $self->process_user_items($option, $repository, $action);
#
# Processes the structured value of a command-line option.
#
# C<$option> names the command-line option whose value to process.  The
# value identifies files and the data to associate with them.
#
# C<$repository> names the repository to which to append the results of
# processing the command-line option value.  The repository must be a
# hash, and is created if it does not yet exist.
#
# C<$action> is a CODE reference through which the command-line option
# value is processed.
#
# The value of command-line option C<$option> may be a HASH or an ARRAY
# reference.  The hash keys or array elements are scalars that identify
# the files with which to associate the results.
#
# The files to search through are those for which information has been
# gathered through L</inspect_files>.
#
# If any of those files have a path that ends with the hash key or array
# element, then those files are the targets for that hash key or array
# element.
#
# Otherwise, if the hash key or array element can be parsed as a
# timestamp (L<Image::Synchronize::Timestamp>) or time range
# (L<ImsyncTimerange>), then the files whose C<CreateDate> is equal to
# the timestamp or falls within the time range are the targets.
#
# If the value of the command-line option is a HASH reference, then
# the results are obtained through
#
#     $result = $action->($value, $file, $info);
#
# for each target C<$file>, with C<$value> the hash value and C<$info>
# the image information of the target file.
#
# If the value of the command-line option is an ARRAY reference, then
# the results are obtained through
#
#     $result = $action->($file, $info);
#
# for each target C<$file>.
#
# In both cases, if the C<$result> is defined, then it is stored in the
# repository hash as the value for the key equal to C<$file>.
#
# Returns C<$self>.
sub process_user_items {
  my ( $self, $option, $repository, $action, @files ) = @_;
  my $in_spec = $self->option($option);
  my $out_repository = $self->repository($repository) if defined $repository;
  if ($in_spec) {
    my @keys;
    if ( ref $in_spec eq 'HASH' ) {
      @keys = keys %{$in_spec};
    }
    elsif ( ref $in_spec eq 'ARRAY' ) {
      @keys = @{$in_spec};
    }
    else {
      croak "Argument should be array ref or hash ref but is '" . ref($in_spec)
        . "\n";
    }
    unless (@files) {
      @files = sort keys %{ $self->{original_info} };
    }
    foreach my $key (@keys) {

      # $key is FILE_END or TIMESTAMP or TIMESTAMP/TIMESTAMP.  First
      # see if the end of the path name of any file matches the key.
      my @targets = identify_files( $key, @files );
      unless (@targets) {

        # then check if the key is a timestamp or time range
        my $t;
        if ( $key =~ m|/| ) {
          $t = Image::Synchronize::Timerange->new($key);
        }
        else {
          $t = Image::Synchronize::Timestamp->new($key);
        }
        if ( defined $t ) {
          @targets = $self->find_info_targets($t);
        }
      }
      unless (@targets) {
        log_warn(
"Target '$key' does not match any of the specified files and does not look like a time instant or range; ignored.\n"
        );
        next;
      }
      foreach my $target (@targets) {
        my $rhs;
        if ( ref $in_spec eq 'HASH' ) {
          $rhs = $action->(
            $in_spec->{$key}, $target, $self->{original_info}->{$target}
          );
        }
        else {
          $rhs = $action->( $target, $self->{original_info}->{$target} );
        }
        if ( defined($out_repository) && defined($rhs) ) {
          $out_repository->{$target} = $rhs;
        }    # end if defined($out_repository) && defined($rhs)
      }    # end foreach my $target
    }    # end foreach my $key
  }    # end if $in_spec
  return $self;
}

sub read_gpx_tracks {
  my ($self) = @_;
  if ( $self->{gpx_total_size} ) {
    my $progressbar =
      $self->setup_progressbar( $self->{gpx_total_size}, 'GPX' );
    foreach my $file ( @{ $self->{gpx_tracks} } ) {
      $self->process_gpx_track($file);
      $progressbar->add( -s $file );
    }
    $self->cleanup_progressbar($progressbar);
  }
  return $self;
}

# remove the tags that this application added
sub remove_our_tags {
  my ( $self, @files ) = @_;

  my $b = $self->backend;
  my $progressbar =
    $self->setup_progressbar( scalar(@files), 'Remove Own Tags' );
  my $count = 0;
  foreach my $file (@files) {
    my $image_info = $self->get_image_info($file);
    if ( has_embedded_timestamp($image_info) ) {
      $b->ExtractInfo($file);
      $b->SaveNewValues();    # so we can return to a clean slate

      # We don't include XMP:DateTimeOriginal even though the current
      # application may have written it, because it might also have been
      # written by some other application.  We invented the following
      # tags, but not DateTimeOriginal.
      my @tags_to_remove = map { "XMP:$_" } @own_xmp_tags;

      # if TimeSource is not equal to GPS, then we can remove the GPS tags
      my $timesource = $image_info->get('TimeSource');
      if ( not( defined $timesource ) or $timesource ne 'GPS' ) {
        # GPSDateTime is in this list because Image::ExifTool writes
        # it in the XMP namespace when it writes GPSDateStamp and
        # GPSTimeStamp in the EXIF namespace
        push @tags_to_remove, qw(
          GPSAltitude
          GPSAltitudeRef
          GPSDateStamp
          GPSDateTime
          GPSLatitude
          GPSLatitudeRef
          GPSLongitude
          GPSLongitudeRef
          GPSTimeStamp
        );
      }

      my $changed = 0;
      foreach my $tag (@tags_to_remove) {
        {
          my $v = $b->GetValue($tag);
          next if not defined $v;
          next if ref($v) eq 'HASH' and not( scalar keys %{$v} );
          next if ref($v) eq 'ARRAY' and not( scalar @{$v} );
        }
        my ( $success, $error ) = $b->SetNewValue( $tag, undef );
        if ($success) {
          log_message(
            4,
            {
              name => $file
            },
            sub { "Removed $tag from '$file'\n"; }
          );
          $changed += $success;
        }
        else {
          log_warn(" Error removing $tag from '$file': $error\n");
        }
      }
      if ($changed) {

        # Also update the FileModifyDate (the file system modification
        # timestamp), because updating any embedded information changes
        # that timestamp to the current time.
        my $value = $image_info->get('FileModifyDate');
        $value = "$value";    # stringify
        my ( $success, $error ) =
          $b->SetNewValue( 'FileModifyDate', $value, Protected => 1 );
        if ($success) {
          log_message(
            4,
            {
              name => $file
            },
            sub { " Set FileModifyDate of '$file' to '$value'\n" }
          );
          $changed += $success;
        }
        else {
          log_warn(
            " Error setting FileModifyDate of '$file' to '$value': $error\n");
        }

        my $status = $b->WriteInfo($file);
        log_warn(" '$file' written but no changes made.\n") if $status == 2;
        if ( $status == 1 ) {
          my $warning = $b->GetValue('Warning');
          if ($warning) {

            # We suppress warnings about the FileName encoding not being
            # specified.  We don't invent or modify the byte values of the
            # file name, so the encoding should be unimportant as long as
            # Image::ExifTool doesn't modify any file name byte values,
            # either.
            my @warnings = split /\n/, $warning;
            @warnings = grep { !/FileName encoding not specified/ } @warnings;
            if (@warnings) {
              $warning = join( "\n", @warnings );
              log_warn(" Writing '$file' succeeded with warning: $warning\n");
            }
          }
          ++$count;
        }
        else {
          my $error = $b->GetValue('Error');
          log_warn(
            join( ', ',
              " Writing '$file' failed",
              ( $error ? "Error: $error" : () ) )
              . "\n"
          );
          $status = 4;
        }
      }
      $b->RestoreNewValues();    # return to clean slate
    }
    $progressbar->add;
  }
  log_message("Removed our own tags from $count file(s).\n");
  $self->cleanup_progressbar($progressbar);
  return $self;
}

# removes tags related to C<@tags> from C<$image_info>.
#
# Image::ExifTool::ImageInfo returns a hash map that may contain
# multiple keys for a requested tag, depending on how many instances
# of the requested information were included in the target file.  If
# there are multiple keys, then some or all of them end with a
# parenthesized index number.  This sub removes keys equal to the
# specified @tags, and also keys equal to the tag followed by a
# parenthesized index number.
sub remove_tag {
  my ( $image_info, @tags ) = @_;
  foreach my $tag (@tags) {
    delete $image_info->{$_}
      foreach grep /^\Q$tag\E(?: \(\d+\))?$/, keys %{$image_info};
  }
  return $image_info;
}

#   $ims->report;
#
# Prints a report about the processed files.  Returns C<$ims>.
sub report {
  my ($self) = @_;

  my $reportlevel = $self->option( 'reportlevel', 1 );
  return $self unless $reportlevel;

  my @report_these = keys %{ $self->{extra_info} };
  @report_these =
    grep { $self->{extra_info}->{$_}->get('needs_modification') } @report_these
    if $reportlevel == 1;
  return $self unless @report_these;

  my %display_cameras = $self->prepare_display_cameras;

  my $common_prefix_path;
  $common_prefix_path = common_prefix_path(@report_these);

  my $modify = $self->option('modify');
  my $modality = $modify ? '' : 'would be ';
  log_message(<<EOD);

REPORT:
 G: embedded GPS timestamp (UTC)
 E: embedded original timestamp
 O: other embedded tags
 M: file modification time
 P: embedded GPS position
 F: minimum --force for modification
  =: ${modality}unchanged
  *: ${modality}modified
  +: ${modality}added
  !: ${modality}removed
  -: absent

 Cm: camera code from following table
  Cm Camera ID
  --|-------------------------
EOD
  my %cameras = reverse %display_cameras;
  foreach my $id ( sort keys %cameras ) {
    my $name = $cameras{$id} eq '?' ? 'UNKNOWN' : $cameras{$id};
    log_message("  $id $name\n");
  }
  log_message("\n");
  log_message( <<EOD );
 M Offset source:
  g: embedded GPS timestamp
  s: embedded creation timestamp & other images
  o: embedded original timestamp
  c: embedded creation timestamp
  t: --time
  n: other file with same number

EOD

  log_message(
    sprintf(
      "GEOMPF Cm %-25s %-10s %-8s %s\n",
      'Target Time', 'M Offset', 'c Offset', 'File'
    )
  );
  log_message( '------|--|'
      . ( '-' x 25 ) . '|'
      . ( '-' x 10 ) . '|'
      . ( '-' x 8 ) . '|'
      . ( '-' x 8 )
      . "\n" );

  my $min_offset;
  my $max_offset;
  my $count_nonzero_offset = 0;
  foreach my $file (
    sort {
      timestamp_for_sorting( $self->{original_info}->{$a},
        $self->{new_info}->{$a} )
        <=> timestamp_for_sorting( $self->{original_info}->{$a},
        $self->{new_info}->{$b} )
        or ( $self->{original_info}->{$a}->get('image_number') // -1 )
        <=> ( $self->{original_info}->{$b}->get('image_number') // -1 )
    } @report_these
    )
  {
    my $info       = $self->{original_info}->{$file};
    my $new_info   = $self->{new_info}->{$file};
    my $extra_info = $self->{extra_info}->{$file};
    my $short;
    ( $short = $file ) =~ s/^(\Q$common_prefix_path\E)//o;
    $short =~ s{^\./}{};

    my $is_metainfo_file = $info->get('is_metadata');

    # G
    log_message( report_letter( 'GPSDateTime', $info, $new_info ) );

    # E
    log_message( report_letter( 'DateTimeOriginal', $info, $new_info ) );

    # O
    if ($is_metainfo_file) {
      log_message('=');
    } else {
      my @letters = map { report_letter( $_, $info, $new_info ) }
        ( 'XMP:DateTimeOriginal', map { "XMP:$_" } @own_xmp_tags );
      my $combined = $letters[0];
      foreach my $i ( 1 .. $#letters ) {
        if ( $letters[$i] ne $combined ) {
          if ( $combined eq '=' ) {
            $combined = $letters[$i];
          }
          else {
            $combined = '*';
          }
        }
      }
      log_message($combined);
    }

    # M
    log_message( report_letter( 'FileModifyDate', $info, $new_info ) );

    # P
    {
      my $letter;
      if ($extra_info->get('position_change')) {
        # position was present in old and new, and the new position is
        # sufficiently different that the difference shows up in the
        # EXIF tags
        $letter = '*';
      } else {
        # a position wasn't present in old or new, or it was present
        # in both and hasn't changed significantly.  The same then
        # goes for any one of the components.
        $letter = report_letter( 'GPSLatitude', $info, $new_info );
        if ($letter eq '*') {
          # the latitude is different but not by enough to show up in
          # the EXIF tag after writing.  Mark as the same.
          $letter = '=';
        }
      }
      log_message($letter);
    }

    {
      my $m = $extra_info->get('min_force_for_change');
      log_message( {}, $m < 99 ? $m : ' ' );
    }

    my $timestamp   = timestamp_for_sorting( $info, $new_info );
    my $new_fmd     = $new_info->get('FileModifyDate');
    my $time_change = $new_fmd - $info->get('FileModifyDate');
    if ( defined $timestamp ) {
      my $create_date = $new_info->get('CreateDate');
      my $camera_id   = $new_info->get('CameraID');
      $camera_id = $display_cameras{$camera_id} if defined $camera_id;
      log_message(
        sprintf(
          " %2s %-25.25s %1s %8s %8s %s\n",
          ( $camera_id // '' ),
          $timestamp->display_iso,
          $extra_info->get('timesource_letter') // ' ',
          display_offset( $time_change, 8 ),
          (
            defined($create_date)
            ? display_offset( $new_fmd - $create_date, 8 )
            : ' ' x 8
          ),
          $short
        )
      );
    }
    else {
      log_message(
        sprintf(
          " %2s %-25.25s %1s %8s %8s %s\n",
          display_camera( $new_info->get('CameraID') ),
          'unknown', '?', 'unknown', 'unknown', $short
        )
      );
    }
    if ($time_change) {
      ++$count_nonzero_offset;
      $min_offset = $time_change
        if not( defined $min_offset )
        or $time_change < $min_offset;
      $max_offset = $time_change
        if not( defined $max_offset )
        or $time_change > $max_offset;
    }
  }
  log_message("\n");
  $min_offset //= 0;
  $max_offset //= 0;
  if ( $min_offset == $max_offset ) {
    if ($min_offset) {    # not equal to zero
      log_message( "All $count_nonzero_offset non-zero offsets are equal to ",
        display_offset($min_offset), ".\n\n" );
    }
    else {
      log_message("All offsets are equal to 0 seconds.\n");
    }
  }
  else {
    log_message(
      "$count_nonzero_offset non-zero offsets are between ",
      display_offset($min_offset),
      " and ", display_offset($max_offset), ".\n"
    );
  }

  if ( $self->{max_gps_distance} ) {
    log_message(
      sub {
        my ( $value, $prefix ) = si_prefix( $self->{max_gps_distance} );
"Maximum shift of GPS position is $value ${prefix}m for $self->{max_gps_file}\n";
      }
    );
  }

  if ( $self->gps_offsets->camera_count ) {
    if ( $self->option( 'verbose', 1 ) & 16 ) {
      log_message(
        sub {
          "\nCamera Offsets:\n", Dump( $self->gps_offsets->to_display ), "\n";
        }
      );
    }
    else {
      log_message(
        sub {
          "\nCamera offsets for the time range:\n",
            Dump( $self->gps_offsets->relevant_part ),
            "\n";
        }
      );
    }
  }
  else {
    log_message("\nNo camera offsets are known.\n");
  }

  return $self;
}

sub report_letter {
  my ( $tag, $info, $new_info ) = @_;
  ( my $group, $tag ) = $tag =~ /^(?:(\w+):)?(\w+)$/;
  $group //= '';
  my $old = $info->get($tag);
  my $new = $new_info->get( $group, $tag );
  if ( defined $new ) {
    if ( defined $old ) {
      if ( $new ne $old ) {
        return '*';             # modified
      }
      else {
        return '=';    # unchanged
      }
    }
    else {             # new but not old
      return '+';      # added
    }
  }
  else {               # not new
    if ( defined $old ) {
      return '!';      # removed
    }
    else {
      return '-';      # absent
    }
  }
}

# report program and options
sub report_program_and_options {
  my ($self)       = @_;
  my $program_name = file($0)->basename;
  my %defaults     = (
    fastscan => 1,
    recurse  => 1,
  );
  my %no = map { $_ => 1 } qw(modify recurse);
  log_message(
    "Running $program_name " . join(
      ' ',
      grep { defined($_) } map( {
          my $key   = $_;
          my $value = $self->option($key);
          my $text;
          if ( ref $value eq 'HASH' ) {
            $text = "--$key "
              . join( " --$key ",
              map { "\"$_\"=\"$value->{$_}\"" } sort keys %{$value} );
          }
          elsif ( ref $value eq 'ARRAY' ) {
            $text = "--$key " . join( " --$key ", @{$value} );
          }
          elsif ( not( defined $defaults{$key} )
            || $value ne $defaults{$key} )
          {
            if ( $no{$key} ) {
              $text = '--' . ( $value ? '' : 'no-' ) . $key;
            }
            else {
              $text = "--$key";
              if ( looks_like_number($value) ) {
                if ( $value != 1 ) {
                  $text .= " $value";
                }
              }
              else {
                $text .=
                  ' ' . ( $value =~ /\s/ ? q(") . $value . q(") : $value );
              }
            }
          }
          $text;
        } grep !/^working-directory$/,
        sort keys %{ $self->{options} } ),
      map { /\s/ ? q(") . $_ . q(") : $_ } @ARGV
      )
      . "\n version $VERSION"
      . "\n in "
      . dir()->absolute . ".\n\n"
  );
  $self;
}

# returns a reference to the named repository, which gets created if
# it did not exist yet
sub repository {
  my ( $self, $name ) = @_;
  $self->{repository}->{$name} //= {};
  return $self->{repository}->{$name};
}

#   @files = resolve_files($rule, @items);
#   @files = resolve_files({ recurse => 0 }, $rule, @items); # don't recurse
#
# Resolves a list of path name patterns to a list of files.  C<$rule> is
# expected to be a L<Path::Iterator::Rule> that identifies files of
# interest.  C<@items> is a list of path name patterns or references to
# lists of path name patterns.  If the first argument is a hash
# reference, then it provides additional options.  The C<recurse> option
# says whether or not to recurse into subdirectories.  It defaults to 1,
# and can be set to 0 through this option.
#
# If an item is an existing directory, then the rule is applied to all
# of its elements, and the matching elements are appended to the list to
# be returned.
#
# If an item is an existing file, then it is appended to the list to be
# returned.
#
# Otherwise, the item is interpreted as a path name pattern, and files
# that match that pattern and also the rule are appended to the list to
# be returned.
sub resolve_files {
  my ( $options, $rule, @items );
  if ( ref $_[0] eq 'HASH' ) {
    ( $options, $rule, @items ) = @_;
  }
  else {
    ( $rule, @items ) = @_;
  }
  @items = map { ref($_) eq 'ARRAY' ? @{$_} : $_ } @items;
  return () unless @items;
  $options //= {};
  if ( not( $options->{recurse} ) ) {
    $rule = Path::Iterator::Rule->new
      ->max_depth(1)            # no recursion
      ->and($rule);
  }
  my @files;
  foreach my $item (@items) {
    my @extra;
    if ( -d $item ) {
      @extra = $rule->all($item);
      log_message("No matches for $item.\n") unless @extra;
    }
    elsif ( -f $item ) {
      my $f = file($item);
      @extra = ($f);
    }
    else {
      # the item was not found as a literal name; maybe it is a file
      # name pattern

      my $f = file($item);

      # seek directories matching the pattern
      my @subdirs =
        Path::Iterator::Rule->new
          ->max_depth(1)
          ->$PIRname( $f->basename )
          ->directory
          ->all( $f->parent );
      @extra = $rule->all(@subdirs) if @subdirs;

      # seek files matching the pattern
      push @extra,
        Path::Iterator::Rule->new
          ->max_depth(1)
          ->$PIRname( $f->basename )
          ->and( $rule )
          ->all( $f->parent );

      log_message("No matches for $item.\n") unless @extra;

      # remove initial './' because it makes later pattern matching
      # more difficult
      @extra = map { s|^./||; $_ } @extra;
    }
    push @files, @extra;
  }

  # remove duplicates, and convert to Perl-style paths
  my %files;
  $files{ perlish_path($_) } = 1 foreach @files;
  return sort keys %files;
}

# restore original files from backup files
sub restore_original_files {
  my ( $self, @arguments ) = @_;

  # restore original files
  my @files = resolve_files( { recurse => $self->option('recurse') },
    Path::Iterator::Rule->new->file->$PIRname('*_original'), @arguments );
  my $progressbar = $self->setup_progressbar( scalar(@files), 'restore' );
  my $count       = 0;
  my $exit_status = 0;
  foreach my $file (@files) {
    my $original;
    my $backup;
    if ( $file =~ /^(.*?)_original$/ ) {
      $original = $1;
      $backup   = $file;
    }
    else {
      $original = $file;
      $backup   = "${file}_original";
    }
    if ( -e $backup ) {
      if ( -e $original ) {
        log_message( 4, { name => $file }, "Removing '$original'.\n" );
        unlink($original);
      }
      else {
        log_message(
          4,
          { name => $file },
          "'$original' does not exist; no need to delete.\n"
        );
      }
      log_message( 4, { name => $file },
        "Renaming '$backup' to '$original'\n" );
      move( $backup, $original )
        or $self->log_message("Failed to restore '$original': $!\n");
    }
    else {
      log_message( 4,
        "Backup '$backup' does not exist; not restoring '$original'.\n" );
    }
    ++$count;
    $progressbar->add;
  }
  log_message("Done restoring $count original file(s).\n");
  $self->cleanup_progressbar($progressbar);
  $self;
}

sub scope_for_file {
  my ($file) = @_;
  my $scope = file($file)->dir->as_foreign('Unix')->stringify;
  $scope = '' if $scope eq '.';
  return $scope;
}

#   $ims->set_option($name, $value);
#   $ims->set_option($name);             # undefine
#
# Assigns the C<$value> to the option with the given C<$name>.  If the
# C<$value> is not defined or equal to C<undef>, then the option is
# removed.
#
# Returns C<$ims>.
sub set_option {
  my ( $self, $option, $value ) = @_;
  if ( defined $value ) {
    $self->{options}->{$option} = $value;
  }
  else {
    delete $self->{options}->{$option};
  }
  return $self;
}

# set_working_directory
#
#   $ims->set_working_directory;
#
# Sets the working directory based on the C<working-directory> option.
# Must be done before calling L</initialize_logging> because the log
# file by default is in the working directory.  So cannot make use of
# the logging.
#
# Returns C<$ims>.
sub set_working_directory {
  my ($self) = @_;
  my $wd = $self->option( 'workingdirectory', '.' );
  if ( $wd ne '.' ) {
    chdir($wd)
      or croak "Couldn't change to working directory '$wd': $@\n";
  }
  $self;
}

#  $progressbar = $ims->setup_progressbar($count, $title);
#
# Displays an Image::Synchronize::ProgressBar with the specified
# $title that shows progress toward the goal equal to $count.
# Progress messages are passed through the default
# Image::Synchronize::Logger.
sub setup_progressbar {
  my ( $self, $count, $title ) = @_;

  # We display a progress bar to show how far we are in processing all
  # files.
  my $progressbar = Image::Synchronize::ProgressBar->new(
    {
      count => $count,
      name  => $title,
    }
  );

  # Arrange for the progress bar to handle output of log messages to
  # screen, so those messages and the progress bar don't mess up each
  # other.
  default_logger()->set_printer(
    {
      bitflags => ( $self->option('verbose') // 1 ),
      action   => sub { $progressbar->message( join( '', @_ ) ); }
    }
  );
  log_message("Starting phase '$title'.\n");
  return $progressbar;
}

sub si_prefix {
  my ( $value, $significant ) = @_;
  $significant //= 3;
  my $sign;
  if ( $value < 0 ) {
    $sign  = -1;
    $value = -$value;
  }
  elsif ( $value > 0 ) {
    $sign = 1;
  }
  else {
    return wantarray ? ( 0, '' ) : 0;
  }
  my @prefixes = ( 'μ', 'm', '', 'k', 'M' );
  my $l = POSIX::floor( log($value) / log(1000) + 1 / 3 + 2 );
  $l = 0          if $l < 0;
  $l = $#prefixes if $l > $#prefixes;
  my $prefix  = $prefixes[$l];
  my $factor  = 10**( 3 * ( 2 - $l ) );
  my $numeral = sprintf( '%.*g', $significant, $sign * $value * $factor );
  return wantarray
    ? ( $numeral, $prefix )
    : $numeral . ( $prefix ? " $prefix" : '' );
}

sub stringify {
  my ($thing) = @_;
  return "$thing" if defined $thing;
  return '';
}

#  $timestamp = timestamp_for_sorting($info, $new_info);
#
# Returns the "best available" timestamp for sorting, based on
# information contained in $info and $new_info, which must have the
# expected format.  The order of preference is: (1) new
# FileModifyDate, (2) new DateTimeOriginal, (3) new GPSDateTime, (4)
# old FileModifyDate, (5) old DateTimeOriginal, (6) old GPSDateTime
sub timestamp_for_sorting {
  my ( $info, $new_info ) = @_;
  my @tags = qw(FileModifyDate DateTimeOriginal GPSDateTime);
  my $value;
  foreach my $tag (@tags) {
    $value = $new_info->get($tag);
    return $value if defined $value;
  }
  foreach my $tag (@tags) {
    $value = $info->get($tag);
    return $value if defined $value;
  }
  return;
}

#  $user_camera_id = $ims->user_camera_id($path);
#
# Returns the user-defined (through option C<camera>) camera ID for
# the file with the given C<$path>, or C<undef> if there isn't one.
sub user_camera_id {
  my ( $self, $path ) = @_;
  return $self->repository('user_camera_ids')->{$path};
}

# Calculates a file modification timestamp from a DateTimeOriginal.
#
# The file modification timestamp is expressed in the local timezone.
# If 'relativefiletime' is set, then the file modification timestamp
# has the same clock time as the DateTimeOriginal.  Otherwise, the
# file modification timestamp represents the same instant of universal
# time as the DateTimeOriginal.
sub file_from_dto {
  my ($self, $dto_timestamp) = @_;
  if ($self->option('relativefiletime')) {
    my $ltzo = $dto_timestamp->local_timezone_offset;
    return $dto_timestamp->clone->set_timezone_offset($ltzo);
  } else {
    return $dto_timestamp;
  }
}

sub normalize_options {
  my @args;
  foreach (@_) {
    if (my ($prefix, $opt, $suffix) = /^(-+)([-_\w]+)(.*)/) {
      $opt =~ tr/-_//d;
      push @args, "$prefix$opt$suffix";
    } else {
      push @args, $_;
    }
  }
  return @args;
}

1;

__END__


        # "Supposedly UTC" images may have a timezone that is
        # different from that of regular images taken by the same
        # camera, i.e., different from the nominal timezone of the
        # camera.  If --relativefiletime is used then the file
        # modification timestamp is the target time with its clock
        # time unchanged but its timezone part replaced by the
        # timezone appropriate for the current system at that moment.
        # The two kinds of images may then end up far apart in file
        # modification time even if they were recorded in close
        # succession.

        if ($info->get('supposedly_utc')) {
          # Let's try to find out what was the nominal timezone offset
          # of the camera at the time that this image was taken.

          my $nominal_camera_id = $new_info->get('CameraID') =~ s/\|U$//r;
          my $nominal_camera_timezone_offset =
            $self->gps_offsets->get( $nominal_camera_id,
                                     $new_info->get('CreateDate') );

          # The CreateDate was relative to the supposedly-UTC
          # timezone, but the offset retrieved just now was obtained
          # based on the assumption that the CreateDate was relative
          # to the nominal timezone, which may be some hours different
          # from the supposedly-UTC timezone, so the offset may have
          # been queried for a timestamp that was a few hours off.  If
          # the nominal timezone happened to change during those few
          # hours, then the retrieved nominal timezone may be wrong.
          # TODO: handle

          if (not($nominal_camera_timezone_offset
              ->has_timezone_offset)) {
            my ($q, $r) = split_number($nominal_camera_timezone_offset
                                       ->time_local, 3600);
            if ($r >= 1800) { # the offset is nearer the next higher
                              # hour than the current hour
              $r -= 3600;
              $q += 3600;
            }
            $nominal_camera_timezone_offset = Image::Synchronize::Timestamp
              ->new($r)
              ->adjust_timezone_offset($q)
              ->adjust_nodate;
          }

          $target_file_time
            ->adjust_timezone_offset($nominal_camera_timezone_offset
                                     ->timezone_offset);
        }

