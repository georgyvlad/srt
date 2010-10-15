#!/usr/bin/perl -w

# This web-based tool is intended for merging two SRT (movie subtitles) files that are very similar.
# The files are usually two versions of the same video (timestamps are identical) with very small
# differences. The user can see these diffs and pick the subtitle version from either SRT file or
# even enter a custom subtitle text instead of either version. At the end, the user can export the
# resulting merged version and download it to his computer.
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

my $data_dir = 'data_diff/';
# once in so many requests (on average), we try to clean up
my $cleanup_request_freq = 100;
# range for random number used for automatic project name
my $project_random_range = 10_000;
# age for data files when they become deletable
my $max_datafile_age = ( 60 * 24 * 60 * 60 );	# 60 days ago

my $q = CGI->new;
my $p = $q->Vars;

my ($fh1, $fh2, $fn1, $fn2, $srt1, $srt2, %srtm, $project);

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

	&read_project_master_file();

	&parse_files();

	&export_final_project();

	exit;
}


print $q->header( -type => 'text/html', -charset => $encoding );
print $q->start_html( 'Zeitgeist Movement | SRT | diff' );

# user submits his merge input
if ( $p->{'step'} and $p->{'step'} eq 'merge' )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&read_project_master_file();

	&parse_files();

	&merge_files();

	&save_project_master_file();

	# read the master file we just saved, so we can print the merge form with new values
	&read_project_master_file();

	&print_merge_form();
}
# user wants to work on existing project
elsif ( $p->{'project'} )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&read_project_master_file();

	&parse_files();

	&print_merge_form();
}
# user submits SRT files for the first time (project will be created)
elsif ( $p->{'file1'} )
{
	&check_input_files();

	# automatically create project name/number the first time files are submitted
	$project = $so->get_new_project_name();

	&submit_and_parse_files( $project );

	&print_merge_form();
}
else
{
	&print_file_form();
}

print $q->end_html;


#----------------- SUBS -----------------

sub check_input_files
{
	$fh1 = $q->upload( 'file1' );
	$fh1 = $so->cgi_to_file_handle( $fh1 )  if ( defined $fh1 );
	$so->error( "File1 can't be read." )  unless ( defined $fh1 );
	$fn1 = $p->{'file1'};
	$fn1 =~ s/\n//g;

	$fh2 = $q->upload( 'file2' );
	$fh2 = $so->cgi_to_file_handle( $fh2 )  if ( defined $fh2 );
	$so->error( "File2 can't be read." )  unless ( defined $fh2 );
	$fn2 = $p->{'file2'};
	$fn2 =~ s/\n//g;
}

sub submit_and_parse_files
{
	my $df1 = "${data_dir}${project}_file1.srt";
	my $dfh1;
	open( $dfh1, ">", $df1 )  or $so->error( "Can't save file1: $!\n" );
	my $df2 = "${data_dir}${project}_file2.srt";
	my $dfh2;
	open( $dfh2, ">", $df2 )  or $so->error( "Can't save file2: $!\n" );

	$srt1 = $so->parse_file( \*$fh1, $dfh1 );
	$srt2 = $so->parse_file( \*$fh2, $dfh2 );

	&save_project_meta_file();
}

sub parse_files
{
	my $df1 = "${data_dir}${project}_file1.srt";
	open( $fh1, "<", $df1 )  or $so->error( "Can't open file1: $!\n" );
	my $df2 = "${data_dir}${project}_file2.srt";
	open( $fh2, "<", $df2 )  or $so->error( "Can't open file2: $!\n" );

	$srt1 = $so->parse_file( $fh1 );
	$srt2 = $so->parse_file( $fh2 );
}

sub save_project_meta_file
{
	my $mf = $so->meta_file_name( $project );
	my $mfh;
	open( $mfh, ">", $mf )  or $so->error( "Can't save project meta file: $!\n" );
	print $mfh "file1=$fn1\n", "file2=$fn2\n";
	close $mfh;
}

sub read_project_meta_file
{
	my $mf = $so->meta_file_name( $project );
	$so->error( "Project ($project) does not exist.\n" )  unless ( -f $mf );

	my $mfh;
	open( $mfh, "<", $mf )  or $so->error( "Can't open project meta file: $!\n" );
	$fn1 = <$mfh>;
	$fn1 = $1  if ( $fn1 =~ /^file1=(.*)/m );
	$fn2 = <$mfh>;
	$fn2 = $1  if ( $fn2 =~ /^file2=(.*)/m );
	close $mfh;
}

