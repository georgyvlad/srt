#!/usr/bin/perl -w

# This web-based tool is intended for combining several SRT (movie subtitles) files into one.
# The multiple files are chunks from one big movie and each one starts its timestamps from zero.
# Therefore, the tool allows the user to timeshift all the timestamps in the consequent files,
# so that the combined version has proper timestamps for the file as a whole. When all the time
# shifting is done, the user can export the resulting file and download it to his computer.
# The script keeps all its data in a data directory, which is by default the current directory
# where the script is running. If the directory doesn't exist, it will attempt to create it.
#
# Original author: Georgy Vladimirov
#
# The work is volunteered contribution to the Zeitgeist Movement (http://www.thezeitgeistmovement.com)
# It is Open Source and licenced as the Perl language itself (under the Artistic Licence and the
# GNU General Public Licence).

use strict;

use CGI;
use CGI::Carp qw(fatalsToBrowser);

use lib '.';
use SRT;

my $data_dir = 'data_tmshift/';
# once in so many requests (on average), we try to clean up
my $cleanup_request_freq = 100;
# range for random number used for automatic project name
my $project_random_range = 10_000;
# age for data files when they become deletable
my $max_datafile_age = ( 60 * 24 * 60 * 60 );	# 60 days ago
# length of text to display for a subtitle
my $subt_len = 30;

my $q = CGI->new;
my $p = $q->Vars;

my ($fn, $fh, @files, @tmshifts, @srts, $srt, $project);

my $encoding = $p->{'encoding'};
$encoding = 'utf8'  unless ( $encoding );		# 'iso-8859-1', 'utf8'

# make sure our data dir exists and try to create it otherwise
mkdir $data_dir  unless ( -d $data_dir );

# create an object of the module SRT, which does a lot of common functionality
my $so = SRT->new( $q, $encoding, $data_dir, $project_random_range, $max_datafile_age );

# once in a while, spend some time cleaning up
$so->cleanup_project_data_files()  if ( int( rand( $cleanup_request_freq ) ) == 1 );

# the export happens before we print the header, so it can print its own
if ( $p->{'step'} and $p->{'step'} eq 'export' )
{
	$project = $p->{'project'};
	$so->error( 'No project specified for the export.', 1 )  unless ( $project );

	&read_project_meta_file();

	&parse_all_files();

	&recalculate_file_timestamps();

	&export_final_project();

	exit;
}


print $q->header( -type => 'text/html', -charset => $encoding );
print $q->start_html( 'Zeitgeist Movement | SRT | tmshift' );


# user submits SRT file for the first time (project will be created)
if ( $p->{'step'} and $p->{'step'} eq 'upload_first' )
{
	&check_input_file();

	# automatically create project name/number the first time files are submitted
	$project = $so->get_new_project_name();

	# submit/copy SRT file on the server as number N, add it to metafile
	&submit_file();

	&print_nextfile_form();
}
# user submits next SRT file
elsif ( $p->{'step'} and $p->{'step'} eq 'upload_next' and $p->{'project'} )
{
	&check_input_file();

	$project = $p->{'project'};

	&read_project_meta_file();

	# submit/copy SRT file on the server as number N, add it to metafile
	&submit_file();

	&print_nextfile_form();
}
# user wants to view the timestamps and timeshifts
elsif ( $p->{'step'} and $p->{'step'} eq 'showtimes' and $p->{'project'} )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&parse_all_files();

	&recalculate_file_timestamps();

	&print_times_form();
}
# user submits his timeshift input
elsif ( $p->{'step'} and $p->{'step'} eq 'timeshift' and $p->{'project'} )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&parse_all_files();

	&save_user_timeshifts();

	&recalculate_file_timestamps();

	&print_times_form();
}
# view existing project - show screen for uploading next file
elsif ( $p->{'step'} and $p->{'step'} eq 'view_project' and $p->{'project'} )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&print_nextfile_form();
}
else
{
	&print_file_form();
}

print $q->end_html;


#----------------- SUBS -----------------

sub check_input_file
{
	$fh = $q->upload( 'file' );
	$fh = $so->cgi_to_file_handle( $fh )  if ( defined $fh );
	$so->error( "File can't be read." )  unless ( defined $fh );
	$fn = $p->{'file'};
	$fn =~ s/\n//g;
}

