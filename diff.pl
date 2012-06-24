#!/usr/bin/perl -w

# This web-based tool is intended for merging two SRT (movie subtitles) files that are very similar.
# The files are usually two versions of the same video (timestamps are identical) with very small
# differences. The user can see these diffs and pick the subtitle version from either SRT file or
# even enter a custom subtitle text instead of either version. At the end, the user can export the
# resulting merged version and download it to his computer. There is an option for adding a third
# SRT file that has the subtitles in the original (English) language. If you provide such a file,
# you will see the original subtitle text above each file1/file2 subtitle diff.
#
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

my ($fh1, $fh2, $fh3, $fn1, $fn2, $fn3, $srt1, $srt2, $srt3, %srt3, %srtm, $project);
%srt3 = ();

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

&print_header();


# user wants to submit an optional third file
if ( $p->{'step'} and $p->{'step'} eq 'file3form' )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&print_file3_form();
}
# user submitted an optional third file
elsif ( $p->{'step'} and $p->{'step'} eq 'submitfile3' )
{
	$project = $p->{'project'};

	&read_project_meta_file();

	&submit_file3();

	&read_project_master_file();

	&parse_files();

	&print_merge_form();
}
# user submits his merge input
elsif ( $p->{'step'} and $p->{'step'} eq 'merge' )
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
# user wants to see his other projects
elsif ( $p->{'step'} and $p->{'step'} eq 'myprojects' )
{
	&print_user_projects();
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

	# check file3 but as optional
	&check_input_file3( 1 );
}

sub check_input_file3
{
	my ($optional) = @_;

	# third file is optional check it only if one was submitted
	$fn3 = $p->{'file3'};
	$fn3 = ''  unless ( defined $fn3 );
	$fn3 =~ s/\n//g;
	return if ( $optional and not $fn3 );

	$fh3 = $q->upload( 'file3' );
	$fh3 = $so->cgi_to_file_handle( $fh3 )  if ( defined $fh3 );
	$so->error( "File3 can't be read." )  unless ( defined $fh3 );
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
	&equalize_arrays();

	# file3 is optional
	if ( $fn3 )
	{
		my $df3 = "${data_dir}${project}_file3.srt";
		my $dfh3;
		open( $dfh3, ">", $df3 )  or $so->error( "Can't save file3: $!\n" );
		$srt3 = $so->parse_file( \*$fh3, $dfh3 );
		# convert the array of subtitles into a hash (with the "order" field as the key)
		%srt3 = map { ( $_->{'c'} => $_ ) } @$srt3;
	}

	&save_project_meta_file();
}

sub submit_file3
{
	&check_input_file3();

	my $df3 = "${data_dir}${project}_file3.srt";
	my $dfh3;
	open( $dfh3, ">", $df3 )  or $so->error( "Can't save file3: $!\n" );
	# use the parse_file just to copy and save file3
	$srt3 = $so->parse_file( \*$fh3, $dfh3 );

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
	&equalize_arrays();

	if ( $fn3 )
	{
		my $df3 = "${data_dir}${project}_file3.srt";
		open( $fh3, "<", $df3 )  or $so->error( "Can't open file3: $!\n" );
		$srt3 = $so->parse_file( $fh3 );
		# convert the array of subtitles into a hash (with the "order" field as the key)
		%srt3 = map { ( $_->{'c'} => $_ ) } @$srt3;
	}
}

# the two srt arrays should always be equal (we equalize them here)
sub equalize_arrays
{
	return unless ( defined $srt1 and defined $srt2 );

	my $cnt1 = scalar @$srt1;
	my $cnt2 = scalar @$srt2;
	return if ( $cnt1 == $cnt2 );

	my $cnt = ( $cnt1 > $cnt2 ) ? $cnt1 : $cnt2;
	for ( my $i = 0; $i < $cnt; $i++ )
	{
		push @$srt1, { 'c' => $srt2->[$i]{'c'}, 't' => $srt2->[$i]{'t'}, 'txt' => '' }  if ( $i >= $cnt1 );
		push @$srt2, { 'c' => $srt1->[$i]{'c'}, 't' => $srt1->[$i]{'t'}, 'txt' => '' }  if ( $i >= $cnt2 );
	}
}