sub merge_files
{
	# save the user choices in the master file
	foreach my $param ( keys %$p )
	{
		# only look at the "version_*" radio buttons
		next  unless ( $param =~ /version_(\d+)/ );

		# this is the "order" field for the subtitle
		my $sorder = $1;

		# choice is not to merge yet (or anymore, in case a choice was previously made)
		if ( $p->{ $param } eq '4' )
		{
			# wipe out any previous choice for this subtitle in the master file
			delete $srtm{ $sorder };
			next;
		}

		# create or overwrite the record in our master hash
		$srtm{ $sorder } = {};

		my $s = $srtm{ $sorder };

		# choice is the subtitle from file1
		if ( $p->{ $param } eq '1' )
		{
			$s->{'c'} = $sorder;
			$s->{'merge'} = 'file1';
			$s->{'t'} = 'file1';
			$s->{'txt'} = 'file1';
		}
		# choice is the subtitle from file2
		elsif ( $p->{ $param } eq '2' )
		{
			$s->{'c'} = $sorder;
			$s->{'merge'} = 'file2';
			$s->{'t'} = 'file2';
			$s->{'txt'} = 'file2';
		}
		# choice is a custom subtitle value from the user
		elsif ( $p->{ $param } eq '3' )
		{
			$s->{'c'} = $sorder;
			$s->{'merge'} = 'custom';
			$s->{'t'} = 'custom';		# maybe in the future we can have the user enter this

			my $custom = $p->{"custom_$sorder"};
			$custom = ''  unless ( defined $custom );
			$s->{'txt'} = $custom;
		}
	}
}

sub save_project_master_file
{
	my $mf = "${data_dir}${project}_master.srt";
	my $mfh;

	# don't create master file unless we have merge choices for it
	return unless ( keys %srtm > 0 );

	open( $mfh, ">", $mf )  or $so->error( "Can't save project master file: $!\n" );

	# for each subtitle - hack the merge choice into the "order" field and save to file
	# (keep our master file sorted by the "order" field)
	foreach ( sort { $a <=> $b } keys %srtm )
	{
		# get the subtitle record from the master hash
		my $s = $srtm{ $_ };

		# modify the "order" column to hold our merge choice
		$s->{'c'} = $s->{'c'} . '-' . $s->{'merge'}  if ( exists $s->{'merge'} );

		print $mfh "$s->{'c'}\n$s->{'t'}\n$s->{'txt'}\n\n";
	}
	close $mfh;
}

sub read_project_master_file
{
	my $mf = "${data_dir}${project}_master.srt";
	my $mfh;

	# initialize the master hash
	%srtm = ();

	# check for existence of the file, maybe there isn't one yet
	return  unless ( -f $mf );

	open( $mfh, "<", $mf )  or $so->error( "Can't open project master file: $!" );
	my $srtm = $so->parse_file( $mfh );

	# our master file has the "order" field modified to hold the merge choice
	foreach my $s ( @$srtm )
	{
		# modified field (we should only have these)
		if ( $s->{'c'} =~ m/(\d+)-(.*)/ )
		{
			$s->{'merge'} = $2;
			$s->{'c'} = $1;
		}
	}

	# convert the array of subtitles into a hash (with the "order" field as the key)
	%srtm = map { ( $_->{'c'} => $_ ) } @$srtm;
}

sub print_file_form
{
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print 'File1: ', $q->filefield( 'file1', '', 75, 200 ), "<br><br>\n";
	print 'File2: ', $q->filefield( 'file2', '', 75, 200 ), "<br><br>\n";
	print "The two files you submit will automatically create a project that you can work on later.<br>
		The upload of the file may take some time depending on how big they are. Once the files are<br>
		uploaded, they are saved on the server and viewing their diffs is much quicker. Use the option<br>
		below for a project you have already started (files uploaded)<br><br>\n";
	print $q->submit( 'submit', 'Upload Files and View Diffs' ), "<br><br>\n";
	print $q->end_form;

	print "--- OR ---<br><br>\n";

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print 'Existing Project: ', $q->textfield( 'project', '', 75, 200 ), "<br><br>\n";
	print "If you enter a number here for an existing project, the file inputs above will be ignored.<br><br>\n";
	print $q->submit( 'submit', 'View Diffs' ), "<br><br>\n";
	print $q->end_form;
}