sub submit_file
{
	# remember the filename
	push @files, $p->{'file'};

	my $filenum = scalar @files;

	my $df = "${data_dir}${project}_file${filenum}.srt";
	my $dfh1;
	open( $dfh1, ">", $df )  or $so->error( "Can't save file${filenum}: $!\n" );

	# use the function not for the parsing but for the file copying
	$so->parse_file( \*$fh, $dfh1 );

	&save_project_meta_file();
}

sub parse_all_files
{
	@srts = ();

	for ( my $i = 1; $i <= @files; $i++ )
	{
		push @srts, &parse_file( $i );
	}
}

sub parse_file
{
	my ($filenum) = @_;

	my $df = "${data_dir}${project}_file${filenum}.srt";
	open( $fh, "<", $df )  or $so->error( "Can't open file${filenum}: $!\n" );

	return $so->parse_file( $fh );
}

sub save_project_meta_file
{
	my $mf = $so->meta_file_name( $project );
	my $mfh;
	open( $mfh, ">", $mf )  or $so->error( "Can't save project meta file: $!\n" );

	for ( my $i = 0; $i < @files; $i++ )
	{
		print $mfh "file=$files[$i]\n";

		# if we don't have a timeshift for this file, create a default zero timeshift
		my $tmshift = ( defined $tmshifts[$i] ) ? $tmshifts[$i] : '00:00:00,000';
		print $mfh "tmshift=$tmshift\n";
	}

	close $mfh;
}

sub read_project_meta_file
{
	@files = ();
	@tmshifts = ();

	my $mf = $so->meta_file_name( $project );
	$so->error( "Project ($project) does not exist.\n" )  unless ( -f $mf );

	my $mfh;
	open( $mfh, "<", $mf )  or $so->error( "Can't open project meta file: $!\n" );
	while ( <$mfh> )
	{
		push @files, $1     if ( /^file=(.*)$/ );
		push @tmshifts, $1  if ( /^tmshift=(.*)$/ );
	}
	close $mfh;
}

sub print_file_form
{
	print "<h1>The LingTeam Time Machine</h1>\n";
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
		<input type="hidden" name="step" value="upload_first">
	};
	print 'File: ', $q->filefield( 'file', '', 75, 200 ), "<br><br>\n";
	print "The SRT file you submit will automatically create a project that you can work on later.<br>
		The upload of the file may take some time depending on how big it is. You can then<br>
		upload the remaining SRT files that are part of the sequence. Once the files are<br>
		uploaded, they are saved on the server and viewing their timestamps is quick. Use the option<br>
		below for a project you have already started (files uploaded)<br><br>\n";
	print $q->submit( 'submit', 'Upload File' ), "<br><br>\n";
	print $q->end_form;

	print "--- OR ---<br><br>\n";

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
		<input type="hidden" name="step" value="view_project">
	};
	print 'Existing Project: ', $q->textfield( 'project', '', 75, 200 ), "<br><br>\n";
	print "If you enter a number here for an existing project, the file input above will be ignored.<br><br>\n";
	print $q->submit( 'submit', 'View Project' ), "<br><br>\n";
	print $q->end_form;
}

sub print_srt_files
{
	my $i = 1;

	foreach ( @files )
	{
		print "File$i: $_<br>\n";
		$i++;
	}
	print "<br>\n";
}

sub print_nextfile_form
{
	print $q->h1("The LingTeam Time Machine" ), "\n";
	print $q->h3( "Project: $project" );
	print $q->h4( "SRT files in project so far:" );
	&print_srt_files();

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
		<input type="hidden" name="step" value="upload_next">
		<input type="hidden" name="project" value="$project">
	};
	print 'File: ', $q->filefield( 'file', '', 75, 200 ), "<br><br>\n";
	print $q->submit( 'submit', 'Upload File' ), "<br><br>\n";
	print $q->end_form;

	print "Upload additional SRT files that are part of a sequence.<br><br>\n";
	print "<hr><br><br>";
	print "When you are finished uploading the SRT files, click 'Show Timestamps'.<br><br>\n";

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
		<input type="hidden" name="step" value="showtimes">
		<input type="hidden" name="project" value="$project">
	};
	print $q->submit( 'submit', 'Show Timestamps' ), "<br><br>\n";
	print $q->end_form;
}

