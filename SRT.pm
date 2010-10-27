package SRT;

# This module contains some common parsing and web functionality to be used by tools that
# manipulate SRT (movie subtitles) files.
#
# Original author: Georgy Vladimirov
#
# The work is volunteered contribution to the Zeitgeist Movement (http://www.thezeitgeistmovement.com)
# It is Open Source and licenced as the Perl language itself (under the Artistic Licence and the
# GNU General Public Licence).

sub new
{
	my ($class, $q, $encoding, $data_dir, $project_random_range, $max_datafile_age) = @_;
	my $self = {
		'q'        => $q,
		'encoding' => $encoding,
		'data_dir' => $data_dir,
		'project_random_range' => $project_random_range,
		'max_datafile_age'     => $max_datafile_age
	};
	bless $self, ref $class || $class;
}

sub parse_file
{
	my ($self, $fh, $dfh) = @_;

	my @srt = ();
	my $c = undef;
	my $t = undef;
	my $txt = undef;
	my $started = 0;

	binmode $fh;
	# optional output filehandle to save the file as we read it
	binmode $dfh if ( defined $dfh );

	while ( my $line = <$fh> )
	{
		# special case for stripping out the weird characters in the beginning of the file
		$line =~ s/^\xEF\xBB\xBF//;

		# just pass onto the output file, if we have one
		print $dfh $line  if ( defined $dfh );

		chomp $line;

		# skip leading blank lines
		next if ( not $started and $line eq '' );

		# the counter field
		unless ( defined $c ) {
			$c = $line;
			$started = 1;
			next;
		}

		# the timeshift field
		unless ( defined $t ) {
			$t = $line;
			next;
		}

		# separator line, time to save the data
		if ( $started and $line eq '' )
		{
			$t = '' unless ( defined $t );
			$txt = '' unless ( defined $txt );

			push @srt, { 'c' => $c, 't' => $t, 'txt' => $txt };

			$c = $t = $txt = undef;
			$started = 0;
		}
		else
		{
			unless ( defined $txt ) {
				$txt = $line;
			} else {
				$txt .= "\n" . $line;
			}
		}
	}

	close $fh;
	close $dfh if ( defined $dfh );

	# save the last subtitle
	if ( defined $c and defined $t ) {
		push @srt, { 'c' => $c, 't' => $t, 'txt' => $txt };
	}

	return \@srt;
}

sub error
{
	my ($self, $msg, $header) = @_;
	my $q = $self->{'q'};

	print $q->header( -type => 'text/html', -charset => $self->{'encoding'} )  if ( $header );
	print "<strong> $msg <strong>";
	print $q->end_html;
	exit;
}


# this is just because of some old CGI.pm I have on my server
sub cgi_to_file_handle
{
	my ($self, $fh) = @_;

	eval "require IO::Handle" unless IO::Handle->can('new_from_fd');
	return IO::Handle->new_from_fd( fileno $fh, "<" );
}


# generate a unique name for a new project (use IP and a random number)
sub get_new_project_name
{
	my ($self) = @_;
	my ($project, $ip, $mf);
	my $tries = 20;

	$ip = $self->{'q'}->remote_addr;
	$ip =~ s/\.//g;

	# find a name that hasn't been taken already (metafile for such project doesn't exist)
	do {
		$project = $ip . int( rand( $self->{'project_random_range'} ) );
		$mf = $self->meta_file_name( $project );

		# wow, what are the chances - let's try to clean up
		$self->cleanup_project_data_files()  if ( -f $mf );
	}
	while ( -f $mf and $tries-- );

	$self->error( "Running out of project names, someone has to clean up the old ones." )
		if ( -f $mf );

	return $project;
}


sub meta_file_name
{
	my ($self, $project) = @_;
	return "$self->{data_dir}${project}_meta.txt";
}


sub cleanup_project_data_files
{
	my ($self) = @_;
	my $cutoff_time = time() - $self->{'max_datafile_age'};
	my $data_dir = $self->{'data_dir'};

	my @data_files =
		map { { 'fn' => $_, 'mtime' => (stat)[9] } }
		glob( "$data_dir*" );

	# first, grab all datafiles that date before the cutoff time
	my @delete_files = grep { $_->{'mtime'} < $cutoff_time } @data_files;

	my %projects = ();

	# then, check the project names that are involved
	foreach my $fn ( map { $_->{'fn'} } @delete_files )
	{
		# look for project name in the filename and remember it
		if ( $fn =~ /^$data_dir(\d+)_/ )
		{
			$projects{ $1 } = 1  unless ( exists $projects{ $1 } );
		}
	}

	# now, grab all datafiles for the projects that had any old datafiles
	@delete_files = grep { $_->{'fn'} =~ /^$data_dir(\d+)_/ and exists $projects{ $1 } } @data_files;

	# delete all projects (their datafiles) that had some old datafiles
	unlink map { $_->{'fn'} } @delete_files;
}

sub timestamp_as_num
{
	my ($self, $timestamp) = @_;
	my $num = undef;

	if ( $timestamp =~ /^(\d+):(\d\d):(\d\d),(\d\d\d)$/ )
	{
		$num =
			$1 * 60 * 60 * 1000 +
			$2 * 60 * 1000 +
			$3 * 1000 +
			$4;
	}

	return $num;
}

sub num_as_timestamp
{
	my ($self, $num) = @_;

	return undef  unless ( defined $num );
	return "00:00:00,000"  if ( $num == 0 );

	my $hours = int( $num / (60 * 60 * 1000) );
	$num -= $hours * (60 * 60 * 1000);
	my $mins = int( $num / (60 * 1000) );
	$num -= $mins * (60 * 1000);
	my $secs = int( $num / 1000 );
	$num -= $secs * 1000;
	my $mils = $num;

	return sprintf( "%02d:%02d:%02d,%03d", $hours, $mins, $secs, $mils);
}

sub valid_timestamp
{
	my ($self, $timestamp) = @_;
	my $num = $self->timestamp_as_num( $timestamp );
	return ( defined $num ) ? 1 : 0;
}

# takes a SRT timestamp field (with two timestamps in it) and shifts both of them
sub shift_srt_timestamps
{
	my ($self, $t, $s) = @_;

	my ( $t1, $t2 ) = $self->get_start_end( $t );

	if ( defined $t1 and defined $t2 )
	{
		my $t1_num = $self->timestamp_as_num( $t1 );
		my $t2_num = $self->timestamp_as_num( $t2 );

		if ( defined $t1_num ) {
			$t1_num += $s;
			$t1 = $self->num_as_timestamp( $t1_num );
		}

		if ( defined $t2_num ) {
			$t2_num += $s;
			$t2 = $self->num_as_timestamp( $t2_num );
		}

		return "$t1 --> $t2";
	}
	else
	{
		return $t;
	}
}

# takes a SRT timestamp and returns the start and end timestamps within it
sub get_start_end
{
	my ($self, $t) = @_;
	my $t1 = undef;
	my $t2 = undef;

	if ( $t =~ /^(.*) --> (.*)$/ )
	{
		( $t1, $t2 ) = ( $1, $2 );
	}

	return ( $t1, $t2 );
}

# takes a reference to an array of srts and renumbers them starting from 1
sub renumber_srts_order
{
	my ($self, $srts) = @_;

	for ( my $i = 0; $i < @$srts; $i++ )
	{
		$srts->[$i]{'c'} = $i + 1;
	}
}


1;