sub save_project_meta_file
{
	my $mf = $so->meta_file_name( $project );
	my $mfh;
	open( $mfh, ">", $mf )  or $so->error( "Can't save project meta file: $!\n" );
	print $mfh "file1=$fn1\n", "file2=$fn2\n";
	print $mfh "file3=$fn3\n"  if ( $fn3 );
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
	$fn3 = <$mfh>;
	$fn3 = ''  unless ( defined $fn3 );
	$fn3 = $1  if ( $fn3 =~ /^file3=(.*)/m );
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
			$so->trim( $custom );
			&strip_end_pipes( $custom );
			$custom = ''  unless ( defined $custom );
			$s->{'txt'} = $custom;
		}
	}
}

# some users don't remove the visual pipes we display (to show leading and trailing space)
# this sub will remove them
sub strip_end_pipes
{
   return unless ( defined $_[0] );

   $_[0] =~ s/^\|+|\|+$//gs;
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
	&print_tool_header();
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	# default to showing a maximum of 25 diffs at a time
	print '<input type="hidden" name="max_diffs" value="25">', "\n";
	print 'File1: ', $q->filefield( 'file1', '', 75, 200 ), " &nbsp;(Reference SRT)<br><br>\n";
	print 'File2: ', $q->filefield( 'file2', '', 75, 200 ), "<br><br>\n";
	print 'File3: ', $q->filefield( 'file3', '', 75, 200 ), " &nbsp;(optional - English/original SRT)<br><br>\n";
	print "The two files you submit will automatically create a project that you can work on later.<br>
		The third file (optional) is the original (English) SRT, if you provide one you will see the<br>
		original/English subtitle above the file1/file2 (translated) subtitles.
		The upload of the files may take some time depending on how big they are. Once the files are<br>
		uploaded, they are saved on the server and viewing their diffs is much quicker. Use the option<br>
		below for a project you have already started (files uploaded)<br><br>\n";
	print $q->submit( 'submit', 'Upload Files and View Diffs' ), "<br><br>\n";
	print $q->end_form;

	print "--- OR ---<br><br>\n";

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print 'Existing Project: ', $q->textfield( 'project', '', 75, 200 ), "<br><br>\n";
	print "If you enter a number here for an existing project, the file inputs above will be ignored.<br><br>\n";
	# default to hiding the diffs that already have merge choices
	print '<input type="hidden" name="hide_merged" value="1">', "\n";
	# default to showing a maximum of 25 diffs at a time
	print '<input type="hidden" name="max_diffs" value="25">', "\n";
	print $q->submit( 'submit', 'View Diffs' ), "<br><br>\n";
	print $q->end_form;

	print "--- OR ---<br><br>\n";

	print 'View all projects created from this computer (IP address).', "<br><br>\n";
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print '<input type="hidden" name="step" value="myprojects">', "\n";
	print $q->submit( 'submit', 'My Projects' ), "<br><br>\n";
	print $q->end_form;

	print "</body>\n";
}

sub print_user_projects
{
	my $projects = $so->get_user_projects();

	&print_tool_header();
	unless ( @$projects > 0 ) {
		print "No projects have been created from this computer (IP address).";
		return;
	}

	print "<h4>Projects created from this computer (IP address):</h4>\n";
	print qq{<table cellpadding="4">\n};
	foreach ( @$projects )
	{
		print "<tr>\n<td> $_  </td>\n<td><br>\n";
		print $q->start_form( 'POST', undef, 'multipart/form-data' );
		print qq{<input type="hidden" name="project" value="$_">\n};
		# default to hiding the diffs that already have merge choices
		print '<input type="hidden" name="hide_merged" value="1">', "\n";
		# default to showing a maximum of 25 diffs at a time
		print '<input type="hidden" name="max_diffs" value="25">', "\n";
		print $q->submit( 'submit', 'View Diffs' ), "<br><br>\n";
		print "</form>\n";
		print "</td></tr>\n";
	}
	print "</table>\n";
}

sub print_files_in_project
{
	my ($skip_file3) = @_;

	print $q->h4( "SRT files in project:" );
	print qq{
		<b>File1:</b> $fn1 &nbsp;(Reference SRT)<br>
		<b>File2:</b> $fn2<br>
	};

	return if ( $skip_file3 );

	if ( $fn3 )
	{
		print qq{<b>File3:</b> $fn3 &nbsp;(optional - English/original SRT)<br><br>};
	}
	else
	{
		print qq{<table cellpadding="0" cellspacing="0"><tr>\n};
		print qq{<td><b>File3:</b> (optional)&nbsp; &nbsp; </td>};
		print "<td>\n";
		print $q->start_form( 'POST', undef, 'multipart/form-data' );
		print qq{<input type="hidden" name="project" value="$project">\n};
		print '<input type="hidden" name="step" value="file3form">', "\n";
		print $q->submit( 'submit', 'Add File3 (English/original SRT)' ), "<br>\n";
		print "</form>\n";
		print "</td></tr></table><br>\n";
	}
}