sub print_times_form
{
	print $q->h1("The LingTeam Time Machine" ), "\n";
	print $q->h3( "Project: $project" );
	print $q->h4( "SRT files in project:" );
	&print_srt_files();

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
<input type="hidden" name="step" value="timeshift">
<input type="hidden" name="project" value="$project">

<table border="1" cellpadding="3">
<tr>
	<th>File</th>
	<th>Shift</th>
	<th>First Timestamp</th>
	<th>First Text</th>
	<th>Last Timestamp</th>
	<th>Last Text</th>
</tr>
	};

	my $i = 1;
	foreach $srt ( @srts )
	{
		my $start_txt = substr( $srt->[0]{'txt'}, 0, $subt_len );
		$start_txt .= '...' if ( length $srt->[0]{'txt'} > $subt_len );

		my $end_txt = substr( $srt->[-1]{'txt'}, 0, $subt_len );
		$end_txt .= '...' if ( length $srt->[-1]{'txt'} > $subt_len );

		my $tmshift_input = ( $i > 1 ) ?
			qq{ <input type="text" name="tmshift_$i" value="$tmshifts[$i-1]" size="12"> } :
			'&nbsp;';

		print qq{
<tr>
	<td>File$i</td>
	<td>$tmshift_input</td>
	<td>$srt->[0]{'t'}</td>
	<td>$start_txt</td>
	<td>$srt->[-1]{'t'}</td>
	<td>$end_txt</td>
</tr>
		};
		
		$i++;
	}

	print qq{
</table>
<br>
	};
	print $q->submit( 'submit', 'Shift Timestamps' ), "<br><br>\n";
	print "</form>\n";
	print "You have to enter the time shifts one by one (in order) and click the 'Shift Timestamps' button each time.<br>
		This will cause a recalculation and the file you time-shifted will be redisplayed.<br>
		Normally, you would probably take the last timestamp from the previous file and enter it as the time shift for the next file.<br>
		When you have time-shifted the last file (and clicked 'Shift Timestamp'), click the 'Export' button below.";

	# a separate form/button for export of the final version
	print "<br><hr><br>";
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{<input type="hidden" name="step" value="export">\n};
	print qq{<input type="hidden" name="project" value="$project">\n};
	print $q->submit( 'submit', 'Export' ), "<br><br>\n";
	print "</form>\n";
}

sub remove_whitespace
{
	return unless ( defined $_[0] );

	$_[0] =~ tr/ \n\t//d;
}

sub save_user_timeshifts
{
	# update timeshifts the user entered
	foreach my $param ( keys %$p )
	{
		# only look at the "version_*" radio buttons
		next  unless ( $param =~ /tmshift_(\d+)/ );
		my $i = $1 - 1;

		# timeshifts are valid for file2 and up to number of files
		next  unless ( $i > 0 and $i < @files );

		my $timeshift = $p->{ $param };
		&remove_whitespace( $timeshift );
		next unless ( $so->valid_timestamp( $timeshift ) );

		$tmshifts[$i] = $timeshift;
	}

	# save timeshifts in the meta file
	&save_project_meta_file();
}

# take the SRT's that are in memory and timeshift their timestamps
sub recalculate_file_timestamps
{
	# loop starting with the second SRT
	for ( my $i = 1; $i < @srts; $i++ )
	{
		my $ts = $tmshifts[ $i ];
		my $ts_num = $so->timestamp_as_num( $ts );

		# if we have a timeshift for this SRT (file), apply to all its subtitles
		if ( $ts_num > 0 )
		{
			# take each subtitle for this SRT (file) and timeshift its two timestamps
			foreach my $s ( @{ $srts[ $i ] } )
			{
				# the timestamp field holds two timestamps for the subtitle
				$s->{'t'} =  $so->shift_srt_timestamps( $s->{'t'}, $ts_num );
			}
		}
	}
}

sub export_final_project
{
	my $file_txt = '';
	# generate the order field afresh for the whole exported SRT file
	my $i = 1;

	# go over all the SRT files
	foreach $srt ( @srts )
	{
		# go over each subtitle
		foreach my $s ( @$srt )
		{
			# keep accumulating the file contents (instead of $s->{'c'}, use $i)
			$file_txt .= "$i\n$s->{'t'}\n$s->{'txt'}\n\n";
			$i++;
		}
	}

	my $filename = $files[0];
	if ( $filename =~ /\.srt$/i ) {
		$filename =~ s/\.srt/.exported.srt/i;
	} else {
		$filename .= '.exported.srt';
	}

	print $q->header(
		-type => 'text/plain',
		-charset => $encoding,
		-attachment => $filename
	);
	print $file_txt;
}