sub print_merge_form
{
	# see which button the user clicked (so we can take him there again)
	my $button = $p->{'button'};

	# if we have a clicked 'Merge' button, print a little JavaScript to send us there
	if ( defined $button and $button > 0 )
	{
		print <<"END";
<script type="text/javascript">
	function goToAnchor() {
		location.href = "#button_$button";
	}
</script>

<body onload="goToAnchor();">
END
	}
	else {
		print "<body>\n";
	}

	print $q->h3( "Project: $project" );
	print $q->h4( "SRT files in project:" );
	print qq{
		<b>File1:</b> $fn1<br>
		<b>File2:</b> $fn2<br><br>
		In the diffs below, you can pick the version of the subtitle from File1, File2, enter a custom value<br>
		or choose not to pick a version yet (no merge yet). Then, you click any 'Merge' button. You should<br>
		click 'Merge' often (even before completely finished) because that is when your choices get saved.<br><br>
	};
	print $q->h4( "Diffs:" );

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
		<input type="hidden" name="step" value="merge">
		<input type="hidden" name="project" value="$project">
		<input type="hidden" name="button" value="0">
		<table>
	};

	# display a 'Merge' button on top
	print &merge_button( 0, $button );

	# counter for the differing srt's only
	my $d = 0;

	foreach ( my $i = 0; $i < @$srt1; $i++ )
	{
		# show only the subtitles that differ in their text
		if ( $srt1->[$i]{'txt'} ne $srt2->[$i]{'txt'} )
		{
			$d++;

			# we always take value for the "order" field from the first file
			my $sorder = $srt1->[$i]{'c'};

			# see whether we have a record for this subtitle in the master hash
			my $m = $srtm{ $sorder };

			my $file1_checked = ( $m and $m->{'merge'} eq 'file1' ) ? 'checked' : '';
			my $file2_checked = ( $m and $m->{'merge'} eq 'file2' ) ? 'checked' : '';
			my $custom_checked = ( $m and $m->{'merge'} eq 'custom' ) ? 'checked' : '';
			my $donotmerge_checked = '';
			$donotmerge_checked = 'checked' unless ( $file1_checked or $file2_checked or $custom_checked );
			my $custom = ( $custom_checked ) ? $m->{'txt'} : '';

			print <<"EOF";
<tr>
	<td rowspan="4">$sorder</td>
	<td><input type="radio" name="version_$sorder" value="1" $file1_checked></td>
	<td>File1: </td>
	<td><pre>|$srt1->[$i]{'txt'}|</pre></td>
</tr>
<tr>
	<td><input type="radio" name="version_$sorder" value="2" $file2_checked></td>
	<td>File2: </td>
	<td><pre>|$srt2->[$i]{'txt'}|</pre></td>
</tr>
<tr>
	<td><input type="radio" name="version_$sorder" value="3" $custom_checked></td>
	<td>Custom: </td>
	<td><input type="text" name="custom_$sorder" value="$custom" size="80"></td>
</tr>
<tr>
	<td><input type="radio" name="version_$sorder" value="4" $donotmerge_checked></td>
	<td nowrap>No merge yet</td>
	<td>&nbsp;</td>
</tr>
<tr><td colspan="4"><hr></td></tr>
EOF

			# display a 'Merge' button every four rows for convenience
			print &merge_button( $d, $button )  if ( $d % 4 == 0 );

		}
	}

	# print 'Merge' button on the bottom (but avoid two of them back to back)
	print &merge_button( $d, $button )  unless ( $d % 4 == 0 );

	print "</table>\n";
	print $q->end_form;

	# a separate form/button for export of the final version
	print "<br><hr><br>";
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{<input type="hidden" name="step" value="export">\n};
	print qq{<input type="hidden" name="project" value="$project">\n};
	print $q->submit( 'submit', 'Export' ), "<br><br>\n";
	print $q->end_form;
	print "</body>\n"
}

# create string for merge button, an anchor to it (if clicked) and settting the 'button' hidden input to it
sub merge_button
{
	my ($button, $clicked) = @_;

	# create an anchor only if this button was clicked
	my $anchor = ( defined $clicked and $button == $clicked ) ? qq|<a name="button_$button"></a>| : '';

	return <<"EOF";
<tr><td colspan="4">$anchor
	<input type="submit" value="Merge" onclick="this.form.button.value = $button;">
</td></tr>
EOF

}

sub export_final_project
{
	my $file_txt = '';
	my $s;

	# go over each subtitle
	foreach ( my $i = 0; $i < @$srt1; $i++ )
	{
		# if subtitles differ in their text, look at the record in the master hash
		if ( $srt1->[$i]{'txt'} ne $srt2->[$i]{'txt'} )
		{
			# we always take value for the "order" field from the first file
			$s = $srt1->[$i];
			my $sorder = $s->{'c'};

			# see whether we have a record for this subtitle in the master hash
			my $m = $srtm{ $sorder };
			$so->error( "All diffs have to be merged before you can export.", 1 )
				unless ( $m );

			# use file1
			if ( $m->{'merge'} eq 'file1' )
			{
				# we alredy set $s to have file1 value by default
			}
			# use file2
			elsif ( $m->{'merge'} eq 'file2' )
			{
				$s = $srt2->[$i];
			}
			# custom value, timestamp and order stay the same as of file1
			elsif ( $m->{'merge'} eq 'custom' )
			{
				$s->{'txt'} = $m->{'txt'};
			}
			else {
				$so->error( "Bad value ($m->{'merge'}) in project master file for subtitle: $sorder.", 1 )
			}
		}
		# if they are identical, take the one from file1
		else
		{
			$s = $srt1->[$i];
		}

		# keep accumulating the file contents
		$file_txt .= "$s->{'c'}\n$s->{'t'}\n$s->{'txt'}\n\n";
	}

	print $q->header(
		-type => 'text/plain',
		-charset => $encoding,
		-attachment => $fn1
	);
	print $file_txt;
}