sub print_merge_form
{
	# see whether user doesn't want to see the diffs that have been merged already
	my $hide_merged_checked = ( $p->{'hide_merged'} ) ? 'checked' : '';
	# see whether the user wants some maximum number of diffs to show at a time (make sure it's an integer)
	my $max_diffs = $p->{'max_diffs'};
	$max_diffs = '0'  unless ( defined $max_diffs );
	$max_diffs = ( $max_diffs =~ m/(\d+)/ ) ? $1 : 0;
	$max_diffs -= 0;

	&print_tool_header();
	&print_project_header();

	print qq{
		In the diffs below, you can pick the version of the subtitle from File1, File2, enter a custom value<br>
		or choose not to pick a version yet (no merge yet). Then, you click any 'Merge' button. You should<br>
		click 'Merge' often (even before completely finished) because that is when your choices get saved.<br>
		The pipe characters '<b>|</b>' are not part of the subtitles, they are just to show white space at the ends.<br><br>
	};

	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{
		<input type="hidden" name="step" value="merge">
		<input type="hidden" name="project" value="$project">
		<input type="checkbox" name="hide_merged" value="1" $hide_merged_checked>
			Hide merged diffs (uncheck this and click 'Merge' to see merged diffs as well)<br><br>
		<input type="text" name="max_diffs" value="$max_diffs" size="2">
			diffs maximum to display at a time (set to 0 and click 'Merge' for no limit)

		<h4>Diffs:</h4>

		<table>
	};

	# display a 'Merge' button on top
	print &merge_button();

	# counter for the differing (and displayed) srt's only
	my $d = 0;
	my $sorder;

	for ( my $i = 0; $i < @$srt1; $i++ )
	{
		# show only the subtitles that differ in their text
		if ( $srt1->[$i]{'txt'} ne $srt2->[$i]{'txt'} )
		{
			# we always take value for the "order" field from the first file
			$sorder = $srt1->[$i]{'c'};

			# see whether we have a record (merge choice) for this subtitle in the master hash
			my $m = $srtm{ $sorder };

			# if we have a merge choice but don't want to see it, skip the display below
			next if ( $m and $p->{'hide_merged'} );

			$d++;

			my $file1_checked = ( $m and $m->{'merge'} eq 'file1' ) ? 'checked' : '';
			my $file2_checked = ( $m and $m->{'merge'} eq 'file2' ) ? 'checked' : '';
			my $custom_checked = ( $m and $m->{'merge'} eq 'custom' ) ? 'checked' : '';
			my $donotmerge_checked = '';
			$donotmerge_checked = 'checked' unless ( $file1_checked or $file2_checked or $custom_checked );
			my $custom = ( $custom_checked ) ? $m->{'txt'} : '';
			$custom = $q->escapeHTML( $custom )  if ( $custom );

			# check whether we have a file3 and an original subtitle
			my $orig_subt = ( $fn3 and exists $srt3{ $sorder } ) ? $srt3{ $sorder }{'txt'} : '';

			my $sorder_cell = '';

			# if we have original subtitle, we will display it and it will have the sorder cell with the rowspan
			if ( $orig_subt )
			{
				print <<"EOF";
<tr>
	<td rowspan="5">$sorder</td>
	<td>&nbsp;</td>
	<td>&nbsp;</td>
	<td><pre><b>|</b>$orig_subt<b>|</b></pre></td>
</tr>
EOF
			}
			# if we don't, the file1 row will have the sorder cell with the rowspan
			else
			{
				$sorder_cell = qq{<td rowspan="4">$sorder</td>\n};
			}

			print <<"EOF";
<tr>
	$sorder_cell
	<td><input type="radio" name="version_$sorder" value="1" $file1_checked></td>
	<td>File1: </td>
	<td><pre><b>|</b>$srt1->[$i]{'txt'}<b>|</b></pre></td>
</tr>
<tr>
	<td><input type="radio" name="version_$sorder" value="2" $file2_checked></td>
	<td>File2: </td>
	<td><pre><b>|</b>$srt2->[$i]{'txt'}<b>|</b></pre></td>
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
			print &merge_button()  if ( $d % 4 == 0 );

			# stop displaying diffs, if we have a maximum and we have reached it
			last  if ( $max_diffs and $d >= $max_diffs );
		}
	}

	# print 'Merge' button on the bottom (but avoid two of them back to back)
	print &merge_button()  unless ( $d % 4 == 0 );

	print "</table>\n";
	print $q->end_form;

	print "<br><hr><br>";

	# a separate form/button for export of the final version
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{<input type="hidden" name="step" value="export">\n};
	print qq{<input type="hidden" name="project" value="$project">\n};
	print $q->submit( 'submit', 'Export' ), "<br><br>\n";
	print $q->end_form;

	# a separate form/button for starting a new project
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print $q->submit( 'submit', 'Start New Project' ), "<br><br>\n";
	print $q->end_form;
	print "</body>\n"
}

# create string for merge button
sub merge_button
{
	return <<"EOF";
<tr><td colspan="4">
	<input type="submit" value="Merge">
</td></tr>
EOF

}

sub print_incomplete_export_form
{
	&print_tool_header();
	&print_project_header();
	print qq{
		You are trying to export a project where not all diffs have been resolved!<br><br>

		If you want, you can export the incomplete version. All diffs you have resolved will go through.<br>
		For the ones you have not resolved, the version from File1 will be used.<br><br>
	};

	# a form/button for export of the incomplete version
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print qq{<input type="hidden" name="step" value="export">\n};
	print qq{<input type="hidden" name="incomplete_export" value="1">\n};
	print qq{<input type="hidden" name="project" value="$project">\n};
	print $q->submit( 'submit', 'Export Incomplete Version' ), "<br><br>\n";
	print $q->end_form;

	print "</body>\n";
}

sub print_file3_form
{
	&print_tool_header();

	my $skip_file3 = 1;
	&print_project_header( $skip_file3 );

	print "<br>\n";
	print $q->start_form( 'POST', undef, 'multipart/form-data' );
	print '<input type="hidden" name="step" value="submitfile3">', "\n";
	print qq{<input type="hidden" name="project" value="$project">\n};
	# default to hiding the diffs that already have merge choices
	print '<input type="hidden" name="hide_merged" value="1">', "\n";
	# default to showing a maximum of 25 diffs at a time
	print '<input type="hidden" name="max_diffs" value="25">', "\n";

	print 'File3: ', $q->filefield( 'file3', '', 75, 200 ), " &nbsp;(optional - English/original SRT)<br><br>\n";
	print "Here you can submit File3 - the original (English) SRT. When File3 is submitted, you will see<br>
		the original/English subtitle text with each diff (between File1 and File2).<br><br>\n";
	print $q->submit( 'submit', 'Upload File3 and View Diffs' ), "<br><br>\n";
	print $q->end_form;

	print "</body>\n";
}

sub print_header
{
	print $q->header( -type => 'text/html', -charset => $encoding );
	print $q->start_html( 'Zeitgeist Movement | SRT | diff' );
}

sub print_tool_header
{
	print "<body>\n";
	$so->print_tools_menu();
	print "<h1>Diff SRT</h1>\n";
}

sub print_project_header
{
	my ($skip_file3) = @_;

	print $q->h3( "Project: $project" );
	&print_files_in_project( $skip_file3 );
}

sub export_final_project
{
	my $file_txt = '';
	my $s;
	my $accept_incomplete = $p->{'incomplete_export'};

	# go over each subtitle
	foreach ( my $i = 0; $i < @$srt1; $i++ )
	{
		# default to the subtitle from file1
		$s = $srt1->[$i];

		# if subtitles differ in their text, look at the record in the master hash
		if ( $srt1->[$i]{'txt'} ne $srt2->[$i]{'txt'} )
		{
			# we always take value for the "order" field from the first file
			my $sorder = $s->{'c'};

			# see whether we have a record for this subtitle in the master hash
			my $m = $srtm{ $sorder };
			unless ( $m )
			{
				unless ( $accept_incomplete )
				{
					&print_header();
					&print_incomplete_export_form();
					return;
				}
				# user explicitly asked for an incomplete export
				else
				{
					# pretend there is a merge choice and it's set to file1
					$m = { 'merge' => 'file1' };
				}
			}

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

		# keep accumulating the file contents
		$file_txt .= "$s->{'c'}\n$s->{'t'}\n$s->{'txt'}\n\n";
	}

	my $filename = $fn1;
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
